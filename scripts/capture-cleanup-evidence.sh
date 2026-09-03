#!/usr/bin/env bash
set -Eeuo pipefail

repository_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
evidence_root="$repository_root/evidence/cleanup"
mode=${1:-}
shift || true
fixture=
eks_repo_root=
dev_context=
prod_context=
output_override=
freeze_override=
adapter_dir=${COURSE_CHECK_BIN_DIR:-}
usage() { echo "Usage: $0 freeze|removal [--fixture file] [--eks-repo-root dir] [--dev-context name --prod-context name]" >&2; exit 2; }

physical_file_path() {
  local requested=$1 physical_parent
  [[ -f "$requested" && ! -L "$requested" ]] || return 1
  physical_parent=$(cd -- "$(dirname -- "$requested")" && pwd -P) || return 1
  echo "$physical_parent/$(basename -- "$requested")"
}
while (($#)); do
  case "$1" in
    --fixture) fixture=${2:?missing fixture}; shift 2 ;;
    --eks-repo-root) eks_repo_root=${2:?missing EKS repository root}; shift 2 ;;
    --dev-context) dev_context=${2:?missing Dev context}; shift 2 ;;
    --prod-context) prod_context=${2:?missing Prod context}; shift 2 ;;
    --output) output_override=${2:?missing output}; shift 2 ;;
    --freeze-evidence) freeze_override=${2:?missing freeze evidence}; shift 2 ;;
    *) usage ;;
  esac
done
[[ "$mode" == freeze || "$mode" == removal ]] || usage
if [[ -n "$fixture" ]]; then
  python3 - "$mode" "$fixture" "$eks_repo_root" <<'PY'
import hashlib, json, re, sys
from datetime import datetime, timezone
from pathlib import Path

mode, fixture, eks_root = sys.argv[1:]
HEX40 = re.compile(r"^[0-9a-f]{40}$")
HEX64 = re.compile(r"^[0-9a-f]{64}$")
ARN = re.compile(r"^arn:aws:eks:(ap-northeast-2|us-east-1):([0-9]{12}):cluster/[A-Za-z0-9][A-Za-z0-9_-]{0,99}$")
RESOURCE_KEYS = {"kind","id","environment","classification","owner","managedBy","billable","decision","reason","followUpAction"}

def fail(message):
    print("FAIL: " + message, file=sys.stderr)
    raise SystemExit(1)

def nonblank(value):
    return isinstance(value, str) and any(not (character.isspace() or character == "\ufeff") for character in value)

def exact(value, keys, context):
    if not isinstance(value, dict) or set(value) != set(keys):
        fail(f"{context} has an unexpected key set")

def utc_timestamp(value, context):
    if not isinstance(value, str) or not value.endswith("Z"):
        fail(f"{context} is not an RFC3339 UTC timestamp")
    try:
        parsed = datetime.fromisoformat(value[:-1] + "+00:00")
    except ValueError:
        fail(f"{context} is not an RFC3339 UTC timestamp")
    if parsed > datetime.now(timezone.utc):
        fail(f"{context} is in the future")

def read_json(path, context):
    try:
        return json.loads(path.read_text())
    except Exception:
        fail(f"{context} is not valid JSON")

def validate_inventory(path):
    if path.is_symlink() or not path.is_file():
        fail("canonical ownership inventory must be a regular non-symlink file")
    inventory = read_json(path, "canonical ownership inventory")
    exact(inventory, {"schemaVersion","evidenceGrade","courseId","accountId","region","resources","observedAt"}, "ownership inventory")
    if inventory["schemaVersion"] != "course.cleanup-ownership/v1" or inventory["evidenceGrade"] != "CLOUD_RUNTIME":
        fail("ownership inventory schema or evidence grade is invalid")
    if not nonblank(inventory["courseId"]) or not re.fullmatch(r"[0-9]{12}", inventory["accountId"]):
        fail("ownership inventory identity is invalid")
    if inventory["region"] not in {"ap-northeast-2", "us-east-1"} or not isinstance(inventory["resources"], list) or not inventory["resources"]:
        fail("ownership inventory Region or resources are invalid")
    if inventory["resources"] != sorted(inventory["resources"], key=lambda item: (item.get("kind", ""), item.get("id", ""))):
        fail("ownership inventory resources are not canonically sorted")
    identities = []
    for resource in inventory["resources"]:
        exact(resource, RESOURCE_KEYS, "ownership resource")
        if resource["environment"] not in {"dev","prod","shared"} or resource["managedBy"] != "terraform":
            fail("ownership resource scope is invalid")
        if not all(nonblank(resource[key]) for key in ("kind","id","classification","owner")):
            fail("ownership resource identity is incomplete")
        if type(resource["billable"]) is not bool or resource["decision"] not in {"DELETE","RETAIN","EXTERNAL_SHARED"}:
            fail("ownership resource decision is invalid")
        if resource["decision"] == "DELETE" and resource["owner"] != "course":
            fail("delete decision is not course-owned")
        if resource["decision"] != "DELETE" and not all(nonblank(resource[key]) for key in ("reason","followUpAction")):
            fail("retained ownership resource lacks rationale")
        identities.append((resource["kind"], resource["id"]))
    if len(identities) != len(set(identities)):
        fail("ownership resource identities are duplicated")
    utc_timestamp(inventory["observedAt"], "ownership observedAt")
    return inventory

def provider_projection(inventory):
    resources = sorted((resource for resource in inventory["resources"] if resource["kind"] == "SecretsManagerSecret"), key=lambda item: (item["environment"], item["id"]))
    if not resources or any(resource["decision"] not in {"RETAIN","EXTERNAL_SHARED"} for resource in resources):
        fail("provider Secrets must be retained or externally shared")
    return json.dumps(resources, sort_keys=True, separators=(",",":"), ensure_ascii=False).encode() + b"\n"

fixture_path = Path(fixture)
if fixture_path.is_symlink() or not fixture_path.is_file():
    fail("cleanup fixture must be a regular non-symlink file")
doc = read_json(fixture_path, "cleanup fixture")
if mode == "freeze":
    exact(doc, {"schemaVersion","evidenceGrade","status","gitopsRevision","clusters","writers","observedAt"}, "freeze evidence")
    if doc["schemaVersion"] != "course.gitops-freeze/v1" or doc["evidenceGrade"] != "CLOUD_RUNTIME" or doc["status"] != "FROZEN" or not HEX40.fullmatch(doc["gitopsRevision"]):
        fail("freeze evidence is not a canonical CLOUD_RUNTIME FROZEN record")
    if not isinstance(doc["clusters"], list) or [cluster.get("environment") for cluster in doc["clusters"]] != ["dev","prod"]:
        fail("freeze evidence must bind ordered dev and prod clusters")
    cluster_identities = []
    for cluster in doc["clusters"]:
        exact(cluster, {"environment","clusterArn","application"}, "freeze cluster")
        match = ARN.fullmatch(cluster["clusterArn"])
        if not match:
            fail("freeze cluster ARN is invalid")
        cluster_identities.append(match.groups())
        application = cluster["application"]
        exact(application, {"name","sync","health","automated"}, "freeze application")
        if application != {"name":f"sample-app-{cluster['environment']}","sync":"Synced","health":"Healthy","automated":False}:
            fail("freeze requires Synced, Healthy, manual applications")
    if cluster_identities[0] != cluster_identities[1] or doc["clusters"][0]["clusterArn"] == doc["clusters"][1]["clusterArn"]:
        fail("freeze clusters must be distinct in one account and Region")
    exact(doc["writers"], {"loadGenerators","chaosResources","recoveryJobs","migrationJobs"}, "freeze writers")
    if any(type(value) is not int or value != 0 for value in doc["writers"].values()):
        fail("freeze requires integer zero active-writer counts")
    utc_timestamp(doc["observedAt"], "freeze observedAt")
else:
    exact(doc, {"schemaVersion","evidenceGrade","status","gitopsRevision","freezeEvidenceSha256","clusters","remaining","retained","providerSecrets","observedAt"}, "removal evidence")
    if doc["schemaVersion"] != "course.gitops-removal/v1" or doc["evidenceGrade"] != "CLOUD_RUNTIME" or doc["status"] != "REMOVED":
        fail("removal evidence is not a canonical CLOUD_RUNTIME REMOVED record")
    if not HEX40.fullmatch(doc["gitopsRevision"]) or not HEX64.fullmatch(doc["freezeEvidenceSha256"]):
        fail("removal Git or freeze digest identity is invalid")
    if not isinstance(doc["clusters"], list) or [cluster.get("environment") for cluster in doc["clusters"]] != ["dev","prod"]:
        fail("removal evidence must bind ordered dev and prod clusters")
    cluster_identities = []
    for cluster in doc["clusters"]:
        exact(cluster, {"environment","clusterArn"}, "removal cluster")
        match = ARN.fullmatch(cluster["clusterArn"])
        if not match:
            fail("removal cluster ARN is invalid")
        cluster_identities.append(match.groups())
    if cluster_identities[0] != cluster_identities[1] or doc["clusters"][0]["clusterArn"] == doc["clusters"][1]["clusterArn"]:
        fail("removal clusters must be distinct in one account and Region")
    exact(doc["remaining"], {"rollouts","deployments","statefulSets","jobs","externalSecrets","chaosResources"}, "removal remaining")
    if any(type(value) is not int or value != 0 for value in doc["remaining"].values()):
        fail("removal requires integer zero remaining counts")
    if not isinstance(doc["retained"], list):
        fail("removal retained inventory is not an array")
    retained_identities = []
    for item in doc["retained"]:
        exact(item, {"environment","namespace","kind","name","uid","classification","requiresExplicitDeletion"}, "retained object")
        if item["environment"] not in {"dev","prod","shared"} or item["requiresExplicitDeletion"] is not True:
            fail("retained object scope or approval boundary is invalid")
        if not all(nonblank(item[key]) for key in ("kind","name","uid","classification")) or not isinstance(item["namespace"], str):
            fail("retained object identity is incomplete")
        retained_identities.append((item["environment"],item["namespace"],item["kind"],item["name"],item["uid"]))
    if retained_identities != sorted(retained_identities) or len(retained_identities) != len(set(retained_identities)):
        fail("retained object identities are not canonical or unique")
    exact(doc["providerSecrets"], {"retained","inventorySha256"}, "provider Secret summary")
    if doc["providerSecrets"]["retained"] is not True or not HEX64.fullmatch(doc["providerSecrets"]["inventorySha256"]):
        fail("provider Secret retention summary is invalid")
    if not eks_root:
        fail("canonical ownership inventory is required")
    eks_path = Path(eks_root)
    if eks_path.is_symlink() or not eks_path.is_dir():
        fail("EKS repository root must be a regular non-symlink directory")
    inventory_root = eks_path.resolve(strict=True)
    inventory_path = inventory_root / "evidence/cleanup/ownership-inventory.json"
    try:
        inventory_resolved = inventory_path.resolve(strict=True)
    except (FileNotFoundError, RuntimeError):
        fail("canonical ownership inventory cannot be resolved safely")
    if inventory_resolved != inventory_path:
        fail("canonical ownership inventory escaped the EKS repository root")
    inventory = validate_inventory(inventory_path)
    projection = provider_projection(inventory)
    if hashlib.sha256(projection).hexdigest() != doc["providerSecrets"]["inventorySha256"]:
        fail("provider Secret inventory projection digest mismatch")
    if hashlib.sha256(inventory_path.read_bytes()).hexdigest() == doc["providerSecrets"]["inventorySha256"]:
        fail("provider projection digest must differ from full ownership-file digest")
    retained_kinds = {"PersistentVolumeClaim","VolumeSnapshot","VolumeSnapshotContent","Namespace"}
    expected = [resource for resource in inventory["resources"] if resource["kind"] in retained_kinds and resource["decision"] == "RETAIN"]
    if len(expected) != len(doc["retained"]):
        fail("retained live object set differs from ownership inventory")
    for item in doc["retained"]:
        inventory_id = item["name"] if item["kind"] in {"Namespace","VolumeSnapshotContent"} else f"{item['namespace']}/{item['name']}"
        matches = [resource for resource in expected if resource["environment"] == item["environment"] and resource["kind"] == item["kind"] and resource["id"] == inventory_id and resource["classification"] == item["classification"]]
        if len(matches) != 1:
            fail("retained object does not exactly match ownership inventory")
    utc_timestamp(doc["observedAt"], "removal observedAt")
print("[STATIC] validated cleanup fixture")
PY
  exit 0
fi

evidence_grade=CLOUD_RUNTIME
output_path="$evidence_root/$mode.json"
if [[ -n "$adapter_dir" ]]; then
  [[ -d "$adapter_dir" && -n "$output_override" ]] || {
    echo "FAIL: static runtime adapter requires COURSE_CHECK_BIN_DIR and --output" >&2
    exit 1
  }
  [[ "$output_override" != "$repository_root/evidence/"* && "$output_override" != *'/tests/fixtures/'* ]] || {
    echo "FAIL: static runtime adapter cannot write repository evidence or fixture paths" >&2
    exit 1
  }
  PATH="$adapter_dir:$PATH"
  evidence_grade=STATIC
  output_path=$output_override
else
  [[ -z "$output_override" && -z "$freeze_override" ]] || {
    echo "FAIL: runtime cleanup inputs and outputs are fixed to canonical paths" >&2
    exit 1
  }
fi
mkdir -p "$(dirname -- "$output_path")"
if [[ "$evidence_grade" == CLOUD_RUNTIME ]]; then
  output_parent=$(cd -- "$(dirname -- "$output_path")" && pwd -P) || {
    echo "FAIL: cannot resolve canonical cleanup output directory" >&2
    exit 1
  }
  [[ "$output_parent/$(basename -- "$output_path")" == "$evidence_root/$mode.json" ]] || {
    echo "FAIL: canonical cleanup output escaped the repository evidence directory" >&2
    exit 1
  }
fi
git_revision=$(git -C "$repository_root" rev-parse HEAD)
if [[ "$mode" == freeze ]]; then
  for command in kubectl aws jq git mktemp; do
    command -v "$command" >/dev/null || { echo "FAIL: $command is required for live freeze capture" >&2; exit 1; }
  done
  [[ -n "$dev_context" && -n "$prod_context" && "$dev_context" != "$prod_context" ]] || {
    echo "FAIL: freeze capture requires distinct --dev-context and --prod-context" >&2
    exit 1
  }
  [[ ${AWS_REGION:-} == ap-northeast-2 || ${AWS_REGION:-} == us-east-1 ]] || {
    echo "FAIL: AWS_REGION must be ap-northeast-2 or us-east-1" >&2
    exit 1
  }
  [[ -n ${DEV_CLUSTER_NAME:-} && -n ${PROD_CLUSTER_NAME:-} && "$DEV_CLUSTER_NAME" != "$PROD_CLUSTER_NAME" ]] || {
    echo "FAIL: distinct DEV_CLUSTER_NAME and PROD_CLUSTER_NAME are required" >&2
    exit 1
  }
  [[ "$git_revision" =~ ^[0-9a-f]{40}$ ]] || {
    echo "FAIL: GitOps revision is not a full commit SHA" >&2
    exit 1
  }
  [[ -z $(git -C "$repository_root" status --porcelain --untracked-files=all -- . ':(exclude)evidence') ]] || {
    echo "FAIL: GitOps source outside evidence/ must match the checked-out commit before freeze capture" >&2
    exit 1
  }

  freeze_tmp_dir=$(mktemp -d)
  freeze_tmp=$(mktemp "$(dirname -- "$output_path")/.freeze.XXXXXX")
  trap 'rm -rf -- "$freeze_tmp_dir"; rm -f -- "$freeze_tmp"' EXIT

  capture_cluster_application() {
    local environment=$1 context=$2 cluster_name=$3 cluster_json cluster_arn endpoint kubeconfig server app_json app_revision api_resources
    cluster_json=$(aws eks describe-cluster --name "$cluster_name" --region "$AWS_REGION" --output json) || {
      echo "FAIL: unable to describe the $environment EKS cluster" >&2
      return 1
    }
    jq -e --arg name "$cluster_name" --arg region "$AWS_REGION" '
      .cluster.name == $name and .cluster.status == "ACTIVE" and
      (.cluster.arn | test("^arn:aws:eks:" + $region + ":[0-9]{12}:cluster/[A-Za-z0-9][A-Za-z0-9_-]{0,99}$")) and
      (.cluster.arn | endswith(":cluster/" + $name)) and
      (.cluster.endpoint | type == "string" and startswith("https://"))
    ' <<<"$cluster_json" >/dev/null || {
      echo "FAIL: $environment EKS cluster identity or status mismatch" >&2
      return 1
    }
    cluster_arn=$(jq -r '.cluster.arn' <<<"$cluster_json")
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
      echo "FAIL: $environment Kubernetes context does not match EKS cluster" >&2
      return 1
    }

    app_json=$(kubectl --context "$context" -n argocd get application "sample-app-$environment" -o json) || {
      echo "FAIL: unable to read sample-app-$environment from the $environment cluster" >&2
      return 1
    }
    app_revision=$(jq -er '.status.operationState.syncResult.revision // .status.sync.revision' <<<"$app_json") || {
      echo "FAIL: sample-app-$environment has no synchronized revision" >&2
      return 1
    }
    jq -e --arg name "sample-app-$environment" '
      .metadata.name == $name and .status.sync.status == "Synced" and .status.health.status == "Healthy" and
      ((.spec.syncPolicy.automated // null) == null)
    ' <<<"$app_json" >/dev/null || {
      echo "FAIL: sample-app-$environment must be Synced, Healthy, and manually synchronized" >&2
      return 1
    }
    [[ "$app_revision" == "$git_revision" ]] || {
      echo "FAIL: sample-app-$environment revision does not match the checked-out GitOps commit" >&2
      return 1
    }
    jq -n --arg environment "$environment" --arg arn "$cluster_arn" --arg name "sample-app-$environment" '
      {environment:$environment,clusterArn:$arn,application:{name:$name,sync:"Synced",health:"Healthy",automated:false}}
    ' >"$freeze_tmp_dir/$environment-cluster.json"

    api_resources=$(kubectl --context "$context" api-resources -o name) || {
      echo "FAIL: unable to discover writer APIs in $environment" >&2
      return 1
    }
    kubectl --context "$context" get jobs.batch -A -o json >"$freeze_tmp_dir/$environment-jobs.json" || return 1
    kubectl --context "$context" get statefulsets.apps -A -o json >"$freeze_tmp_dir/$environment-statefulsets.json" || return 1
    if grep -Fxq 'testruns.k6.io' <<<"$api_resources"; then
      kubectl --context "$context" get testruns.k6.io -A -o json >"$freeze_tmp_dir/$environment-load.json" || return 1
    else
      echo '{"apiVersion":"v1","kind":"List","items":[]}' >"$freeze_tmp_dir/$environment-load.json"
    fi
    if grep -Fxq 'podchaos.chaos-mesh.org' <<<"$api_resources" || grep -Fxq 'networkchaos.chaos-mesh.org' <<<"$api_resources"; then
      kubectl --context "$context" get podchaos.chaos-mesh.org,networkchaos.chaos-mesh.org -A -o json \
        >"$freeze_tmp_dir/$environment-chaos.json" || return 1
    else
      echo '{"apiVersion":"v1","kind":"List","items":[]}' >"$freeze_tmp_dir/$environment-chaos.json"
    fi
    jq -e '.items | type == "array"' "$freeze_tmp_dir/$environment-jobs.json" \
      "$freeze_tmp_dir/$environment-statefulsets.json" "$freeze_tmp_dir/$environment-load.json" \
      "$freeze_tmp_dir/$environment-chaos.json" >/dev/null || {
      echo "FAIL: $environment writer query returned a non-list response" >&2
      return 1
    }
  }

  capture_cluster_application dev "$dev_context" "$DEV_CLUSTER_NAME"
  capture_cluster_application prod "$prod_context" "$PROD_CLUSTER_NAME"
  dev_account=$(jq -r '.clusterArn | split(":")[4]' "$freeze_tmp_dir/dev-cluster.json")
  prod_account=$(jq -r '.clusterArn | split(":")[4]' "$freeze_tmp_dir/prod-cluster.json")
  [[ "$dev_account" == "$prod_account" ]] || {
    echo "FAIL: Dev and Prod EKS clusters belong to different accounts" >&2
    exit 1
  }

  writers=$(jq -n \
    --slurpfile devLoad "$freeze_tmp_dir/dev-load.json" --slurpfile prodLoad "$freeze_tmp_dir/prod-load.json" \
    --slurpfile devChaos "$freeze_tmp_dir/dev-chaos.json" --slurpfile prodChaos "$freeze_tmp_dir/prod-chaos.json" \
    --slurpfile devJobs "$freeze_tmp_dir/dev-jobs.json" --slurpfile prodJobs "$freeze_tmp_dir/prod-jobs.json" \
    --slurpfile devStateful "$freeze_tmp_dir/dev-statefulsets.json" --slurpfile prodStateful "$freeze_tmp_dir/prod-statefulsets.json" '
    def items($left;$right): $left[0].items + $right[0].items;
    items($devJobs;$prodJobs) as $jobs |
    items($devStateful;$prodStateful) as $stateful |
    {
      loadGenerators:
        (([items($devLoad;$prodLoad)[] | select((.status.stage // "unknown") != "finished")] | length) +
         ([$jobs[] | select(((.status.active // 0) > 0) and
           (.metadata.labels["course.writer"] == "load-generator" or
            .metadata.labels["app.kubernetes.io/component"] == "load-generator"))] | length)),
      chaosResources:(items($devChaos;$prodChaos) | length),
      recoveryJobs:
        (([$jobs[] | select(((.status.active // 0) > 0) and
          (.metadata.labels["course.writer"] == "recovery" or
           .metadata.labels["app.kubernetes.io/component"] == "recovery"))] | length) +
         ([$stateful[] | select(((.spec.replicas // 0) > 0) and
          (.metadata.labels["course.writer"] == "recovery" or
           .metadata.labels["app.kubernetes.io/component"] == "recovery" or
           .metadata.labels["course.playbuilder.io/cleanup-scope"] == "recovery"))] | length)),
      migrationJobs:([$jobs[] | select(((.status.active // 0) > 0) and
        (.metadata.labels["course.writer"] == "migration" or
         .metadata.labels["app.kubernetes.io/component"] == "migration"))] | length)
    }
  ') || {
    echo "FAIL: unable to summarize active writers" >&2
    exit 1
  }
  jq -e '[.[]] | all(. == 0)' <<<"$writers" >/dev/null || {
    echo "FAIL: active load, Chaos, recovery, or migration writers prevent freeze" >&2
    exit 1
  }

  freeze_observed=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  jq -n --arg revision "$git_revision" --arg observed "$freeze_observed" --arg grade "$evidence_grade" \
    --slurpfile dev "$freeze_tmp_dir/dev-cluster.json" --slurpfile prod "$freeze_tmp_dir/prod-cluster.json" \
    --argjson writers "$writers" '
    {schemaVersion:"course.gitops-freeze/v1",evidenceGrade:$grade,status:"FROZEN",
     gitopsRevision:$revision,clusters:[$dev[0],$prod[0]],writers:$writers,observedAt:$observed}
  ' >"$freeze_tmp" || {
    echo "FAIL: unable to construct GitOps freeze evidence" >&2
    exit 1
  }
  chmod 600 "$freeze_tmp"
  mv "$freeze_tmp" "$output_path"
  rm -rf -- "$freeze_tmp_dir"
  trap - EXIT
else
  [[ -n "$eks_repo_root" ]] || { echo "FAIL: runtime removal capture requires --eks-repo-root" >&2; exit 1; }
  for command in kubectl aws jq python3 git mktemp; do
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
  [[ -z $(git -C "$repository_root" status --porcelain --untracked-files=all -- . ':(exclude)evidence') ]] || {
    echo "FAIL: GitOps source outside evidence/ must match the checked-out commit before removal capture" >&2
    exit 1
  }

  freeze=${freeze_override:-$evidence_root/freeze.json}
  [[ ! -L "$eks_repo_root" ]] || {
    echo "FAIL: EKS repository root cannot be a symlink" >&2
    exit 1
  }
  inventory_root=$(cd -- "$eks_repo_root" && pwd -P) || {
    echo "FAIL: EKS repository root does not exist" >&2
    exit 1
  }
  inventory="$inventory_root/evidence/cleanup/ownership-inventory.json"
  [[ -f "$freeze" && ! -L "$freeze" && -f "$inventory" && ! -L "$inventory" ]] || {
    echo "FAIL: canonical freeze and ownership inventory evidence are required" >&2
    exit 1
  }
  freeze_physical=$(physical_file_path "$freeze") || {
    echo "FAIL: canonical freeze evidence cannot be resolved safely" >&2
    exit 1
  }
  inventory_physical=$(physical_file_path "$inventory") || {
    echo "FAIL: canonical ownership inventory cannot be resolved safely" >&2
    exit 1
  }
  if [[ "$evidence_grade" == CLOUD_RUNTIME ]]; then
    [[ "$freeze_physical" == "$repository_root/evidence/cleanup/freeze.json" ]] || {
      echo "FAIL: freeze evidence escaped its canonical repository path" >&2
      exit 1
    }
  fi
  [[ "$inventory_physical" == "$inventory_root/evidence/cleanup/ownership-inventory.json" ]] || {
    echo "FAIL: ownership inventory escaped its EKS repository path" >&2
    exit 1
  }
  [[ "$inventory" != *'/tests/fixtures/'* && "$inventory" != *'/test/fixtures/'* ]] || {
    echo "FAIL: fixture ownership inventory cannot produce runtime removal evidence" >&2
    exit 1
  }

  jq -e --arg grade "$evidence_grade" '
    def nonblank: type == "string" and test("[^[:space:]\uFEFF]");
    (keys | sort) == ["accountId","courseId","evidenceGrade","observedAt","region","resources","schemaVersion"] and
    .schemaVersion == "course.cleanup-ownership/v1" and .evidenceGrade == $grade and
    (.courseId | nonblank) and (.accountId | test("^[0-9]{12}$")) and
    (.region | IN("ap-northeast-2","us-east-1")) and
    (.resources | type == "array" and length > 0) and
    ([.resources[] | [.kind,.id]] == ([.resources[] | [.kind,.id]] | sort)) and
    ([.resources[] | [.kind,.id]] | unique | length) == (.resources | length) and
    all(.resources[];
      (keys | sort) == ["billable","classification","decision","environment","followUpAction","id","kind","managedBy","owner","reason"] and
      (.kind | nonblank) and (.id | nonblank) and
      (.environment | IN("dev","prod","shared")) and
      (.classification | nonblank) and
      (.owner | nonblank) and .managedBy == "terraform" and
      (.billable | type == "boolean") and (.decision | IN("DELETE","RETAIN","EXTERNAL_SHARED")) and
      (if .decision == "DELETE" then .owner == "course"
       else (.reason | nonblank) and (.followUpAction | nonblank) end)) and
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

  jq -e --arg region "$region" --arg account "$account_id" --arg grade "$evidence_grade" '
    (keys | sort) == ["clusters","evidenceGrade","gitopsRevision","observedAt","schemaVersion","status","writers"] and
    .schemaVersion == "course.gitops-freeze/v1" and .evidenceGrade == $grade and .status == "FROZEN" and
    (.gitopsRevision | test("^[0-9a-f]{40}$")) and
    [.clusters[].environment] == ["dev","prod"] and
    all(.clusters[];
      (keys | sort) == ["application","clusterArn","environment"] and
      (.clusterArn | test("^arn:aws:eks:" + $region + ":" + $account + ":cluster/[A-Za-z0-9][A-Za-z0-9_-]{0,99}$")) and
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

  tmp_dir=$(mktemp -d)
  tmp=$(mktemp "$(dirname -- "$output_path")/.removal.XXXXXX")
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

  verify_application_absent() {
    local environment=$1 context=$2 application
    application=$(kubectl --context "$context" -n argocd get application "sample-app-$environment" \
      -o name --ignore-not-found) || {
      echo "FAIL: unable to query sample-app-$environment after removal" >&2
      return 1
    }
    [[ -z "$application" ]] || {
      echo "FAIL: sample-app-$environment Argo CD Application still exists" >&2
      return 1
    }
  }

  scan_namespace() {
    local key=$1 environment=$2 context=$3 namespace=$4 namespace_json api_resources
    verify_context "$environment" "$context"
    api_resources=$(kubectl --context "$context" api-resources -o name) || {
      echo "FAIL: unable to discover retained-object APIs in $environment" >&2
      return 1
    }
    if [[ "$key" == "$environment" ]]; then
      if grep -Fxq 'volumesnapshotcontents.snapshot.storage.k8s.io' <<<"$api_resources"; then
        kubectl --context "$context" get volumesnapshotcontents.snapshot.storage.k8s.io -o json \
          >"$tmp_dir/$environment-snapshotcontents.json" || return 1
      else
        echo '{"apiVersion":"v1","kind":"List","items":[]}' >"$tmp_dir/$environment-snapshotcontents.json"
      fi
    fi
    namespace_json=$(kubectl --context "$context" get namespace "$namespace" -o json --ignore-not-found) || {
      echo "FAIL: unable to query $namespace" >&2
      return 1
    }
    if [[ -z "$namespace_json" ]]; then
      echo '{"apiVersion":"v1","kind":"List","items":[]}' >"$tmp_dir/$key-namespaces.json"
      echo '{"apiVersion":"v1","kind":"List","items":[]}' >"$tmp_dir/$key-workloads.json"
      echo '{"apiVersion":"v1","kind":"List","items":[]}' >"$tmp_dir/$key-pvcs.json"
      echo '{"apiVersion":"v1","kind":"List","items":[]}' >"$tmp_dir/$key-snapshots.json"
      return
    fi
    jq -e --arg namespace "$namespace" '.kind == "Namespace" and .metadata.name == $namespace and (.metadata.uid | type == "string" and length > 0)' \
      <<<"$namespace_json" >/dev/null || {
      echo "FAIL: $namespace response is not a valid Namespace" >&2
      return 1
    }
    jq -n --argjson namespace "$namespace_json" '{apiVersion:"v1",kind:"List",items:[$namespace]}' \
      >"$tmp_dir/$key-namespaces.json"
    kubectl --context "$context" get \
      rollouts.argoproj.io,deployments.apps,statefulsets.apps,jobs.batch,externalsecrets.external-secrets.io,podchaos.chaos-mesh.org,networkchaos.chaos-mesh.org \
      -n "$namespace" -o json >"$tmp_dir/$key-workloads.json" || {
      echo "FAIL: unable to scan remaining workloads in $namespace" >&2
      return 1
    }
    kubectl --context "$context" get persistentvolumeclaims -n "$namespace" -o json \
      >"$tmp_dir/$key-pvcs.json" || {
      echo "FAIL: unable to scan retained PVCs in $namespace" >&2
      return 1
    }
    if grep -Fxq 'volumesnapshots.snapshot.storage.k8s.io' <<<"$api_resources"; then
      kubectl --context "$context" get volumesnapshots.snapshot.storage.k8s.io -n "$namespace" -o json \
        >"$tmp_dir/$key-snapshots.json" || return 1
    else
      echo '{"apiVersion":"v1","kind":"List","items":[]}' >"$tmp_dir/$key-snapshots.json"
    fi
    jq -e '.items | type == "array"' "$tmp_dir/$key-namespaces.json" "$tmp_dir/$key-workloads.json" \
      "$tmp_dir/$key-pvcs.json" "$tmp_dir/$key-snapshots.json" >/dev/null || {
      echo "FAIL: kubectl returned a non-list response for $namespace" >&2
      return 1
    }
  }

  verify_application_absent dev "$dev_context"
  verify_application_absent prod "$prod_context"
  scan_namespace dev dev "$dev_context" app-dev
  scan_namespace recovery dev "$dev_context" app-recovery
  scan_namespace prod prod "$prod_context" app-prod

  summary=$(jq -n \
    --slurpfile dev "$tmp_dir/dev-workloads.json" --slurpfile recovery "$tmp_dir/recovery-workloads.json" \
    --slurpfile prod "$tmp_dir/prod-workloads.json" '
    ($dev[0].items + $recovery[0].items + $prod[0].items) as $items |
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

  retained=$(python3 - "$inventory" \
    "dev=$tmp_dir/dev-namespaces.json" "dev=$tmp_dir/dev-pvcs.json" "dev=$tmp_dir/dev-snapshots.json" \
    "dev=$tmp_dir/recovery-namespaces.json" "dev=$tmp_dir/recovery-pvcs.json" "dev=$tmp_dir/recovery-snapshots.json" \
    "prod=$tmp_dir/prod-namespaces.json" "prod=$tmp_dir/prod-pvcs.json" "prod=$tmp_dir/prod-snapshots.json" \
    "dev=$tmp_dir/dev-snapshotcontents.json" "prod=$tmp_dir/prod-snapshotcontents.json" <<'PY'
import json, sys
from pathlib import Path

inventory_path = Path(sys.argv[1])
inventory = json.loads(inventory_path.read_text())
resources = inventory["resources"]
result = []
seen = set()
snapshots = {"dev": set(), "prod": set()}
documents = []
for entry in sys.argv[2:]:
    environment, path = entry.split("=", 1)
    document = json.loads(Path(path).read_text())
    if not isinstance(document.get("items"), list):
        raise SystemExit("FAIL: retained-object query returned a non-list response")
    documents.append((environment, document))
    for item in document["items"]:
        if item.get("kind") == "VolumeSnapshot":
            metadata = item.get("metadata", {})
            snapshots[environment].add((metadata.get("namespace"), metadata.get("name"), metadata.get("uid")))

for environment, document in documents:
    for item in document["items"]:
        kind = item.get("kind")
        if kind not in {"PersistentVolumeClaim", "VolumeSnapshot", "VolumeSnapshotContent", "Namespace"}:
            continue
        metadata = item.get("metadata", {})
        namespace = metadata.get("namespace")
        name = metadata.get("name")
        uid = metadata.get("uid")
        if kind in {"Namespace", "VolumeSnapshotContent"}:
            namespace = ""
        if not all(isinstance(value, str) and value for value in (name, uid)) or not isinstance(namespace, str):
            raise SystemExit(f"FAIL: retained {kind} identity is incomplete")
        if kind == "VolumeSnapshotContent":
            reference = item.get("spec", {}).get("volumeSnapshotRef", {})
            linked = (reference.get("namespace"), reference.get("name"), reference.get("uid"))
            if linked not in snapshots[environment]:
                continue
        inventory_id = name if kind in {"Namespace", "VolumeSnapshotContent"} else f"{namespace}/{name}"
        matches = [resource for resource in resources if resource.get("kind") == kind
                   and resource.get("environment") == environment and resource.get("decision") == "RETAIN"
                   and resource.get("id") == inventory_id]
        if len(matches) != 1:
            raise SystemExit(f"FAIL: retained {kind} {inventory_id} is not uniquely approved by ownership inventory")
        key = (environment, namespace, kind, name, uid)
        if key in seen:
            raise SystemExit("FAIL: duplicate retained object identity")
        seen.add(key)
        result.append({"environment": environment, "namespace": namespace,
                       "kind": kind, "name": name, "uid": uid,
                       "classification": matches[0]["classification"],
                       "requiresExplicitDeletion": True})

supported = {"PersistentVolumeClaim", "VolumeSnapshot", "VolumeSnapshotContent", "Namespace"}
expected = [item for item in resources if item.get("kind") in supported
            and item.get("environment") in ("dev", "prod") and item.get("decision") == "RETAIN"]
if len(expected) != len(result):
    raise SystemExit("FAIL: ownership inventory retained-object set differs from live clusters")
result.sort(key=lambda item: (item["environment"], item["namespace"], item["kind"], item["name"], item["uid"]))
print(json.dumps(result, sort_keys=True, separators=(",", ":")))
PY
  ) || exit 1

  jq -e '
    [.resources[] | select(.kind == "SecretsManagerSecret")] as $providers |
    ($providers | length) > 0 and all($providers[]; .decision == "RETAIN" or .decision == "EXTERNAL_SHARED")
  ' "$inventory" >/dev/null || {
    echo "FAIL: every provider Secret must be explicitly retained or externally shared" >&2
    exit 1
  }
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
  done < <(jq -c '.resources[] | select(.kind == "SecretsManagerSecret" and (.decision == "RETAIN" or .decision == "EXTERNAL_SHARED"))' "$inventory")
  ((provider_count > 0)) || {
    echo "FAIL: ownership inventory contains no provider Secrets" >&2
    exit 1
  }

  freeze_sha=$(shasum -a 256 "$freeze" | awk '{print $1}')
  provider_sha=$(jq -cS '[.resources[] | select(.kind == "SecretsManagerSecret")] | sort_by(.environment,.id)' \
    "$inventory" | shasum -a 256 | awk '{print $1}')
  observed=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  while ! jq -e --arg observed "$observed" \
    '(.observedAt | fromdateiso8601) < ($observed | fromdateiso8601)' "$freeze" >/dev/null; do
    sleep 1
    observed=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  done
  jq -n --arg revision "$git_revision" --arg freeze "$freeze_sha" --arg provider "$provider_sha" \
    --arg grade "$evidence_grade" \
    --arg observed "$observed" --argjson clusters "$(jq -c '[.clusters[] | {environment,clusterArn}]' "$freeze")" \
    --argjson remaining "$summary" --argjson retained "$retained" '
    {
      schemaVersion:"course.gitops-removal/v1",evidenceGrade:$grade,status:"REMOVED",
      gitopsRevision:$revision,freezeEvidenceSha256:$freeze,clusters:$clusters,
      remaining:$remaining,retained:$retained,
      providerSecrets:{retained:true,inventorySha256:$provider},observedAt:$observed
    }
  ' >"$tmp" || {
    echo "FAIL: unable to construct GitOps removal evidence" >&2
    exit 1
  }
  chmod 600 "$tmp"
  mv "$tmp" "$output_path"
  rm -rf -- "$tmp_dir"
  trap - EXIT
fi
echo "[$evidence_grade] wrote $output_path"
