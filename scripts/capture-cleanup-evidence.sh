#!/usr/bin/env bash
set -Eeuo pipefail

repository_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
evidence_root="$repository_root/evidence/cleanup"
mode=${1:-}
shift || true
fixture=
eks_repo_root=
usage() { echo "Usage: $0 freeze|removal [--fixture file] [--eks-repo-root dir]" >&2; exit 2; }
while (($#)); do
  case "$1" in
    --fixture) fixture=${2:?missing fixture}; shift 2 ;;
    --eks-repo-root) eks_repo_root=${2:?missing EKS repository root}; shift 2 ;;
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
  echo "FAIL: removal capture requires a validated freeze.json and live removal query" >&2
  exit 1
fi
echo "[CLOUD_RUNTIME] wrote $evidence_root/$mode.json"
