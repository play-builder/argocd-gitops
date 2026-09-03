#!/usr/bin/env bash
set -Eeuo pipefail

test_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd -- "$test_root/.." && pwd)
fixture_root="$test_root/fixtures/platform-owner-handoff"
scratch_root=$(mktemp -d "${TMPDIR:-/tmp}/platform-owner-phase-b.XXXXXX")
trap 'rm -rf -- "$scratch_root"' EXIT

gate="$repository_root/scripts/verify-platform-owner-phase-b.sh"
revision=1111111111111111111111111111111111111111

set +e
missing_output=$(bash "$gate" \
  --environment dev \
  --handoff "$scratch_root/missing-handoff.json" \
  --adoption "$scratch_root/missing-adoption.json" \
  --expected-gitops-revision "$revision" 2>&1)
missing_status=$?
set -e
[[ "$missing_status" -ne 0 ]]
grep -Fq 'PLATFORM_OWNER_HANDOFF_BLOCKED: handoff evidence file not found' <<<"$missing_output"

static_output=$(COURSE_PHASE_B_TEST_MODE=1 COURSE_PHASE_B_NOW=2026-09-03T00:20:00Z \
  bash "$gate" \
    --environment dev \
    --handoff "$fixture_root/dev-handoff.json" \
    --adoption "$fixture_root/dev-adoption.json" \
    --expected-gitops-revision "$revision")
grep -Fq '[STATIC] PASS: dev platform owner adoption permits Phase B preparation' \
  <<<"$static_output"

set +e
runtime_output=$(bash "$gate" \
  --environment dev \
  --handoff "$fixture_root/dev-handoff.json" \
  --adoption "$fixture_root/dev-adoption.json" \
  --expected-gitops-revision "$revision" 2>&1)
runtime_status=$?
set -e
[[ "$runtime_status" -ne 0 ]]
grep -Fq 'PLATFORM_OWNER_HANDOFF_BLOCKED: test fixtures cannot authorize a runtime Phase B transition' \
  <<<"$runtime_output"

cp "$fixture_root/dev-handoff.json" "$scratch_root/static-handoff.json"
cp "$fixture_root/dev-adoption.json" "$scratch_root/static-adoption.json"
set +e
grade_output=$(bash "$gate" \
  --environment dev \
  --handoff "$scratch_root/static-handoff.json" \
  --adoption "$scratch_root/static-adoption.json" \
  --expected-gitops-revision "$revision" 2>&1)
grade_status=$?
set -e
[[ "$grade_status" -ne 0 ]]
grep -Fq 'PLATFORM_OWNER_HANDOFF_BLOCKED: CLOUD_RUNTIME evidence is required' \
  <<<"$grade_output"

jq '.terraform.planActions = ["create"]' "$fixture_root/dev-adoption.json" \
  >"$scratch_root/create-plan.json"
set +e
plan_output=$(COURSE_PHASE_B_TEST_MODE=1 COURSE_PHASE_B_NOW=2026-09-03T00:20:00Z \
  bash "$gate" \
    --environment dev \
    --handoff "$fixture_root/dev-handoff.json" \
    --adoption "$scratch_root/create-plan.json" \
    --expected-gitops-revision "$revision" 2>&1)
plan_status=$?
set -e
[[ "$plan_status" -ne 0 ]]
grep -Fq 'PLATFORM_OWNER_HANDOFF_BLOCKED: adoption proof is not a no-op import' \
  <<<"$plan_output"

jq '.release.after.workloadUids[0].uid = "replacement-uid"' \
  "$fixture_root/dev-adoption.json" >"$scratch_root/replaced-uid.json"
set +e
uid_output=$(COURSE_PHASE_B_TEST_MODE=1 COURSE_PHASE_B_NOW=2026-09-03T00:20:00Z \
  bash "$gate" \
    --environment dev \
    --handoff "$fixture_root/dev-handoff.json" \
    --adoption "$scratch_root/replaced-uid.json" \
    --expected-gitops-revision "$revision" 2>&1)
uid_status=$?
set -e
[[ "$uid_status" -ne 0 ]]
grep -Fq 'PLATFORM_OWNER_HANDOFF_BLOCKED: release identity or UID changed during adoption' \
  <<<"$uid_output"

jq '.unexpected = true' "$fixture_root/dev-handoff.json" \
  >"$scratch_root/extra-key-handoff.json"
set +e
exact_output=$(COURSE_PHASE_B_TEST_MODE=1 COURSE_PHASE_B_NOW=2026-09-03T00:20:00Z \
  bash "$gate" \
    --environment dev \
    --handoff "$scratch_root/extra-key-handoff.json" \
    --adoption "$fixture_root/dev-adoption.json" \
    --expected-gitops-revision "$revision" 2>&1)
exact_status=$?
set -e
[[ "$exact_status" -ne 0 ]]
grep -Fq 'PLATFORM_OWNER_HANDOFF_BLOCKED: handoff evidence is malformed' \
  <<<"$exact_output"

jq '.handoffSha256 = "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' \
  "$fixture_root/dev-adoption.json" >"$scratch_root/wrong-hash-adoption.json"
set +e
hash_output=$(COURSE_PHASE_B_TEST_MODE=1 COURSE_PHASE_B_NOW=2026-09-03T00:20:00Z \
  bash "$gate" \
    --environment dev \
    --handoff "$fixture_root/dev-handoff.json" \
    --adoption "$scratch_root/wrong-hash-adoption.json" \
    --expected-gitops-revision "$revision" 2>&1)
hash_status=$?
set -e
[[ "$hash_status" -ne 0 ]]
grep -Fq 'PLATFORM_OWNER_HANDOFF_BLOCKED: adoption evidence is malformed' \
  <<<"$hash_output"

echo "PASS: Phase B gate fails closed and validates the exact adoption contract."
