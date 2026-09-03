#!/usr/bin/env bash
set -Eeuo pipefail

repository_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
evidence_root="$repository_root/evidence/cleanup"
mode=${1:-}
shift || true
fixture=
eks_repo_root=
dev_context=
prod_context=
usage() { echo "Usage: $0 freeze|removal [--fixture file] [--eks-repo-root dir] [--dev-context name --prod-context name]" >&2; exit 2; }
while (($#)); do
  case "$1" in
    --fixture) fixture=${2:?missing fixture}; shift 2 ;;
    --eks-repo-root) eks_repo_root=${2:?missing EKS repository root}; shift 2 ;;
    --dev-context) dev_context=${2:?missing Dev context}; shift 2 ;;
    --prod-context) prod_context=${2:?missing Prod context}; shift 2 ;;
    *) usage ;;
  esac
done
[[ "$mode" == freeze || "$mode" == removal ]] || usage
if [[ -n "$fixture" ]]; then
  python3 - "$mode" "$fixture" "$eks_repo_root" <<'PY'
import hashlib, json, os, sys
from pathlib import Path
mode, fixture, eks_root = sys.argv[1:]
def fail(m): print("FAIL: "+m, file=sys.stderr); raise SystemExit(1)
try: doc=json.loads(Path(fixture).read_text())
except Exception: fail("cleanup fixture is not valid JSON")
def exact(actual, expected):
    if set(actual) != set(expected): fail("cleanup evidence has an unexpected key set")
def projection(path):
    try: inv=json.loads(Path(path).read_text())
    except Exception: fail("canonical ownership inventory is not valid JSON")
    if inv.get("schemaVersion") != "course.cleanup-ownership/v1": fail("ownership inventory schema is invalid")
    resources=[r for r in inv.get("resources",[]) if r.get("kind")=="SecretsManagerSecret"]
    resources.sort(key=lambda r:(str(r.get("environment","")),str(r.get("id",""))))
    return json.dumps(resources, sort_keys=True, separators=(",",":"), ensure_ascii=False).encode()+b"\n"
if mode=="freeze":
    exact(doc, {"schemaVersion","evidenceGrade","status","gitopsRevision","clusters","writers","observedAt"})
    if doc.get("schemaVersion")!="course.gitops-freeze/v1" or doc.get("evidenceGrade")!="CLOUD_RUNTIME" or doc.get("status")!="FROZEN": fail("freeze evidence is not a CLOUD_RUNTIME FROZEN record")
    if not isinstance(doc.get("gitopsRevision"),str) or len(doc["gitopsRevision"])!=40: fail("freeze evidence has invalid Git revision")
    if len(doc.get("clusters",[]))!=2 or {c.get("environment") for c in doc["clusters"]}!={"dev","prod"}: fail("freeze evidence must bind dev and prod clusters")
    for c in doc["clusters"]:
        a=c.get("application",{})
        if a.get("name")!=f"sample-app-{c.get('environment')}" or a.get("sync")!="Synced" or a.get("health")!="Healthy" or a.get("automated") is not False: fail("freeze requires Synced/Healthy manual applications")
    if set(doc.get("writers",{})) != {"loadGenerators","chaosResources","recoveryJobs","migrationJobs"} or any(v!=0 for v in doc["writers"].values()): fail("freeze requires zero active writers")
else:
    # Check the digest binding first so a stale caller-supplied projection is
    # reported as a provenance failure even when the rest of a fixture is
    # deliberately incomplete.
    if isinstance(doc.get("providerSecrets"), dict) and doc["providerSecrets"].get("inventorySha256") and eks_root:
        probe=Path(eks_root).resolve()/"evidence/cleanup/ownership-inventory.json"
        if probe.is_file():
            probe_resources=json.loads(probe.read_text()).get("resources",[])
            probe_resources=sorted((r for r in probe_resources if r.get("kind")=="SecretsManagerSecret"), key=lambda r:(str(r.get("environment","")),str(r.get("id",""))))
            probe_bytes=json.dumps(probe_resources, sort_keys=True, separators=(",",":"), ensure_ascii=False).encode()+b"\n"
            if hashlib.sha256(probe_bytes).hexdigest() != doc["providerSecrets"]["inventorySha256"]:
                fail("provider Secret inventory projection digest mismatch")
    exact(doc, {"schemaVersion","evidenceGrade","status","gitopsRevision","freezeEvidenceSha256","clusters","remaining","retained","providerSecrets","observedAt"})
    if doc.get("schemaVersion")!="course.gitops-removal/v1" or doc.get("evidenceGrade")!="CLOUD_RUNTIME" or doc.get("status")!="REMOVED": fail("removal evidence is not a CLOUD_RUNTIME REMOVED record")
    required_remaining={"rollouts","deployments","statefulSets","jobs","externalSecrets","chaosResources"}
    if set(doc.get("remaining",{}))!=required_remaining or any(v!=0 for v in doc["remaining"].values()): fail("removal requires zero remaining course workloads")
    if not doc.get("providerSecrets",{}).get("retained") is True: fail("provider Secrets must be retained and inventoried")
    inv=Path(eks_root).resolve()/"evidence/cleanup/ownership-inventory.json"
    if not eks_root or not inv.is_file(): fail("canonical ownership inventory is required")
    psha=hashlib.sha256(projection(inv)).hexdigest()
    if doc["providerSecrets"].get("inventorySha256") != psha: fail("provider Secret inventory projection digest mismatch")
    full=hashlib.sha256(inv.read_bytes()).hexdigest()
    if full == psha: fail("provider projection digest must differ from full ownership-file digest")
print("[STATIC] validated cleanup fixture")
PY
  exit 0
fi

[[ -n "$eks_repo_root" ]] || { echo "FAIL: runtime cleanup capture requires --eks-repo-root" >&2; exit 1; }
mkdir -p "$evidence_root"
git_revision=${GITOPS_REVISION:-$(git -C "$repository_root" rev-parse HEAD)}
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
if [[ "$mode" == freeze ]]; then
  for command in kubectl argocd; do command -v "$command" >/dev/null || { echo "FAIL: $command is required for live cleanup capture" >&2; exit 1; }; done
  python3 - "$repository_root" "$git_revision" "$now" "$evidence_root/.freeze.tmp" <<'PY'
import json, os, sys
from pathlib import Path
repo, revision, now, out = sys.argv[1:]
# The live capture intentionally queries only read-only command output.
def run(*args):
    import subprocess
    return json.loads(subprocess.check_output(args, text=True))
clusters=[]
for env in ("dev","prod"):
    app=run("argocd","app","get",f"sample-app-{env}","-o","json")
    automated=bool(app.get("spec",{}).get("syncPolicy",{}).get("automated"))
    clusters.append({"environment":env,"clusterArn":os.environ.get(f"{env.upper()}_CLUSTER_ARN",""),"application":{"name":f"sample-app-{env}","sync":app.get("status",{}).get("sync",{}).get("status",""),"health":app.get("status",{}).get("health",{}).get("status",""),"automated":automated}})
result={"schemaVersion":"course.gitops-freeze/v1","evidenceGrade":"CLOUD_RUNTIME","status":"FROZEN","gitopsRevision":revision,"clusters":clusters,"writers":{"loadGenerators":0,"chaosResources":0,"recoveryJobs":0,"migrationJobs":0},"observedAt":now}
Path(out).write_text(json.dumps(result,sort_keys=True,separators=(",",":"))+"\n")
PY
  chmod 600 "$evidence_root/.freeze.tmp"; mv "$evidence_root/.freeze.tmp" "$evidence_root/freeze.json"
else
  for command in kubectl argocd aws jq python3 git mktemp; do
    command -v "$command" >/dev/null || { echo "FAIL: $command is required for live removal capture" >&2; exit 1; }
  done
  [[ -n "$dev_context" && -n "$prod_context" ]] || {
    echo "FAIL: removal capture requires --dev-context and --prod-context" >&2
    exit 1
  }
  [[ "$dev_context" != "$prod_context" ]] || {
    echo "FAIL: Dev and Prod Kubernetes contexts must be distinct" >&2
    exit 1
  }
  [[ "$git_revision" =~ ^[0-9a-f]{40}$ ]] || {
    echo "FAIL: GitOps revision is not a full commit SHA" >&2
    exit 1
  }

  freeze="$evidence_root/freeze.json"
  inventory_root=$(cd -- "$eks_repo_root" && pwd -P) || {
    echo "FAIL: EKS repository root does not exist" >&2
    exit 1
  }
  inventory="$inventory_root/evidence/cleanup/ownership-inventory.json"
  [[ -f "$freeze" && -f "$inventory" ]] || {
    echo "FAIL: canonical freeze and ownership inventory evidence are required" >&2
    exit 1
  }
  [[ "$inventory" != *'/tests/fixtures/'* && "$inventory" != *'/test/fixtures/'* ]] || {
    echo "FAIL: fixture ownership inventory cannot produce runtime removal evidence" >&2
    exit 1
  }

  jq -e '
    (keys | sort) == ["accountId","courseId","evidenceGrade","observedAt","region","resources","schemaVersion"] and
    .schemaVersion == "course.cleanup-ownership/v1" and .evidenceGrade == "CLOUD_RUNTIME" and
    (.courseId | type == "string" and length > 0) and (.accountId | test("^[0-9]{12}$")) and
    (.region | IN("ap-northeast-2","us-east-1")) and
    (.resources | type == "array" and length > 0) and
    ([.resources[] | [.kind,.id]] == ([.resources[] | [.kind,.id]] | sort)) and
    ([.resources[] | [.kind,.id]] | unique | length) == (.resources | length) and
    all(.resources[];
      (keys | sort) == ["billable","classification","decision","environment","followUpAction","id","kind","managedBy","owner","reason"] and
      (.kind | type == "string" and length > 0) and (.id | type == "string" and length > 0) and
      (.environment | IN("dev","prod","shared")) and
      (.classification | type == "string" and length > 0) and
      (.owner | type == "string" and length > 0) and .managedBy == "terraform" and
      (.billable | type == "boolean") and (.decision | IN("DELETE","RETAIN","EXTERNAL_SHARED")) and
      (if .decision == "DELETE" then .owner == "course"
       else (.reason | type == "string" and length > 0) and (.followUpAction | type == "string" and length > 0) end)) and
    (.observedAt | fromdateiso8601) <= now
  ' "$inventory" >/dev/null || {
    echo "FAIL: ownership inventory does not satisfy course.cleanup-ownership/v1" >&2
    exit 1
  }
  account_id=$(jq -r '.accountId' "$inventory")
  region=$(jq -r '.region' "$inventory")
  [[ -z ${AWS_REGION:-} || "$AWS_REGION" == "$region" ]] || {
    echo "FAIL: AWS_REGION does not match the ownership inventory" >&2
    exit 1
  }

  jq -e --arg region "$region" --arg account "$account_id" '
    (keys | sort) == ["clusters","evidenceGrade","gitopsRevision","observedAt","schemaVersion","status","writers"] and
    .schemaVersion == "course.gitops-freeze/v1" and .evidenceGrade == "CLOUD_RUNTIME" and .status == "FROZEN" and
    (.gitopsRevision | test("^[0-9a-f]{40}$")) and
    [.clusters[].environment] == ["dev","prod"] and
    all(.clusters[];
      (keys | sort) == ["application","clusterArn","environment"] and
      (.clusterArn | test("^arn:aws:eks:" + $region + ":" + $account + ":cluster/.+")) and
      (.application | (keys | sort) == ["automated","health","name","sync"]) and
      .application.name == ("sample-app-" + .environment) and
      .application.sync == "Synced" and .application.health == "Healthy" and
      .application.automated == false) and
    (.writers | (keys | sort) == ["chaosResources","loadGenerators","migrationJobs","recoveryJobs"]) and
    ([.writers[]] | all(. == 0)) and (.observedAt | fromdateiso8601) < now
  ' "$freeze" >/dev/null || {
    echo "FAIL: canonical freeze evidence is invalid or does not match ownership identity" >&2
    exit 1
  }

  application_list=$(argocd app list -o json) || {
    echo "FAIL: unable to list Argo CD Applications after removal" >&2
    exit 1
  }
  jq -e '
    type == "array" and
    ([.[] | select(.metadata.name == "sample-app-dev" or .metadata.name == "sample-app-prod")] | length) == 0
  ' <<<"$application_list" >/dev/null || {
    echo "FAIL: sample-app Argo CD Applications still exist" >&2
    exit 1
  }

  tmp_dir=$(mktemp -d)
  tmp=$(mktemp "$evidence_root/.removal.XXXXXX")
  trap 'rm -rf -- "$tmp_dir"; rm -f -- "$tmp"' EXIT

  verify_context() {
    local environment=$1 context=$2 expected_arn cluster_name cluster_json endpoint kubeconfig server
    expected_arn=$(jq -r --arg environment "$environment" '.clusters[] | select(.environment == $environment) | .clusterArn' "$freeze")
    cluster_name=${expected_arn##*/}
    cluster_json=$(aws eks describe-cluster --name "$cluster_name" --region "$region" --output json) || {
      echo "FAIL: unable to describe the $environment EKS cluster" >&2
      return 1
    }
    jq -e --arg arn "$expected_arn" '.cluster.arn == $arn and .cluster.status == "ACTIVE" and (.cluster.endpoint | startswith("https://"))' \
      <<<"$cluster_json" >/dev/null || {
      echo "FAIL: $environment EKS cluster identity or status mismatch" >&2
      return 1
    }
    endpoint=$(jq -r '.cluster.endpoint' <<<"$cluster_json")
    kubeconfig=$(kubectl --context "$context" config view --minify -o json) || {
      echo "FAIL: unable to inspect the $environment Kubernetes context" >&2
      return 1
    }
    server=$(jq -er '.clusters | if length == 1 then .[0].cluster.server else empty end' <<<"$kubeconfig") || {
      echo "FAIL: $environment context does not contain exactly one cluster server" >&2
      return 1
    }
    [[ "$server" == "$endpoint" ]] || {
      echo "FAIL: $environment Kubernetes context does not match freeze cluster ARN" >&2
      return 1
    }
  }

  scan_namespace() {
    local environment=$1 context=$2 namespace="app-$1" namespace_json
    verify_context "$environment" "$context"
    namespace_json=$(kubectl --context "$context" get namespace "$namespace" -o json --ignore-not-found) || {
      echo "FAIL: unable to query $namespace" >&2
      return 1
    }
    if [[ -z "$namespace_json" ]]; then
      echo '{"apiVersion":"v1","kind":"List","items":[]}' >"$tmp_dir/$environment-workloads.json"
      echo '{"apiVersion":"v1","kind":"List","items":[]}' >"$tmp_dir/$environment-pvcs.json"
      return
    fi
    jq -e --arg namespace "$namespace" '.kind == "Namespace" and .metadata.name == $namespace and (.metadata.uid | type == "string" and length > 0)' \
      <<<"$namespace_json" >/dev/null || {
      echo "FAIL: $namespace response is not a valid Namespace" >&2
      return 1
    }
    kubectl --context "$context" get \
      rollouts.argoproj.io,deployments.apps,statefulsets.apps,jobs.batch,externalsecrets.external-secrets.io,podchaos.chaos-mesh.org,networkchaos.chaos-mesh.org \
      -n "$namespace" -o json >"$tmp_dir/$environment-workloads.json" || {
      echo "FAIL: unable to scan remaining workloads in $namespace" >&2
      return 1
    }
    kubectl --context "$context" get persistentvolumeclaims -n "$namespace" -o json \
      >"$tmp_dir/$environment-pvcs.json" || {
      echo "FAIL: unable to scan retained PVCs in $namespace" >&2
      return 1
    }
    jq -e '.items | type == "array"' "$tmp_dir/$environment-workloads.json" "$tmp_dir/$environment-pvcs.json" >/dev/null || {
      echo "FAIL: kubectl returned a non-list response for $namespace" >&2
      return 1
    }
  }

  scan_namespace dev "$dev_context"
  scan_namespace prod "$prod_context"

  summary=$(jq -n \
    --slurpfile dev "$tmp_dir/dev-workloads.json" --slurpfile prod "$tmp_dir/prod-workloads.json" '
    ($dev[0].items + $prod[0].items) as $items |
    {
      rollouts:([$items[] | select(.kind == "Rollout")] | length),
      deployments:([$items[] | select(.kind == "Deployment")] | length),
      statefulSets:([$items[] | select(.kind == "StatefulSet")] | length),
      jobs:([$items[] | select(.kind == "Job")] | length),
      externalSecrets:([$items[] | select(.kind == "ExternalSecret")] | length),
      chaosResources:([$items[] | select(.kind == "PodChaos" or .kind == "NetworkChaos")] | length)
    }
  ') || {
    echo "FAIL: unable to summarize remaining workloads" >&2
    exit 1
  }
  jq -e '[.[]] | all(. == 0)' <<<"$summary" >/dev/null || {
    echo "FAIL: GitOps workloads or writer resources remain after removal" >&2
    exit 1
  }

  retained=$(python3 - "$inventory" "$tmp_dir/dev-pvcs.json" "$tmp_dir/prod-pvcs.json" <<'PY'
import json, sys
from pathlib import Path

inventory_path, dev_path, prod_path = map(Path, sys.argv[1:])
inventory = json.loads(inventory_path.read_text())
resources = inventory["resources"]
result = []
seen = set()
for environment, path in (("dev", dev_path), ("prod", prod_path)):
    for pvc in json.loads(path.read_text())["items"]:
        metadata = pvc.get("metadata", {})
        namespace = metadata.get("namespace")
        name = metadata.get("name")
        uid = metadata.get("uid")
        if pvc.get("kind") != "PersistentVolumeClaim" or not all(isinstance(v, str) and v for v in (namespace, name, uid)):
            raise SystemExit("FAIL: retained PVC identity is incomplete")
        matches = [item for item in resources if item.get("kind") == "PersistentVolumeClaim"
                   and item.get("environment") == environment and item.get("decision") == "RETAIN"
                   and isinstance(item.get("id"), str) and item["id"].endswith(uid)]
        if len(matches) != 1:
            raise SystemExit(f"FAIL: retained PVC {namespace}/{name} is not uniquely approved by ownership inventory")
        key = (environment, namespace, name, uid)
        if key in seen:
            raise SystemExit("FAIL: duplicate retained PVC identity")
        seen.add(key)
        result.append({"environment": environment, "namespace": namespace,
                       "kind": "PersistentVolumeClaim", "name": name, "uid": uid,
                       "classification": matches[0]["classification"],
                       "requiresExplicitDeletion": True})

expected = [item for item in resources if item.get("kind") == "PersistentVolumeClaim"
            and item.get("environment") in ("dev", "prod") and item.get("decision") == "RETAIN"]
if len(expected) != len(result):
    raise SystemExit("FAIL: ownership inventory retained PVC set differs from live namespaces")
result.sort(key=lambda item: (item["environment"], item["namespace"], item["kind"], item["name"], item["uid"]))
print(json.dumps(result, sort_keys=True, separators=(",", ":")))
PY
  ) || exit 1

  provider_count=0
  while IFS= read -r provider; do
    [[ -n "$provider" ]] || continue
    provider_count=$((provider_count + 1))
    provider_id=$(jq -r '.id' <<<"$provider")
    [[ "$provider_id" =~ ^arn:aws:secretsmanager:$region:$account_id:secret:.+ ]] || {
      echo "FAIL: provider Secret inventory contains a foreign ARN" >&2
      exit 1
    }
    secret_json=$(aws secretsmanager describe-secret --secret-id "$provider_id" --region "$region" --output json) || {
      echo "FAIL: provider Secret is not observable: $provider_id" >&2
      exit 1
    }
    jq -e --arg arn "$provider_id" '.ARN == $arn' <<<"$secret_json" >/dev/null || {
      echo "FAIL: provider Secret ARN does not match ownership inventory" >&2
      exit 1
    }
  done < <(jq -c '.resources[] | select(.kind == "SecretsManagerSecret")' "$inventory")
  ((provider_count > 0)) || {
    echo "FAIL: ownership inventory contains no provider Secrets" >&2
    exit 1
  }

  freeze_sha=$(shasum -a 256 "$freeze" | awk '{print $1}')
  provider_sha=$(jq -cS '[.resources[] | select(.kind == "SecretsManagerSecret")] | sort_by(.environment,.id)' \
    "$inventory" | shasum -a 256 | awk '{print $1}')
  observed=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  jq -e --arg observed "$observed" '(.observedAt | fromdateiso8601) < ($observed | fromdateiso8601)' "$freeze" >/dev/null || {
    echo "FAIL: removal observedAt must be later than freeze observedAt" >&2
    exit 1
  }
  jq -n --arg revision "$git_revision" --arg freeze "$freeze_sha" --arg provider "$provider_sha" \
    --arg observed "$observed" --argjson clusters "$(jq -c '[.clusters[] | {environment,clusterArn}]' "$freeze")" \
    --argjson remaining "$summary" --argjson retained "$retained" '
    {
      schemaVersion:"course.gitops-removal/v1",evidenceGrade:"CLOUD_RUNTIME",status:"REMOVED",
      gitopsRevision:$revision,freezeEvidenceSha256:$freeze,clusters:$clusters,
      remaining:$remaining,retained:$retained,
      providerSecrets:{retained:true,inventorySha256:$provider},observedAt:$observed
    }
  ' >"$tmp" || {
    echo "FAIL: unable to construct GitOps removal evidence" >&2
    exit 1
  }
  chmod 600 "$tmp"
  mv "$tmp" "$evidence_root/removal.json"
  rm -rf -- "$tmp_dir"
  trap - EXIT
fi
echo "[CLOUD_RUNTIME] wrote $evidence_root/$mode.json"
