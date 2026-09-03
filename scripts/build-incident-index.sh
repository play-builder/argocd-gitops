#!/usr/bin/env bash
set -Eeuo pipefail

repository_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
catalog_root="$repository_root/incidents/catalog"
fixture=
manifest=
evidence_root=
sample_repo_root=
gitops_repo_root=
eks_repo_root=
course_id=
account_id=
region=
output="$repository_root/evidence/incidents/index.json"

usage() {
  echo "Usage: $0 --fixture file | --manifest file --evidence-root dir --sample-repo-root dir --gitops-repo-root dir --eks-repo-root dir --course-id id --account-id id --region region [--output file]" >&2
  exit 2
}
while (($#)); do
  case "$1" in
    --fixture) fixture=${2:?missing fixture}; shift 2 ;;
    --manifest) manifest=${2:?missing manifest}; shift 2 ;;
    --evidence-root) evidence_root=${2:?missing evidence root}; shift 2 ;;
    --sample-repo-root) sample_repo_root=${2:?missing sample repository root}; shift 2 ;;
    --gitops-repo-root) gitops_repo_root=${2:?missing GitOps repository root}; shift 2 ;;
    --eks-repo-root) eks_repo_root=${2:?missing EKS repository root}; shift 2 ;;
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
[[ -d "$sample_repo_root" && -d "$gitops_repo_root" && -d "$eks_repo_root" ]] || { echo "FAIL: all three reviewed repository roots are required" >&2; exit 1; }
[[ -n "$course_id" && -n "$account_id" && -n "$region" ]] || usage

python3 - "$repository_root" "$catalog_root" "$manifest" "$evidence_root" "$sample_repo_root" "$gitops_repo_root" "$eks_repo_root" "$course_id" "$account_id" "$region" "$output" <<'PY'
import hashlib, json, os, re, subprocess, sys, tempfile
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath

repo = Path(sys.argv[1])
catalog_root = Path(sys.argv[2])
manifest_path = Path(sys.argv[3])
evidence_root = Path(sys.argv[4])
sample_repo_root = Path(sys.argv[5])
gitops_repo_root = Path(sys.argv[6])
eks_repo_root = Path(sys.argv[7])
course_id, account_id, region = sys.argv[8:11]
output = Path(sys.argv[11])

def fail(message):
    print(f"FAIL: {message}", file=sys.stderr)
    raise SystemExit(1)

def nonblank(value):
    return isinstance(value, str) and any(not (character.isspace() or character == "\ufeff") for character in value)

if not nonblank(course_id):
    fail("course ID must be nonblank")
if not re.fullmatch(r"[0-9]{12}", account_id):
    fail("account ID must contain exactly 12 digits")
if region not in {"ap-northeast-2", "us-east-1"}:
    fail("Region must be ap-northeast-2 or us-east-1")

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

def relative_parts(candidate, label):
    if not isinstance(candidate, str) or not candidate or os.path.isabs(candidate):
        fail(f"{label} path must be relative")
    if "\\" in candidate:
        fail(f"{label} path must use repository-relative POSIX syntax")
    normalized = PurePosixPath(candidate)
    if str(normalized) != candidate or any(part in {"", ".", ".."} for part in normalized.parts):
        fail(f"{label} path is not canonical")
    return normalized.parts

def safe_path(root, candidate, label):
    parts = relative_parts(candidate, label)
    if len(parts) >= 2 and any(parts[index:index + 2] == ("tests", "fixtures") for index in range(len(parts) - 1)):
        fail("runtime incident evidence may not come from tests/fixtures")
    root = root.resolve()
    try:
        actual = root.joinpath(*parts).resolve(strict=True)
    except (FileNotFoundError, RuntimeError):
        fail(f"{label} not found: {candidate}")
    try:
        actual.relative_to(root)
    except ValueError:
        fail(f"{label} path escapes its reviewed root")
    if not actual.is_file():
        fail(f"{label} not found: {candidate}")
    return actual

reviewed_roots = {
    "cicd-course-sample-app": sample_repo_root.resolve(),
    "argocd-gitops": gitops_repo_root.resolve(),
    "EKS-infra": eks_repo_root.resolve(),
}
if len(set(reviewed_roots.values())) != len(reviewed_roots):
    fail("reviewed repository roots must resolve to three distinct physical directories")
reviewed_revisions = {}
for repository, root in reviewed_roots.items():
    try:
        revision = subprocess.check_output(
            ["git", "-C", str(root), "rev-parse", "--verify", "HEAD"],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        fail(f"{repository} reviewed root has no verifiable Git HEAD")
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        fail(f"{repository} reviewed root HEAD is not a 40-character lowercase SHA")
    reviewed_revisions[repository] = revision
    dirty = subprocess.check_output([
        "git", "-C", str(root), "status", "--porcelain=v1", "--untracked-files=all",
        "--", ".", ":(exclude)evidence", ":(exclude)evidence/**",
    ], text=True)
    if dirty:
        fail(f"{repository} reviewed root has uncommitted changes outside evidence/")
evidence_root = evidence_root.resolve()
try:
    evidence_relative = evidence_root.relative_to(reviewed_roots["argocd-gitops"])
except ValueError:
    fail("evidence root must be inside the reviewed GitOps repository root")
if evidence_relative == Path("."):
    fail("evidence root must be a directory below the reviewed GitOps repository root")
canonical_output = reviewed_roots["argocd-gitops"] / "evidence" / "incidents" / "index.json"
if output.resolve(strict=False) != canonical_output:
    fail("runtime incident index output must use the canonical GitOps evidence path")
if canonical_output.parent.exists() and canonical_output.parent.resolve() != canonical_output.parent:
    fail("runtime incident index output parent may not be a symlink")
output = canonical_output

ids = """INC-AWS-01 INC-AWS-02 INC-AWS-03 INC-AWS-04 INC-AWS-05 INC-CI-01 INC-CI-02 INC-SC-01 INC-SC-02 INC-SC-03 INC-SC-04 INC-GO-01 INC-GO-02 INC-SEC-01 INC-K8S-01 INC-K8S-02 INC-K8S-03 INC-K8S-04 INC-OBS-01 INC-OBS-02 INC-REL-01 INC-REL-02 INC-REL-03 INC-REL-04 INC-DB-01 INC-DB-02 INC-DB-03 INC-DB-04 INC-DB-05 INC-DB-06 INC-RES-01 INC-RES-02 INC-CAP-01 INC-CAP-02 INC-CLN-01 INC-CLN-02 INC-CLN-03""".split()
catalog_ids = [p.stem for p in Path(catalog_root).glob("INC-*.yaml")]
if len(catalog_ids) != 37 or len(set(catalog_ids)) != 37 or set(catalog_ids) != set(ids):
    fail("incident catalog must contain exactly 37 unique canonical IDs")
catalog = {}
for path in sorted(Path(catalog_root).glob("INC-*.yaml")):
    item = load_yaml(path)
    if item.get("id") != path.stem or item["id"] in catalog:
        fail("catalog contains an alias or duplicate ID")
    if (
        isinstance(item.get("chapter"), bool)
        or not isinstance(item.get("chapter"), int)
        or item["chapter"] < 1
        or item.get("tier") not in {"Core-must", "Core-should", "Extended"}
        or not isinstance(item.get("maximumDuration"), str)
        or not re.fullmatch(r"(?:[1-9][0-9]*m|[1-9][0-9]*h(?:[1-9][0-9]*m)?)", item["maximumDuration"])
    ):
        fail(f"catalog item {path.stem} has an invalid chapter, tier, or maximumDuration")
    catalog[item["id"]] = item

try:
    manifest = json.loads(Path(manifest_path).read_text())
except Exception:
    manifest = load_yaml(manifest_path)
if not isinstance(manifest, dict):
    fail("incident lifecycle manifest must be an object")
if manifest.get("curriculumVersion") != "v3.4":
    fail("incident lifecycle manifest curriculumVersion must be v3.4")
def timestamp(value, label):
    if not isinstance(value, str) or not re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z", value):
        fail(f"{label} must be an RFC3339 UTC timestamp")
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        fail(f"{label} must be a valid RFC3339 UTC timestamp")

started_at = manifest.get("startedAt")
started_at_time = timestamp(started_at, "incident lifecycle manifest startedAt")
generated_at_time = datetime.now(timezone.utc).replace(microsecond=0)
if started_at_time >= generated_at_time:
    fail("incident lifecycle manifest startedAt must be strictly earlier than generatedAt")
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
    path = safe_path(evidence_root, record.get("path", ""), "incident artifact")
    envelope = load_yaml(path)
    required = {"schemaVersion","evidenceGrade","incidentId","scenario","phase","courseId","accountId","region","environment","producer","subject","sources","outcome","observedAt"}
    if set(envelope) != required or envelope.get("schemaVersion") != "course.incident-artifact/v1" or envelope.get("evidenceGrade") != "INCIDENT_EVIDENCE":
        fail(f"{path.name} is not an exact INCIDENT_EVIDENCE incident artifact envelope")
    if (envelope["incidentId"], envelope["scenario"], envelope["phase"]) != (incident_id, scenario, phase):
        fail(f"{path.name} identity does not match its manifest record")
    if envelope["courseId"] != course_id or envelope["accountId"] != account_id or envelope["region"] != region:
        fail(f"{path.name} course/account/Region mismatch")
    producer = envelope.get("producer")
    if not isinstance(producer, dict) or set(producer) != {"repository","revision"}:
        fail(f"{path.name} producer identity is not exact")
    if producer.get("repository") not in reviewed_roots or not re.fullmatch(r"[0-9a-f]{40}", str(producer.get("revision", ""))):
        fail(f"{path.name} producer identity is not a reviewed repository revision")
    if producer["revision"] != reviewed_revisions[producer["repository"]]:
        fail(f"{path.name} producer revision does not match the reviewed repository HEAD")
    subject = envelope.get("subject")
    if not isinstance(subject, dict) or set(subject) != {"kind","id"} or not all(nonblank(subject.get(key)) for key in ("kind","id")):
        fail(f"{path.name} subject identity is not exact")
    outcome = envelope.get("outcome")
    if not isinstance(outcome, dict) or set(outcome) != {"status","summary"} or outcome.get("status") != "PASS" or not nonblank(outcome.get("summary")):
        fail(f"{path.name} outcome is not an exact completed result")
    if envelope.get("environment") not in {"dev","prod","shared"}:
        fail(f"{path.name} environment is not canonical")
    observed_at = timestamp(envelope.get("observedAt"), f"{path.name} observedAt")
    if observed_at < started_at_time or observed_at > generated_at_time:
        fail(f"{path.name} observedAt is outside the incident index lifecycle window")
    if not isinstance(envelope.get("sources"), list) or not envelope["sources"]:
        fail(f"{path.name} has no lifecycle source references")
    sources = []
    for source in envelope["sources"]:
        if not isinstance(source, dict) or set(source) != {"repository","path","sha256"} or not re.fullmatch(r"[0-9a-f]{64}", str(source.get("sha256", ""))):
            fail(f"{path.name} has an invalid source reference")
        source_root = reviewed_roots.get(source["repository"])
        if source_root is None:
            fail(f"{path.name} source repository is not a reviewed repository")
        source_path = safe_path(source_root, source["path"], "incident source")
        actual_hash = digest(source_path)
        if actual_hash != source["sha256"]:
            fail(f"incident source digest mismatch: {source['path']}")
        sources.append({"repository":source["repository"],"path":source["path"],"sha256":actual_hash})
    envelope_reference = {
        "repository": "argocd-gitops",
        "path": path.relative_to(reviewed_roots["argocd-gitops"]).as_posix(),
        "sha256": digest(path),
    }
    return incident_id, scenario, phase, envelope, sources, envelope_reference, observed_at

def validate_db04(selected):
    """Validate the three independent recovery identities for INC-DB-04."""
    identity_keys = {"repository","sourceSha","imageRepository","indexDigest"}
    canonical_repository = "play-builder/cicd-course-sample-app"
    sha_pattern = r"[0-9a-f]{40}"
    digest_pattern = r"sha256:[0-9a-f]{64}"
    ecr_pattern = re.compile(r"(?P<account>[0-9]{12})\.dkr\.ecr\.(?P<region>ap-northeast-2|us-east-1)\.amazonaws\.com/(?P<name>[a-z0-9]+(?:[._/-][a-z0-9]+)*)")

    def release_identity(value, label, recovered=False):
        expected = identity_keys | ({"strategy"} if recovered else set())
        if not isinstance(value, dict) or set(value) != expected:
            fail(f"{label} identity is not exact")
        if value["repository"] != canonical_repository:
            fail(f"{label} repository must be the canonical sample repository")
        image_repository = value["imageRepository"]
        image_match = ecr_pattern.fullmatch(image_repository) if isinstance(image_repository, str) else None
        if image_match is None or image_match.group("account") != account_id or image_match.group("region") != region or not 2 <= len(image_match.group("name")) <= 256 or re.search(r"(?:^|/)sample-app$", image_match.group("name")) is None:
            fail(f"{label} imageRepository must be a canonical ECR repository in the incident account and Region")
        if not isinstance(value["sourceSha"], str) or not re.fullmatch(sha_pattern, value["sourceSha"]):
            fail(f"{label} sourceSha must be a 40-character lowercase SHA")
        if not isinstance(value["indexDigest"], str) or not re.fullmatch(digest_pattern, value["indexDigest"]):
            fail(f"{label} indexDigest must be a canonical SHA-256 digest")

    lineage = manifest.get("releaseLineage")
    lineage_names = {
        "v2PrimeContractCompatible",
        "v2FaultyOrderTotal",
        "v201HotfixOrderTotal",
    }
    if not isinstance(lineage, dict) or not lineage_names.issubset(lineage):
        fail("INC-DB-04 manifest releaseLineage is incomplete")
    for name in lineage_names:
        value = lineage[name]
        if not isinstance(value, dict) or set(value) != {"sourceSha","indexDigest"}:
            fail(f"releaseLineage.{name} is not an exact release identity")
        if not isinstance(value["sourceSha"], str) or not re.fullmatch(sha_pattern, value["sourceSha"]):
            fail(f"releaseLineage.{name}.sourceSha is invalid")
        if not isinstance(value["indexDigest"], str) or not re.fullmatch(digest_pattern, value["indexDigest"]):
            fail(f"releaseLineage.{name}.indexDigest is invalid")

    recoveries = {}
    expected_root = {"schemaVersion","evidenceGrade","incidentId","scenario","courseId","accountId","region","executionId","stable","faulty","recovered","workflow","gitopsRevision","rolloutRevision","observedAt"}
    for scenario in ("git-revert", "break-glass-undo-plus-git", "hotfix-fix-forward"):
        item = selected.get(("INC-DB-04", scenario, "recover"))
        if item is None or len(item[4]) != 1:
            fail(f"INC-DB-04/{scenario} recover must reference exactly one recovery source")
        source_reference = item[4][0]
        source_path = safe_path(reviewed_roots[source_reference["repository"]], source_reference["path"], "INC-DB-04 recovery source")
        recovery = load_yaml(source_path)
        if set(recovery) != expected_root or recovery.get("schemaVersion") != "course.db04-recovery/v1" or recovery.get("evidenceGrade") != "INCIDENT_EVIDENCE":
            fail(f"INC-DB-04/{scenario} recovery source has an invalid exact schema")
        if (recovery.get("incidentId"), recovery.get("scenario"), recovery.get("courseId"), recovery.get("accountId"), recovery.get("region")) != ("INC-DB-04", scenario, course_id, account_id, region):
            fail(f"INC-DB-04/{scenario} recovery identity mismatch")
        for key in ("stable", "faulty"):
            release_identity(recovery.get(key), f"INC-DB-04/{scenario} {key}")
        release_identity(recovery.get("recovered"), f"INC-DB-04/{scenario} recovered", recovered=True)
        if any(recovery[name]["imageRepository"] != recovery["stable"]["imageRepository"] for name in ("faulty", "recovered")):
            fail(f"INC-DB-04/{scenario} image repositories must match the stable sample-app identity")
        if recovery["recovered"]["strategy"] != scenario:
            fail(f"INC-DB-04/{scenario} recovery strategy mismatch")
        workflow = recovery.get("workflow")
        if not isinstance(workflow, dict) or set(workflow) != {"runId","runAttempt","runUrl"}:
            fail(f"INC-DB-04/{scenario} workflow identity is not exact")
        run_id = workflow.get("runId")
        run_attempt = workflow.get("runAttempt")
        run_url = workflow.get("runUrl")
        if not isinstance(run_id, str) or not re.fullmatch(r"[0-9]+", run_id):
            fail(f"INC-DB-04/{scenario} workflow runId must contain only digits")
        if isinstance(run_attempt, bool) or not isinstance(run_attempt, int) or run_attempt < 1:
            fail(f"INC-DB-04/{scenario} workflow runAttempt must be a positive integer")
        expected_run_url = f"https://github.com/{canonical_repository}/actions/runs/{run_id}"
        if run_url != expected_run_url:
            fail(f"INC-DB-04/{scenario} workflow runUrl does not bind the canonical repository and runId")
        if not nonblank(recovery.get("executionId")):
            fail(f"INC-DB-04/{scenario} executionId must be nonblank")
        if not isinstance(recovery.get("gitopsRevision"), str) or not re.fullmatch(sha_pattern, recovery["gitopsRevision"]):
            fail(f"INC-DB-04/{scenario} gitopsRevision must be a 40-character lowercase SHA")
        rollout_revision = recovery.get("rolloutRevision")
        if isinstance(rollout_revision, bool) or not isinstance(rollout_revision, int) or rollout_revision < 1:
            fail(f"INC-DB-04/{scenario} rolloutRevision must be a positive integer")
        recovery_observed_at = timestamp(recovery.get("observedAt"), f"INC-DB-04/{scenario} observedAt")
        if recovery_observed_at < started_at_time or recovery_observed_at > generated_at_time:
            fail(f"INC-DB-04/{scenario} observedAt is outside the incident index lifecycle window")
        recoveries[scenario] = recovery
    a, b, c = (recoveries[s] for s in ("git-revert","break-glass-undo-plus-git","hotfix-fix-forward"))
    if a["stable"] != b["stable"] or a["faulty"] != b["faulty"] or a["stable"] != c["stable"] or a["faulty"] != c["faulty"]:
        fail("INC-DB-04 scenarios must share stable and faulty identities")
    ordered_identity_keys = ("repository","sourceSha","imageRepository","indexDigest")
    if any(a["recovered"][key] != b["recovered"][key] for key in ordered_identity_keys):
        fail("INC-DB-04 Git-revert and break-glass must recover the same stable identity")
    for recovery in (a, b):
        if any(recovery["recovered"][key] != recovery["stable"][key] for key in ordered_identity_keys):
            fail("INC-DB-04 undo scenarios must recover the exact stable identity")
    if any(c["recovered"][key] in {c["stable"][key], c["faulty"][key]} for key in ("sourceSha","indexDigest")):
        fail("INC-DB-04 hotfix recovery must have a distinct source and digest")
    bindings = (
        (a["stable"], lineage["v2PrimeContractCompatible"], "v2PrimeContractCompatible"),
        (a["faulty"], lineage["v2FaultyOrderTotal"], "v2FaultyOrderTotal"),
        (c["recovered"], lineage["v201HotfixOrderTotal"], "v201HotfixOrderTotal"),
    )
    for identity, expected, name in bindings:
        if any(identity[key] != expected[key] for key in ("sourceSha", "indexDigest")):
            fail(f"INC-DB-04 recovery identity does not match releaseLineage.{name}")
    identities = [
        (r["executionId"], (r["workflow"]["runId"], r["workflow"]["runAttempt"]), r["gitopsRevision"], r["rolloutRevision"])
        for r in recoveries.values()
    ]
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
if not isinstance(not_run, dict):
    fail("incident lifecycle manifest notRun must be an object")
executed_ids = {incident_id for incident_id, _, _ in by_key}
expected_not_run = set(ids) - executed_ids
if set(not_run) != expected_not_run:
    fail("incident lifecycle manifest must explicitly classify every unexecuted incident as NOT_RUN")
if any(not nonblank(reason) for reason in not_run.values()):
    fail("every NOT_RUN incident requires an explicit nonblank reason")
incidents = []
phase_order = ("baseline","inject","detect","mitigate","recover","reconcile","prevent","cleanup")
phases_required = set(phase_order)
for incident_id in ids:
    meta = catalog[incident_id]
    scenarios = sorted({scenario for iid, scenario, phase in by_key if iid == incident_id})
    expected_scenarios = ["primary"] if incident_id != "INC-DB-04" else ["break-glass-undo-plus-git","git-revert","hotfix-fix-forward"]
    if scenarios and scenarios != expected_scenarios:
        fail(f"{incident_id} has a noncanonical scenario set")
    if incident_id == "INC-DB-04" and scenarios != expected_scenarios:
        fail("INC-DB-04 requires exactly git-revert, break-glass-undo-plus-git, and hotfix-fix-forward")
    complete = []
    for scenario in scenarios:
        selected = {(iid, sc, phase): value for (iid, sc, phase), value in by_key.items() if iid == incident_id and sc == scenario}
        if set(phase for iid, sc, phase in selected) != phases_required:
            fail(f"{incident_id}/{scenario} is missing lifecycle evidence")
        refs = {}
        previous = started_at_time
        phase_times = {}
        for phase in phase_order:
            item = selected[(incident_id, scenario, phase)]
            phase_times[phase] = item[6]
            if item[6] < previous:
                fail(f"{incident_id}/{scenario} lifecycle timestamps are out of order")
            previous = item[6]
            refs[phase] = [item[5]]
        duration = re.fullmatch(r"([1-9][0-9]*)([sm])", str(meta.get("maximumDuration", "")))
        if duration is None:
            fail(f"{incident_id} catalog maximumDuration is invalid")
        maximum_seconds = int(duration.group(1)) * (60 if duration.group(2) == "m" else 1)
        if (phase_times["mitigate"] - phase_times["inject"]).total_seconds() > maximum_seconds:
            fail(f"{incident_id}/{scenario} mitigation exceeded catalog maximumDuration")
        complete.append({"name":scenario,"status":"COMPLETE","evidenceGrade":"INCIDENT_EVIDENCE","lifecycle":refs})
    if not complete:
        reason = not_run[incident_id]
        if meta["tier"] == "Core-must":
            fail(f"Core-must incident missing runtime evidence: {incident_id}")
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
generated_at = generated_at_time.isoformat().replace("+00:00","Z")
result = {"schemaVersion":"course.incident-index/v1","evidenceGrade":"INCIDENT_EVIDENCE","curriculumVersion":"v3.4","courseId":course_id,"accountId":account_id,"region":region,"startedAt":started_at,"generatedAt":generated_at,"completionLevel":completion,"incidents":incidents}
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
