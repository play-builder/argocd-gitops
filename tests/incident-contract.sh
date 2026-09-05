#!/usr/bin/env bash
set -Eeuo pipefail

test_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd -- "$test_root/.." && pwd)
catalog_root="$repository_root/incidents/catalog"
expected_ids='INC-AWS-01 INC-AWS-02 INC-AWS-03 INC-AWS-04 INC-AWS-05 INC-CI-01 INC-CI-02 INC-SC-01 INC-SC-02 INC-SC-03 INC-SC-04 INC-GO-01 INC-GO-02 INC-SEC-01 INC-K8S-01 INC-K8S-02 INC-K8S-03 INC-K8S-04 INC-OBS-01 INC-OBS-02 INC-REL-01 INC-REL-02 INC-REL-03 INC-REL-04 INC-DB-01 INC-DB-02 INC-DB-03 INC-DB-04 INC-DB-05 INC-DB-06 INC-RES-01 INC-RES-02 INC-CAP-01 INC-CAP-02 INC-CLN-01 INC-CLN-02 INC-CLN-03'

fail() { echo "FAIL: $*" >&2; exit 1; }

validate_file() {
  local file=$1 json id case_name test_file
  [[ -f "$file" ]] || fail "incident file not found: $file"
  json=$(yq -o=json '.' "$file") || fail "$(basename "$file") is not valid YAML"
  jq -e '
    (keys | sort) == ["chapter","cleanup","evidence","id","inject","maximumDuration","preventionTest","scope","stop","tier"] and
    (.id | test("^INC-[A-Z0-9]+-[0-9]{2}$")) and
    (.chapter | type == "number") and (.tier | IN("Core-must","Core-should","Extended")) and
    (.maximumDuration | test("^[1-9][0-9]*[sm]$")) and
    (.scope | type == "object" and (.environment|type=="string" and length>0) and (.namespaces|type=="array" and length>0) and (.forbiddenNamespaces|type=="array")) and
    (.inject | type == "object" and (.action|type=="string" and length>0)) and
    (.stop | type == "object" and (.action|type=="string" and length>0)) and
    (.evidence | (keys|sort) == ["baseline","cleanup","detect","inject","mitigate","prevent","reconcile","recover"] and all(to_entries[]; .value|type=="array" and length>0)) and
    (.cleanup | type=="object" and (.action|type=="string" and length>0) and .externalSecretLifecycle.targetSecretOwnerReferenceGC == true and .externalSecretLifecycle.providerSecretRetained == true)
  ' <<<"$json" >/dev/null || fail "$(basename "$file") has an incomplete incident lifecycle"
  id=$(jq -r .id <<<"$json")
  case_name=$(jq -r '.preventionTest' <<<"$json")
  [[ "$case_name" =~ ^(tests/[A-Za-z0-9_./-]+\.sh)[[:space:]]--case[[:space:]]([A-Za-z0-9_.-]+)$ ]] || fail "$(basename "$file") has an unsafe preventionTest"
  test_file="$repository_root/${BASH_REMATCH[1]}"
  [[ -x "$test_file" ]] || fail "$(basename "$file") prevention test is not executable"
  grep -Eq "(case_|\|[[:space:]]*${BASH_REMATCH[2]}\)|${BASH_REMATCH[2]})" "$test_file" || fail "$(basename "$file") references an unknown prevention case"
  bash "$test_file" --case "${BASH_REMATCH[2]}" >/dev/null || fail "$(basename "$file") preventionTest failed"
}

validate_catalog() {
  local ids actual file
  [[ -d "$catalog_root" ]] || fail "incident catalog directory not found"
  actual=$(find "$catalog_root" -maxdepth 1 -type f -name 'INC-*.yaml' -exec basename {} .yaml \; | sort | tr '\n' ' ' | sed 's/[[:space:]]*$//')
  ids=$(printf '%s\n' $expected_ids | sort | tr '\n' ' ' | sed 's/[[:space:]]*$//')
  [[ "$actual" == "$ids" ]] || fail "incident catalog IDs do not match the canonical 37-ID set"
  for file in "$catalog_root"/INC-*.yaml; do validate_file "$file"; done
}

make_runtime_bundle() {
  local target=$1 grade=$2 curriculum=$3 started_at=$4 db04_mismatch=${5:-none}
  local course_id=${6:-course-ci} account_id=${7:-123456789012} region=${8:-us-east-1}
  python3 - "$repository_root" "$target" "$grade" "$curriculum" "$started_at" "$db04_mismatch" "$course_id" "$account_id" "$region" <<'PY'
import hashlib
import json
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

repository_root, target, grade, curriculum, started_at, db04_mismatch, course_id, account_id, region = sys.argv[1:]
target = Path(target)
roots = {
    "cicd-course-sample-app": target / "repos" / "cicd-course-sample-app",
    "argocd-gitops": target / "repos" / "argocd-gitops",
    "EKS-infra": target / "repos" / "EKS-infra",
}
for name, root in roots.items():
    source = root / "evidence" / "sources" / "common.json"
    source.parent.mkdir(parents=True, exist_ok=True)
    source.write_text('{"source":"shared-reviewed-bytes"}\n')
    subprocess.run(["git", "init", "-q", str(root)], check=True)
    subprocess.run(["git", "-C", str(root), "add", "."], check=True)
    subprocess.run([
        "git", "-C", str(root), "-c", "user.name=Contract Test",
        "-c", "user.email=contract@example.invalid", "commit", "-q", "-m", "reviewed source",
    ], check=True)
revisions = {
    name: subprocess.check_output(["git", "-C", str(root), "rev-parse", "HEAD"], text=True).strip()
    for name, root in roots.items()
}
gitops_root = roots["argocd-gitops"]
evidence_root = gitops_root / "evidence"

phases = ("baseline", "inject", "detect", "mitigate", "recover", "reconcile", "prevent", "cleanup")
phase_times = {
    phase: (datetime(2026, 9, 3, 1, 0, tzinfo=timezone.utc) + timedelta(seconds=30 * offset))
    .isoformat().replace("+00:00", "Z")
    for offset, phase in enumerate(phases)
}

catalog_root = Path(repository_root) / "incidents" / "catalog"
core_ids = []
all_ids = []
for path in sorted(catalog_root.glob("INC-*.yaml")):
    all_ids.append(path.stem)
    tier = subprocess.check_output(["yq", "-r", ".tier", str(path)], text=True).strip()
    if tier == "Core-must":
        core_ids.append(path.stem)

stable = {
    "repository": "play-builder/cicd-course-sample-app",
    "sourceSha": "1" * 40,
    "imageRepository": f"{account_id}.dkr.ecr.{region}.amazonaws.com/course/mini-commerce",
    "indexDigest": "sha256:" + "a" * 64,
}
faulty = {
    "repository": "play-builder/cicd-course-sample-app",
    "sourceSha": "2" * 40,
    "imageRepository": f"{account_id}.dkr.ecr.{region}.amazonaws.com/course/mini-commerce",
    "indexDigest": "sha256:" + "b" * 64,
}
hotfix = {
    "repository": "play-builder/cicd-course-sample-app",
    "sourceSha": "3" * 40,
    "imageRepository": f"{account_id}.dkr.ecr.{region}.amazonaws.com/course/mini-commerce",
    "indexDigest": "sha256:" + "c" * 64,
}
if db04_mismatch == "invalid-stable-source-sha":
    stable["sourceSha"] = "not-a-source-sha"
elif db04_mismatch == "invalid-stable-digest":
    stable["indexDigest"] = "sha256:bad"
elif db04_mismatch == "blank-stable-repository":
    stable["repository"] = " "
elif db04_mismatch == "blank-stable-image-repository":
    stable["imageRepository"] = " "
elif db04_mismatch == "arbitrary-release-repository":
    for identity in (stable, faulty, hotfix):
        identity["repository"] = "evil/other-app"
elif db04_mismatch == "non-ecr-image-repository":
    for identity in (stable, faulty, hotfix):
        identity["imageRepository"] = "not-ecr"
elif db04_mismatch == "cross-region-image-repository":
    other_region = "ap-northeast-2" if region == "us-east-1" else "us-east-1"
    for identity in (stable, faulty, hotfix):
        identity["imageRepository"] = f"{account_id}.dkr.ecr.{other_region}.amazonaws.com/course/mini-commerce"
elif db04_mismatch == "foreign-account-image-repository":
    foreign_account = "999999999999" if account_id != "999999999999" else "111111111111"
    for identity in (stable, faulty, hotfix):
        identity["imageRepository"] = f"{foreign_account}.dkr.ecr.{region}.amazonaws.com/course/mini-commerce"
elif db04_mismatch in {"one-character-image-repository", "noncanonical-image-repository"}:
    repository_name = {"one-character-image-repository": "a", "noncanonical-image-repository": "other-service"}[db04_mismatch]
    for identity in (stable, faulty, hotfix):
        identity["imageRepository"] = f"{account_id}.dkr.ecr.{region}.amazonaws.com/{repository_name}"
scenarios = ("git-revert", "break-glass-undo-plus-git", "hotfix-fix-forward")
recovery_sources = {}
for number, scenario in enumerate(scenarios, start=1):
    recovered = dict(hotfix if scenario == "hotfix-fix-forward" else stable)
    if db04_mismatch == scenario or (db04_mismatch == "undo-repository" and scenario != "hotfix-fix-forward"):
        recovered["repository"] = "play-builder/wrong-repository"
    recovered["strategy"] = scenario
    if db04_mismatch == "recovered-image-repository-mismatch" and scenario == "hotfix-fix-forward":
        recovered["imageRepository"] = f"{account_id}.dkr.ecr.{region}.amazonaws.com/other/mini-commerce"
    if db04_mismatch == "strategy-mismatch" and scenario == "git-revert":
        recovered["strategy"] = "hotfix-fix-forward"
    run_id = str(1000 + number)
    run_attempt = 1
    run_url = f"https://github.com/play-builder/cicd-course-sample-app/actions/runs/{run_id}"
    gitops_revision = str(number) * 40
    rollout_revision = number + 10
    recovery_observed_at = phase_times["recover"]
    execution_id = f"execution-{number}"
    if db04_mismatch == "invalid-workflow" and scenario == "git-revert":
        run_id = "run-one"
        run_url = "https://github.com/play-builder/cicd-course-sample-app/actions/runs/1001"
    elif db04_mismatch == "invalid-run-attempt" and scenario == "git-revert":
        run_attempt = 0
    elif db04_mismatch == "workflow-url-mismatch" and scenario == "git-revert":
        run_url = "https://github.com/play-builder/cicd-course-sample-app/actions/runs/9999"
    elif db04_mismatch == "workflow-repository-mismatch":
        run_url = f"https://github.com/evil/other-app/actions/runs/{run_id}"
    elif db04_mismatch == "invalid-gitops-revision" and scenario == "git-revert":
        gitops_revision = "not-a-git-sha"
    elif db04_mismatch == "invalid-rollout-revision" and scenario == "git-revert":
        rollout_revision = 0
    elif db04_mismatch == "invalid-recovery-time" and scenario == "git-revert":
        recovery_observed_at = "2025-12-31T23:59:59Z"
    elif db04_mismatch == "fractional-recovery-time" and scenario == "git-revert":
        recovery_observed_at = "2026-09-03T01:01:30.123Z"
    elif db04_mismatch == "blank-execution-id" and scenario == "git-revert":
        execution_id = " "
    elif db04_mismatch == "bom-execution-id" and scenario == "git-revert":
        execution_id = "\ufeff"
    recovery = {
        "schemaVersion": "course.db04-recovery/v1",
        "evidenceGrade": grade,
        "incidentId": "INC-DB-04",
        "scenario": scenario,
        "courseId": course_id,
        "accountId": account_id,
        "region": region,
        "executionId": execution_id,
        "stable": stable,
        "faulty": faulty,
        "recovered": recovered,
        "workflow": {
            "runId": run_id,
            "runAttempt": run_attempt,
            "runUrl": run_url,
        },
        "gitopsRevision": gitops_revision,
        "rolloutRevision": rollout_revision,
        "observedAt": recovery_observed_at,
    }
    path = roots["cicd-course-sample-app"] / "evidence" / "sources" / f"db04-{scenario}.json"
    path.write_text(json.dumps(recovery, separators=(",", ":")) + "\n")
    recovery_sources[scenario] = ("cicd-course-sample-app", path)

def relative(repository, path):
    return str(path.relative_to(roots[repository]))

def source_reference(repository, path):
    return {
        "repository": repository,
        "path": relative(repository, path),
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
    }

records = []
for incident_id in core_ids:
    incident_scenarios = scenarios if incident_id == "INC-DB-04" else ("primary",)
    if incident_id == "INC-AWS-01" and db04_mismatch == "alias-scenario":
        incident_scenarios = ("alternate",)
    elif incident_id == "INC-AWS-01" and db04_mismatch == "multiple-scenarios":
        incident_scenarios = ("primary", "secondary")
    for scenario in incident_scenarios:
        for phase_number, phase in enumerate(phases):
            source_repository = ("cicd-course-sample-app", "argocd-gitops", "EKS-infra")[phase_number % 3]
            source = roots[source_repository] / "evidence" / "sources" / "common.json"
            if incident_id == "INC-DB-04" and phase == "recover":
                source_repository, source = recovery_sources[scenario]
            artifact = {
                "schemaVersion": "course.incident-artifact/v1",
                "evidenceGrade": grade,
                "incidentId": incident_id,
                "scenario": scenario,
                "phase": phase,
                "courseId": course_id,
                "accountId": account_id,
                "region": region,
                "environment": "prod",
                "producer": {"repository": "argocd-gitops", "revision": revisions["argocd-gitops"]},
                "subject": {"kind": "Incident", "id": incident_id},
                "sources": [source_reference(source_repository, source)],
                "outcome": {"status": "PASS", "summary": f"{incident_id}/{scenario}/{phase} completed"},
                "observedAt": phase_times[phase],
            }
            artifact_path = evidence_root / "artifacts" / incident_id / scenario / f"{phase}.json"
            artifact_path.parent.mkdir(parents=True, exist_ok=True)
            artifact_path.write_text(json.dumps(artifact, separators=(",", ":")) + "\n")
            records.append({
                "incidentId": incident_id,
                "scenario": scenario,
                "phase": phase,
                "path": str(artifact_path.relative_to(evidence_root)),
            })

manifest = {
    "curriculumVersion": curriculum,
    "releaseLineage": {
        "v2PrimeContractCompatible": {"sourceSha": stable["sourceSha"], "indexDigest": stable["indexDigest"]},
        "v2FaultyOrderTotal": {"sourceSha": faulty["sourceSha"], "indexDigest": faulty["indexDigest"]},
        "v201HotfixOrderTotal": {"sourceSha": hotfix["sourceSha"], "indexDigest": hotfix["indexDigest"]},
    },
    "artifacts": records,
    "notRun": {
        incident_id: "not selected for this bounded runtime contract"
        for incident_id in all_ids if incident_id not in core_ids
    },
}
if db04_mismatch == "stable-lineage-mismatch":
    manifest["releaseLineage"]["v2PrimeContractCompatible"]["sourceSha"] = "f" * 40
elif db04_mismatch == "faulty-lineage-mismatch":
    manifest["releaseLineage"]["v2FaultyOrderTotal"]["indexDigest"] = "sha256:" + "d" * 64
elif db04_mismatch == "hotfix-lineage-mismatch":
    manifest["releaseLineage"]["v201HotfixOrderTotal"]["sourceSha"] = "f" * 40
if db04_mismatch == "missing-not-run":
    manifest["notRun"].pop(next(iter(manifest["notRun"])))
elif db04_mismatch == "blank-not-run":
    manifest["notRun"][next(iter(manifest["notRun"]))] = " "
elif db04_mismatch == "bom-not-run":
    manifest["notRun"][next(iter(manifest["notRun"]))] = "\ufeff"
if started_at != "MISSING":
    manifest["startedAt"] = started_at
(target / "manifest.json").write_text(json.dumps(manifest, separators=(",", ":")) + "\n")
PY
}

run_runtime_producer() {
  local bundle=$1 course_id=${2:-course-ci} account_id=${3:-123456789012} region=${4:-us-east-1}
  bash "$repository_root/scripts/build-incident-index.sh" \
    --manifest "$bundle/manifest.json" \
    --evidence-root "$bundle/repos/argocd-gitops/evidence" \
    --sample-repo-root "$bundle/repos/cicd-course-sample-app" \
    --gitops-repo-root "$bundle/repos/argocd-gitops" \
    --eks-repo-root "$bundle/repos/EKS-infra" \
    --course-id "$course_id" --account-id "$account_id" --region "$region" \
    --output "$bundle/repos/argocd-gitops/evidence/incidents/index.json"
}

mutate_runtime_bundle() {
  local bundle=$1 mutation=$2
  python3 - "$bundle" "$mutation" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

bundle, mutation = Path(sys.argv[1]), sys.argv[2]
artifact_root = bundle / "repos" / "argocd-gitops" / "evidence" / "artifacts" / "INC-AWS-01" / "primary"
artifact = artifact_root / "baseline.json"
value = json.loads(artifact.read_text())

if mutation == "producer-extra":
    value["producer"]["extra"] = True
elif mutation == "producer-unknown":
    value["producer"]["repository"] = "play-builder/argocd-gitops"
elif mutation == "producer-head-mismatch":
    value["producer"]["revision"] = "e" * 40
elif mutation == "subject-extra":
    value["subject"]["name"] = value["subject"]["id"]
elif mutation == "outcome-extra":
    value["outcome"]["details"] = "unreviewed"
elif mutation == "blank-summary":
    value["outcome"]["summary"] = " "
elif mutation == "bom-summary":
    value["outcome"]["summary"] = "\ufeff"
elif mutation == "bom-subject-kind":
    value["subject"]["kind"] = "\ufeff"
elif mutation == "bom-subject-id":
    value["subject"]["id"] = "\ufeff"
elif mutation == "invalid-environment":
    value["environment"] = "staging"
elif mutation == "invalid-observed-at":
    value["observedAt"] = "2026-09-03 01:00:00"
elif mutation == "fractional-observed-at":
    value["observedAt"] = "2026-09-03T01:00:00.123Z"
elif mutation == "outside-index-window":
    value["observedAt"] = "2025-12-31T23:59:59Z"
elif mutation == "source-extra":
    value["sources"][0]["extra"] = True
elif mutation == "source-path-base":
    artifact = artifact_root / "inject.json"
    value = json.loads(artifact.read_text())
    value["sources"][0]["path"] = "sources/common.json"
elif mutation == "phase-order":
    artifact = artifact_root / "detect.json"
    value = json.loads(artifact.read_text())
    value["observedAt"] = "2026-09-03T01:00:15Z"
elif mutation == "mitigation-duration":
    times = {
        "inject": "2026-09-03T01:00:30Z",
        "detect": "2026-09-03T01:01:00Z",
        "mitigate": "2026-09-03T01:06:00Z",
        "recover": "2026-09-03T01:06:30Z",
        "reconcile": "2026-09-03T01:07:00Z",
        "prevent": "2026-09-03T01:07:30Z",
        "cleanup": "2026-09-03T01:08:00Z",
    }
    for phase, observed_at in times.items():
        path = artifact_root / f"{phase}.json"
        document = json.loads(path.read_text())
        document["observedAt"] = observed_at
        path.write_text(json.dumps(document, separators=(",", ":")) + "\n")
    raise SystemExit(0)
else:
    raise SystemExit(f"unknown mutation: {mutation}")

artifact.write_text(json.dumps(value, separators=(",", ":")) + "\n")
PY
}

case_runtime_grade() {
  local work
  work=$(mktemp -d)
  trap 'rm -rf -- "$work"' RETURN

  make_runtime_bundle "$work/incident" INCIDENT_EVIDENCE v3.4 2026-09-03T00:00:00Z
  run_runtime_producer "$work/incident" >/dev/null || fail "runtime producer rejected INCIDENT_EVIDENCE artifacts"
  jq -e '
    .evidenceGrade == "INCIDENT_EVIDENCE" and
    ([.incidents[].scenarios[].evidenceGrade] | all(. == "INCIDENT_EVIDENCE"))
  ' "$work/incident/repos/argocd-gitops/evidence/incidents/index.json" >/dev/null || fail "runtime incident index and scenarios are not INCIDENT_EVIDENCE"
  jq -e '
    .incidents[0].scenarios[0].lifecycle.baseline[0] as $reference |
    $reference.repository == "argocd-gitops" and
    ($reference.path | startswith("evidence/artifacts/")) and
    ($reference.sha256 | test("^[0-9a-f]{64}$"))
  ' "$work/incident/repos/argocd-gitops/evidence/incidents/index.json" >/dev/null \
    || fail "runtime index does not reference the repo-relative incident envelope"
  local envelope_path
  envelope_path=$(jq -r '.incidents[0].scenarios[0].lifecycle.baseline[0].path' \
    "$work/incident/repos/argocd-gitops/evidence/incidents/index.json")
  jq -e '.schemaVersion == "course.incident-artifact/v1"' \
    "$work/incident/repos/argocd-gitops/$envelope_path" >/dev/null \
    || fail "runtime index lifecycle reference cannot be parsed as an incident envelope"

  make_runtime_bundle "$work/legacy" CLOUD_RUNTIME v3.4 2026-09-03T00:00:00Z
  if run_runtime_producer "$work/legacy" >/dev/null 2>&1; then
    fail "runtime producer accepted legacy CLOUD_RUNTIME incident artifacts"
  fi
}

case_manifest_metadata() {
  local work
  work=$(mktemp -d)
  trap 'rm -rf -- "$work"' RETURN

  make_runtime_bundle "$work/valid" INCIDENT_EVIDENCE v3.4 2026-01-01T00:00:00Z
  run_runtime_producer "$work/valid" >/dev/null || fail "runtime producer rejected canonical manifest metadata"
  jq -e '
    def canonical_utc_seconds:
      . as $value |
      type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$") and
      ((fromdateiso8601 | strftime("%Y-%m-%dT%H:%M:%SZ")) == $value);
    .curriculumVersion == "v3.4" and
    .startedAt == "2026-01-01T00:00:00Z" and
    (.startedAt | canonical_utc_seconds) and (.generatedAt | canonical_utc_seconds) and
    ((.startedAt | fromdateiso8601) < (.generatedAt | fromdateiso8601))
  ' "$work/valid/repos/argocd-gitops/evidence/incidents/index.json" >/dev/null || fail "runtime index did not preserve valid canonical manifest metadata"

  make_runtime_bundle "$work/wrong-version" INCIDENT_EVIDENCE 2026-09 2026-01-01T00:00:00Z
  if run_runtime_producer "$work/wrong-version" >/dev/null 2>&1; then
    fail "runtime producer accepted an incompatible curriculumVersion"
  fi

  make_runtime_bundle "$work/missing-start" INCIDENT_EVIDENCE v3.4 MISSING
  if run_runtime_producer "$work/missing-start" >/dev/null 2>&1; then
    fail "runtime producer synthesized a missing manifest startedAt"
  fi

  make_runtime_bundle "$work/invalid-start" INCIDENT_EVIDENCE v3.4 2026-09-03
  if run_runtime_producer "$work/invalid-start" >/dev/null 2>&1; then
    fail "runtime producer accepted a non-RFC3339 manifest startedAt"
  fi

  make_runtime_bundle "$work/fractional-start" INCIDENT_EVIDENCE v3.4 2026-01-01T00:00:00.123Z
  if run_runtime_producer "$work/fractional-start" >/dev/null 2>&1; then
    fail "runtime producer accepted fractional manifest startedAt"
  fi

  make_runtime_bundle "$work/future-start" INCIDENT_EVIDENCE v3.4 2999-01-01T00:00:00Z
  if run_runtime_producer "$work/future-start" >/dev/null 2>&1; then
    fail "runtime producer accepted startedAt that is not earlier than generatedAt"
  fi
}

case_db04_recovery_identity() {
  local work variant
  work=$(mktemp -d)
  trap 'rm -rf -- "$work"' RETURN

  make_runtime_bundle "$work/valid" INCIDENT_EVIDENCE v3.4 2026-01-01T00:00:00Z
  for recovery_source in "$work"/valid/repos/cicd-course-sample-app/evidence/sources/db04-*.json; do
    jq -e '[.stable,.faulty,.recovered] | all(.imageRepository | test("(^|/)mini-commerce$"))' \
      "$recovery_source" >/dev/null || fail "runtime bundle emitted a noncanonical DB04 mini-commerce ECR identity"
  done
  run_runtime_producer "$work/valid" >/dev/null || fail "runtime producer rejected valid INC-DB-04 recovery identities"

  make_runtime_bundle "$work/repository-mismatch" INCIDENT_EVIDENCE v3.4 2026-01-01T00:00:00Z undo-repository
  if run_runtime_producer "$work/repository-mismatch" >/dev/null 2>&1; then
    fail "runtime producer accepted rollback recoveries whose repository differs from stable"
  fi

  for variant in invalid-stable-source-sha invalid-stable-digest blank-stable-repository \
    blank-stable-image-repository strategy-mismatch invalid-workflow invalid-run-attempt \
    workflow-url-mismatch arbitrary-release-repository workflow-repository-mismatch \
    non-ecr-image-repository cross-region-image-repository foreign-account-image-repository \
    one-character-image-repository noncanonical-image-repository recovered-image-repository-mismatch \
    invalid-gitops-revision invalid-rollout-revision \
    invalid-recovery-time fractional-recovery-time blank-execution-id bom-execution-id stable-lineage-mismatch \
    faulty-lineage-mismatch hotfix-lineage-mismatch; do
    make_runtime_bundle "$work/$variant" INCIDENT_EVIDENCE v3.4 2026-01-01T00:00:00Z "$variant"
    if run_runtime_producer "$work/$variant" >/dev/null 2>&1; then
      fail "runtime producer accepted invalid INC-DB-04 recovery contract: $variant"
    fi
  done
}

case_envelope_contract() {
  local work mutation candidate
  work=$(mktemp -d)
  trap 'rm -rf -- "$work"' RETURN
  make_runtime_bundle "$work/base" INCIDENT_EVIDENCE v3.4 2026-01-01T00:00:00Z
  run_runtime_producer "$work/base" >/dev/null || fail "runtime producer rejected the exact incident envelope contract"

  for mutation in producer-extra producer-unknown producer-head-mismatch subject-extra \
    outcome-extra blank-summary bom-summary bom-subject-kind bom-subject-id invalid-environment invalid-observed-at fractional-observed-at outside-index-window \
    source-extra source-path-base phase-order mitigation-duration; do
    candidate="$work/$mutation"
    cp -R "$work/base" "$candidate"
    mutate_runtime_bundle "$candidate" "$mutation"
    if run_runtime_producer "$candidate" >/dev/null 2>&1; then
      fail "runtime producer accepted invalid incident envelope mutation: $mutation"
    fi
  done
}

case_not_run_contract() {
  local work variant
  work=$(mktemp -d)
  trap 'rm -rf -- "$work"' RETURN

  for variant in missing-not-run blank-not-run bom-not-run; do
    make_runtime_bundle "$work/$variant" INCIDENT_EVIDENCE v3.4 2026-01-01T00:00:00Z "$variant"
    if run_runtime_producer "$work/$variant" >/dev/null 2>&1; then
      fail "runtime producer synthesized or accepted invalid NOT_RUN reason: $variant"
    fi
  done
}

case_scenario_contract() {
  local work variant
  work=$(mktemp -d)
  trap 'rm -rf -- "$work"' RETURN

  for variant in alias-scenario multiple-scenarios; do
    make_runtime_bundle "$work/$variant" INCIDENT_EVIDENCE v3.4 2026-01-01T00:00:00Z "$variant"
    if run_runtime_producer "$work/$variant" >/dev/null 2>&1; then
      fail "runtime producer accepted noncanonical non-DB04 scenarios: $variant"
    fi
  done
}

case_scope_contract() {
  local work label course_id account_id region bom
  work=$(mktemp -d)
  trap 'rm -rf -- "$work"' RETURN
  while IFS='|' read -r label course_id account_id region; do
    make_runtime_bundle "$work/$label" INCIDENT_EVIDENCE v3.4 2026-01-01T00:00:00Z none \
      "$course_id" "$account_id" "$region"
    if run_runtime_producer "$work/$label" "$course_id" "$account_id" "$region" >/dev/null 2>&1; then
      fail "runtime producer accepted invalid index scope: $label"
    fi
  done <<'CASES'
blank-course| |123456789012|us-east-1
invalid-account|course-ci|1234|us-east-1
unsupported-region|course-ci|123456789012|eu-west-1
CASES
  bom=$(printf '\357\273\277')
  make_runtime_bundle "$work/bom-course" INCIDENT_EVIDENCE v3.4 2026-01-01T00:00:00Z none \
    "$bom" 123456789012 us-east-1
  if run_runtime_producer "$work/bom-course" "$bom" 123456789012 us-east-1 >/dev/null 2>&1; then
    fail "runtime producer accepted invalid index scope: bom-course"
  fi
}

case_root_boundary() {
  local work bundle gitops_root outside
  work=$(mktemp -d)
  trap 'rm -rf -- "$work"' RETURN
  bundle="$work/base"
  make_runtime_bundle "$bundle" INCIDENT_EVIDENCE v3.4 2026-01-01T00:00:00Z
  gitops_root="$bundle/repos/argocd-gitops"
  cp "$bundle"/repos/cicd-course-sample-app/evidence/sources/db04-*.json \
    "$gitops_root/evidence/sources/"

  if bash "$repository_root/scripts/build-incident-index.sh" \
    --manifest "$bundle/manifest.json" --evidence-root "$gitops_root/evidence" \
    --sample-repo-root "$gitops_root" --gitops-repo-root "$gitops_root" \
    --eks-repo-root "$gitops_root" --course-id course-ci --account-id 123456789012 \
    --region us-east-1 --output "$gitops_root/evidence/incidents/index.json" >/dev/null 2>&1; then
    fail "runtime producer accepted one physical root under three repository identities"
  fi

  outside="$work/outside-evidence"
  mkdir -p "$outside"
  if bash "$repository_root/scripts/build-incident-index.sh" \
    --manifest "$bundle/manifest.json" --evidence-root "$outside" \
    --sample-repo-root "$bundle/repos/cicd-course-sample-app" \
    --gitops-repo-root "$gitops_root" --eks-repo-root "$bundle/repos/EKS-infra" \
    --course-id course-ci --account-id 123456789012 --region us-east-1 \
    --output "$gitops_root/evidence/incidents/index.json" >/dev/null 2>&1; then
    fail "runtime producer accepted an evidence root outside the GitOps repository"
  fi
}

case_output_boundary() {
  local work bundle gitops_root canonical_output outside_output outside_directory
  work=$(mktemp -d)
  trap 'rm -rf -- "$work"' RETURN
  bundle="$work/base"
  make_runtime_bundle "$bundle" INCIDENT_EVIDENCE v3.4 2026-01-01T00:00:00Z
  gitops_root="$bundle/repos/argocd-gitops"
  canonical_output="$gitops_root/evidence/incidents/index.json"
  outside_output="$work/outside-index.json"

  if bash "$repository_root/scripts/build-incident-index.sh" \
    --manifest "$bundle/manifest.json" --evidence-root "$gitops_root/evidence" \
    --sample-repo-root "$bundle/repos/cicd-course-sample-app" \
    --gitops-repo-root "$gitops_root" --eks-repo-root "$bundle/repos/EKS-infra" \
    --course-id course-ci --account-id 123456789012 --region us-east-1 \
    --output "$outside_output" >/dev/null 2>&1; then
    fail "runtime producer wrote INCIDENT_EVIDENCE outside the canonical GitOps path"
  fi

  outside_directory="$work/outside-directory"
  mkdir -p "$outside_directory"
  ln -s "$outside_directory" "$gitops_root/evidence/incidents"
  if bash "$repository_root/scripts/build-incident-index.sh" \
    --manifest "$bundle/manifest.json" --evidence-root "$gitops_root/evidence" \
    --sample-repo-root "$bundle/repos/cicd-course-sample-app" \
    --gitops-repo-root "$gitops_root" --eks-repo-root "$bundle/repos/EKS-infra" \
    --course-id course-ci --account-id 123456789012 --region us-east-1 \
    --output "$canonical_output" >/dev/null 2>&1; then
    fail "runtime producer followed a canonical output parent symlink"
  fi
}

case_provenance_boundary() {
  local work bundle
  work=$(mktemp -d)
  trap 'rm -rf -- "$work"' RETURN
  bundle="$work/base"
  make_runtime_bundle "$bundle" INCIDENT_EVIDENCE v3.4 2026-01-01T00:00:00Z
  echo "unreviewed" > "$bundle/repos/cicd-course-sample-app/dirty.txt"
  if run_runtime_producer "$bundle" >/dev/null 2>&1; then
    fail "runtime producer trusted a reviewed repository with non-evidence changes"
  fi
}

requested=all
fixture=
while (($#)); do case "$1" in --all) requested=all; shift ;; --fixture) fixture=${2:?missing fixture}; requested=fixture; shift 2 ;; --case) requested=${2:?missing case}; shift 2 ;; *) echo "Usage: $0 --all|--fixture path|--case runtime-grade|manifest-metadata|db04-recovery-identity|envelope-contract|not-run-contract|scenario-contract|scope-contract|root-boundary|output-boundary|provenance-boundary" >&2; exit 2 ;; esac; done
case "$requested" in
  fixture) validate_file "$fixture" ;;
  runtime-grade) case_runtime_grade ;;
  manifest-metadata) case_manifest_metadata ;;
  db04-recovery-identity) case_db04_recovery_identity ;;
  envelope-contract) case_envelope_contract ;;
  not-run-contract) case_not_run_contract ;;
  scenario-contract) case_scenario_contract ;;
  scope-contract) case_scope_contract ;;
  root-boundary) case_root_boundary ;;
  output-boundary) case_output_boundary ;;
  provenance-boundary) case_provenance_boundary ;;
  all) validate_catalog; case_runtime_grade; case_manifest_metadata; case_db04_recovery_identity; case_envelope_contract; case_not_run_contract; case_scenario_contract; case_scope_contract; case_root_boundary; case_output_boundary; case_provenance_boundary ;;
  *) fail "unknown incident contract case: $requested" ;;
esac
echo "PASS: incident lifecycle metadata is valid."
