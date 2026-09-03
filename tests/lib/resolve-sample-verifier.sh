#!/usr/bin/env bash
set -Eeuo pipefail

fail() { echo "FAIL: $*" >&2; exit 1; }

mode=${CROSS_REPO_CONTRACT_MODE:-repository-local}
sample_root=${SAMPLE_APP_REPO_ROOT:-}
verifier_path=${SAMPLE_APP_VERIFIER_PATH:-}
optional=${SAMPLE_APP_VERIFIER_OPTIONAL:-0}

[[ "$mode" == repository-local || "$mode" == exact-sha ]] ||
  fail 'CROSS_REPO_CONTRACT_MODE must be repository-local or exact-sha'
[[ "$optional" == 0 || "$optional" == 1 ]] ||
  fail 'SAMPLE_APP_VERIFIER_OPTIONAL must be 0 or 1'
[[ -z "$sample_root" || -z "$verifier_path" ]] ||
  fail 'set either SAMPLE_APP_REPO_ROOT or SAMPLE_APP_VERIFIER_PATH, not both'

if [[ -z "$sample_root" && -z "$verifier_path" ]]; then
  [[ "$mode" != exact-sha ]] || fail 'exact-SHA mode requires a sample-app checkout or verifier path'
  [[ "$optional" == 1 ]] || fail 'sample-app verifier is required unless optional mode is explicit'
  exit 0
fi

if [[ -n "$sample_root" ]]; then
  [[ -d "$sample_root" && ! -L "$sample_root" ]] || fail 'SAMPLE_APP_REPO_ROOT must be a non-symlink directory'
  sample_root=$(cd -- "$sample_root" && pwd -P)
  verifier_path="$sample_root/src/migration-ledger.js"
fi

[[ -f "$verifier_path" && ! -L "$verifier_path" ]] ||
  fail 'sample-app verifier must be a regular non-symlink file'
verifier_dir=$(cd -- "$(dirname -- "$verifier_path")" && pwd -P)
verifier_path="$verifier_dir/$(basename -- "$verifier_path")"

if [[ "$mode" == exact-sha ]]; then
  [[ ${SAMPLE_APP_EXPECTED_SHA:-} =~ ^[0-9a-f]{40}$ ]] ||
    fail 'exact-SHA mode requires SAMPLE_APP_EXPECTED_SHA as a full commit SHA'
  git_root=$(git -C "$verifier_dir" rev-parse --show-toplevel 2>/dev/null) ||
    fail 'sample-app verifier is not inside a Git checkout'
  git_root=$(cd -- "$git_root" && pwd -P)
  [[ "$verifier_path" == "$git_root/src/migration-ledger.js" ]] ||
    fail 'exact-SHA verifier path is not the canonical sample-app source file'
  actual_sha=$(git -C "$git_root" rev-parse HEAD)
  [[ "$actual_sha" == "$SAMPLE_APP_EXPECTED_SHA" ]] ||
    fail 'sample-app checkout revision differs from SAMPLE_APP_EXPECTED_SHA'
  expected_blob=$(git -C "$git_root" rev-parse \
    "$SAMPLE_APP_EXPECTED_SHA:src/migration-ledger.js" 2>/dev/null) ||
    fail 'expected sample-app commit does not track src/migration-ledger.js'
  index_blob=$(git -C "$git_root" rev-parse ':src/migration-ledger.js' 2>/dev/null) ||
    fail 'sample-app index does not track src/migration-ledger.js'
  actual_blob=$(git hash-object "$verifier_path") ||
    fail 'unable to hash the selected sample-app verifier'
  [[ "$index_blob" == "$expected_blob" ]] ||
    fail 'staged sample-app verifier bytes differ from the expected commit'
  [[ "$actual_blob" == "$expected_blob" ]] ||
    fail 'sample-app verifier bytes differ from the expected commit'
fi

printf '%s\n' "$verifier_path"
