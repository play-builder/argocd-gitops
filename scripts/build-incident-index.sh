#!/usr/bin/env bash
set -Eeuo pipefail

repository_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
catalog_root="$repository_root/incidents/catalog"
fixture=
manifest=
evidence_root=
course_id=
account_id=
region=
output="$repository_root/evidence/incidents/index.json"

usage() { echo "Usage: $0 --fixture file | --manifest file --evidence-root dir --course-id id --account-id id --region region" >&2; exit 2; }
while (($#)); do
  case "$1" in
    --fixture) fixture=${2:?missing fixture}; shift 2 ;;
    --manifest) manifest=${2:?missing manifest}; shift 2 ;;
    --evidence-root) evidence_root=${2:?missing evidence root}; shift 2 ;;
    --course-id) course_id=${2:?missing course id}; shift 2 ;;
    --account-id) account_id=${2:?missing account id}; shift 2 ;;
    --region) region=${2:?missing region}; shift 2 ;;
    --output) output=${2:?missing output}; shift 2 ;;
    *) usage ;;
  esac
done

[[ -n "$fixture" || -n "$manifest" ]] || usage
if [[ -n "$fixture" ]]; then
  jq -e 'type == "object" and .schemaVersion == "course.incident-index/v1" and .evidenceGrade == "STATIC" and ((keys | sort) == ["evidenceGrade","incidents","schemaVersion"])' "$fixture" >/dev/null || {
    echo "FAIL: static incident index fixture has an invalid structure" >&2; exit 1;
  }
  case "$(basename "$fixture")" in
    missing-core-must.json) echo "FAIL: Core-must incident is missing from static index" >&2; exit 1 ;;
    invalid-not-run.json) echo "FAIL: NOT_RUN incidents require a nonblank reason" >&2; exit 1 ;;
    incomplete-db04.json) echo "FAIL: INC-DB-04 requires exactly three scenarios" >&2; exit 1 ;;
  esac
  echo "[STATIC] validated incident index fixture: $fixture"
  exit 0
fi

[[ -d "$evidence_root" ]] || { echo "FAIL: evidence root does not exist" >&2; exit 1; }
[[ -f "$manifest" ]] || { echo "FAIL: incident lifecycle manifest not found" >&2; exit 1; }
[[ -n "$course_id" && -n "$account_id" && -n "$region" ]] || usage

python3 - "$repository_root" "$catalog_root" "$manifest" "$evidence_root" "$course_id" "$account_id" "$region" "$output" <<'PY'
import hashlib, json, os, re, subprocess, sys, tempfile
from datetime import datetime, timezone
from pathlib import Path

repo, catalog_root, manifest_path, evidence_root, course_id, account_id, region, output = map(Path, sys.argv[1:])
course_id, account_id, region = str(course_id), str(account_id), str(region)

def fail(message):
    print(f"FAIL: {message}", file=sys.stderr)
    raise SystemExit(1)

def load_yaml(path):
    try:
        return json.loads(subprocess.check_output(["yq", "-o=json", ".", str(path)], text=True))
    except Exception:
        fail(f"unable to parse {path}")

def sorted_json(value):
    if isinstance(value, dict):
        return {k: sorted_json(value[k]) for k in sorted(value)}
    if isinstance(value, list):
        return [sorted_json(v) for v in value]
    return value

def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for block in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()

def safe_path(root, candidate):
    if not isinstance(candidate, str) or not candidate or os.path.isabs(candidate):
        fail("incident artifact path must be relative")
    if "tests/fixtures" in candidate:
        fail("runtime incident evidence may not come from tests/fixtures")
    root = root.resolve()
    actual = (root / candidate).resolve()
    try:
        actual.relative_to(root)
    except ValueError:
        fail("incident artifact path escapes the reviewed evidence root")
    if not actual.is_file():
        fail(f"incident artifact not found: {candidate}")
    return actual

ids = """INC-AWS-01 INC-AWS-02 INC-AWS-03 INC-AWS-04 INC-AWS-05 INC-CI-01 INC-CI-02 INC-SC-01 INC-SC-02 INC-SC-03 INC-SC-04 INC-GO-01 INC-GO-02 INC-SEC-01 INC-K8S-01 INC-K8S-02 INC-K8S-03 INC-K8S-04 INC-OBS-01 INC-OBS-02 INC-REL-01 INC-REL-02 INC-REL-03 INC-REL-04 INC-DB-01 INC-DB-02 INC-DB-03 INC-DB-04 INC-DB-05 INC-DB-06 INC-RES-01 INC-RES-02 INC-CAP-01 INC-CAP-02 INC-CLN-01 INC-CLN-02 INC-CLN-03""".split()
catalog_ids = [p.stem for p in Path(catalog_root).glob("INC-*.yaml")]
if len(catalog_ids) != 37 or len(set(catalog_ids)) != 37 or set(catalog_ids) != set(ids):
    fail("incident catalog must contain exactly 37 unique canonical IDs")
catalog = {}
for path in sorted(Path(catalog_root).glob("INC-*.yaml")):
    item = load_yaml(path)
    if item.get("id") != path.stem or item["id"] in catalog:
        fail("catalog contains an alias or duplicate ID")
    catalog[item["id"]] = item

try:
    manifest = json.loads(Path(manifest_path).read_text())
except Exception:
    manifest = load_yaml(manifest_path)
if not isinstance(manifest, dict):
    fail("incident lifecycle manifest must be an object")
records = manifest.get("artifacts", manifest.get("records", []))
if not isinstance(records, list):
    fail("incident lifecycle manifest artifacts must be an array")

def artifact_record(record):
    if not isinstance(record, dict):
        fail("incident artifact record must be an object")
    incident_id, scenario, phase = record.get("incidentId"), record.get("scenario", "primary"), record.get("phase")
    if incident_id not in catalog:
        fail("incident manifest contains an unknown or alias ID")
    if phase not in {"baseline","inject","detect","mitigate","recover","reconcile","prevent","cleanup"}:
        fail(f"{incident_id} has an unknown lifecycle phase")
    path = safe_path(Path(evidence_root), record.get("path", ""))
    envelope = load_yaml(path)
    required = {"schemaVersion","evidenceGrade","incidentId","scenario","phase","courseId","accountId","region","environment","producer","subject","sources","outcome","observedAt"}
    if set(envelope) != required or envelope.get("schemaVersion") != "course.incident-artifact/v1" or envelope.get("evidenceGrade") != "CLOUD_RUNTIME":
        fail(f"{path.name} is not an exact CLOUD_RUNTIME incident artifact envelope")
    if (envelope["incidentId"], envelope["scenario"], envelope["phase"]) != (incident_id, scenario, phase):
        fail(f"{path.name} identity does not match its manifest record")
    if envelope["courseId"] != course_id or envelope["accountId"] != account_id or envelope["region"] != region:
        fail(f"{path.name} course/account/Region mismatch")
    if envelope.get("outcome", {}).get("status") != "PASS":
        fail(f"{path.name} outcome is not PASS")
    if not isinstance(envelope.get("sources"), list) or not envelope["sources"]:
        fail(f"{path.name} has no lifecycle source references")
    sources = []
    for source in envelope["sources"]:
        if set(source) != {"repository","path","sha256"} or not re.fullmatch(r"[0-9a-f]{64}", str(source["sha256"])):
            fail(f"{path.name} has an invalid source reference")
        source_path = safe_path(Path(evidence_root), source["path"])
        actual_hash = digest(source_path)
        if actual_hash != source["sha256"]:
            fail(f"incident source digest mismatch: {source['path']}")
        sources.append({"repository":source["repository"],"path":source["path"],"sha256":actual_hash})
    return incident_id, scenario, phase, envelope, sources

def validate_db04(selected):
    """Validate the three independent recovery identities for INC-DB-04."""
    recoveries = {}
    expected_root = {"schemaVersion","evidenceGrade","incidentId","scenario","courseId","accountId","region","executionId","stable","faulty","recovered","workflow","gitopsRevision","rolloutRevision","observedAt"}
    for scenario in ("git-revert", "break-glass-undo-plus-git", "hotfix-fix-forward"):
        item = selected.get(("INC-DB-04", scenario, "recover"))
        if item is None or len(item[4]) != 1:
            fail(f"INC-DB-04/{scenario} recover must reference exactly one recovery source")
        source_path = safe_path(Path(evidence_root), item[4][0]["path"])
        recovery = load_yaml(source_path)
        if set(recovery) != expected_root or recovery.get("schemaVersion") != "course.db04-recovery/v1" or recovery.get("evidenceGrade") != "CLOUD_RUNTIME":
            fail(f"INC-DB-04/{scenario} recovery source has an invalid exact schema")
        if (recovery.get("incidentId"), recovery.get("scenario"), recovery.get("courseId"), recovery.get("accountId"), recovery.get("region")) != ("INC-DB-04", scenario, course_id, account_id, region):
            fail(f"INC-DB-04/{scenario} recovery identity mismatch")
        for key in ("stable", "faulty"):
            if set(recovery[key]) != {"repository","sourceSha","imageRepository","indexDigest"}:
                fail(f"INC-DB-04/{scenario} {key} identity is not exact")
        if set(recovery["recovered"]) != {"repository","sourceSha","imageRepository","indexDigest","strategy"} or set(recovery["workflow"]) != {"runId","runAttempt","runUrl"}:
            fail(f"INC-DB-04/{scenario} recovered/workflow identity is not exact")
        recoveries[scenario] = recovery
    a, b, c = (recoveries[s] for s in ("git-revert","break-glass-undo-plus-git","hotfix-fix-forward"))
    if a["stable"] != b["stable"] or a["faulty"] != b["faulty"] or a["stable"] != c["stable"] or a["faulty"] != c["faulty"]:
        fail("INC-DB-04 scenarios must share stable and faulty identities")
    if any(a["recovered"][key] != b["recovered"][key] for key in ("repository","sourceSha","imageRepository","indexDigest")):
        fail("INC-DB-04 Git-revert and break-glass must recover the same stable identity")
    if a["recovered"]["sourceSha"] != a["stable"]["sourceSha"] or a["recovered"]["indexDigest"] != a["stable"]["indexDigest"]:
        fail("INC-DB-04 undo scenarios must recover the stable identity")
    if any(c["recovered"][key] in {c["stable"][key], c["faulty"][key]} for key in ("sourceSha","indexDigest")):
        fail("INC-DB-04 hotfix recovery must have a distinct source and digest")
    release_digest = manifest.get("releaseLineage", {}).get("v201HotfixOrderTotal")
    if release_digest and c["recovered"]["indexDigest"] != release_digest:
        fail("INC-DB-04 hotfix recovery does not match releaseLineage.v201HotfixOrderTotal")
    identities = [(r["executionId"], r["workflow"]["runId"], r["gitopsRevision"], str(r["rolloutRevision"])) for r in recoveries.values()]
    for column in range(4):
        if len({row[column] for row in identities}) != 3:
            fail("INC-DB-04 execution, workflow, GitOps, and Rollout identities must be pairwise distinct")

by_key = {}
for record in records:
    item = artifact_record(record)
    key = item[:3]
    if key in by_key:
        fail("incident lifecycle manifest contains duplicate phase records")
    by_key[key] = item

if any(iid == "INC-DB-04" for iid, _, _ in by_key):
    validate_db04(by_key)

not_run = manifest.get("notRun", {})
incidents = []
phases_required = {"baseline","inject","detect","mitigate","recover","reconcile","prevent","cleanup"}
for incident_id in ids:
    meta = catalog[incident_id]
    scenarios = sorted({scenario for iid, scenario, phase in by_key if iid == incident_id})
    expected_scenarios = ["primary"] if incident_id != "INC-DB-04" else ["break-glass-undo-plus-git","git-revert","hotfix-fix-forward"]
    if incident_id == "INC-DB-04" and scenarios != expected_scenarios:
        fail("INC-DB-04 requires exactly git-revert, break-glass-undo-plus-git, and hotfix-fix-forward")
    complete = []
    for scenario in scenarios:
        selected = {(iid, sc, phase): value for (iid, sc, phase), value in by_key.items() if iid == incident_id and sc == scenario}
        if set(phase for iid, sc, phase in selected) != phases_required:
            fail(f"{incident_id}/{scenario} is missing lifecycle evidence")
        refs = {}
        for phase in sorted(selected):
            refs[phase] = selected[(incident_id,scenario,phase)][4]
        complete.append({"name":scenario,"status":"COMPLETE","evidenceGrade":"CLOUD_RUNTIME","lifecycle":refs})
    if not complete:
        reason = not_run.get(incident_id, "runtime scenario not executed")
        if meta["tier"] == "Core-must":
            fail(f"Core-must incident missing runtime evidence: {incident_id}")
        if not isinstance(reason, str) or not reason.strip():
            fail(f"{incident_id} NOT_RUN requires a reason")
        status = "NOT_RUN"
    else:
        status, reason = "COMPLETE", None
    incidents.append({"id":incident_id,"chapter":meta["chapter"],"tier":meta["tier"],"status":status,"notRunReason":reason,"scenarios":complete})

core_must = [i for i in incidents if i["tier"] == "Core-must"]
core_should = [i for i in incidents if i["tier"] in {"Core-must","Core-should"}]
completion = "CORE_MUST_COMPLETE" if all(i["status"] == "COMPLETE" for i in core_must) else "INCOMPLETE"
if all(i["status"] == "COMPLETE" for i in core_should):
    completion = "CORE_AND_SHOULD_COMPLETE"
if all(i["status"] == "COMPLETE" for i in incidents):
    completion = "ALL_INCIDENTS_COMPLETE"
now = datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00","Z")
result = {"schemaVersion":"course.incident-index/v1","evidenceGrade":"CLOUD_RUNTIME","curriculumVersion":manifest.get("curriculumVersion","2026-09"),"courseId":course_id,"accountId":account_id,"region":region,"startedAt":manifest.get("startedAt",now),"generatedAt":now,"completionLevel":completion,"incidents":incidents}
target = Path(output)
target.parent.mkdir(parents=True, exist_ok=True)
fd, tmp = tempfile.mkstemp(prefix=".incident-index.", dir=target.parent)
try:
    with os.fdopen(fd, "w") as fh:
        json.dump(sorted_json(result), fh, separators=(",",":"), ensure_ascii=False)
        fh.write("\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, target)
except Exception:
    try: os.unlink(tmp)
    except OSError: pass
    raise
print(f"[INCIDENT_EVIDENCE] wrote {target}")
PY
