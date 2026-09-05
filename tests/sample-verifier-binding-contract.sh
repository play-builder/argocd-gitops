#!/usr/bin/env bash
set -Eeuo pipefail

test_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
resolver="$test_root/lib/resolve-sample-verifier.sh"
tmp_root=$(mktemp -d "${TMPDIR:-/tmp}/sample-verifier-binding.XXXXXX")
trap 'rm -rf -- "$tmp_root"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# Each case below supplies its own resolver inputs. Ignore cross-repository
# selection inherited from a parent suite so the negative cases remain isolated.
unset CROSS_REPO_CONTRACT_MODE SAMPLE_APP_REPO_ROOT SAMPLE_APP_EXPECTED_SHA
unset SAMPLE_APP_VERIFIER_PATH SAMPLE_APP_VERIFIER_OPTIONAL

[[ -x "$resolver" ]] || fail 'sample verifier resolver is missing or not executable'

sample_root="$tmp_root/sample-checkout"
mkdir -p "$sample_root/src"
printf '%s\n' 'export function verifyContract003RollbackCandidates() {}' \
  >"$sample_root/src/migration-ledger.js"
git init -q "$sample_root"
git -C "$sample_root" add src/migration-ledger.js
git -C "$sample_root" -c user.name='Contract Test' \
  -c user.email=contract@example.invalid commit -q -m 'add verifier'
sample_sha=$(git -C "$sample_root" rev-parse HEAD)
expected_path=$(cd -- "$sample_root/src" && pwd -P)/migration-ledger.js

resolved=$(CROSS_REPO_CONTRACT_MODE=exact-sha \
  SAMPLE_APP_REPO_ROOT="$sample_root" SAMPLE_APP_EXPECTED_SHA="$sample_sha" \
  "$resolver") || fail 'exact-SHA mode rejected the selected Sample checkout'
[[ "$resolved" == "$expected_path" ]] || fail 'resolver did not return the selected checkout verifier'

printf '%s\n' '// unstaged mutation' >>"$expected_path"
if CROSS_REPO_CONTRACT_MODE=exact-sha SAMPLE_APP_REPO_ROOT="$sample_root" \
  SAMPLE_APP_EXPECTED_SHA="$sample_sha" "$resolver" >/dev/null 2>&1; then
  fail 'exact-SHA mode accepted an unstaged verifier mutation'
fi
git -C "$sample_root" restore --source=HEAD --worktree src/migration-ledger.js

printf '%s\n' '// staged mutation' >>"$expected_path"
git -C "$sample_root" add src/migration-ledger.js
if CROSS_REPO_CONTRACT_MODE=exact-sha SAMPLE_APP_REPO_ROOT="$sample_root" \
  SAMPLE_APP_EXPECTED_SHA="$sample_sha" "$resolver" >/dev/null 2>&1; then
  fail 'exact-SHA mode accepted a staged verifier mutation'
fi
git -C "$sample_root" restore --source=HEAD --staged --worktree src/migration-ledger.js

resolved=$(SAMPLE_APP_VERIFIER_PATH="$expected_path" "$resolver") ||
  fail 'explicit verifier path was rejected'
[[ "$resolved" == "$expected_path" ]] || fail 'explicit verifier path was not resolved physically'

if CROSS_REPO_CONTRACT_MODE=exact-sha SAMPLE_APP_REPO_ROOT="$sample_root" \
  SAMPLE_APP_EXPECTED_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  "$resolver" >/dev/null 2>&1; then
  fail 'exact-SHA mode accepted a different checkout revision'
fi
if CROSS_REPO_CONTRACT_MODE=exact-sha "$resolver" >/dev/null 2>&1; then
  fail 'exact-SHA mode accepted a missing Sample checkout'
fi

untracked_root="$tmp_root/sample-checkout-untracked"
mkdir -p "$untracked_root/src"
git init -q "$untracked_root"
git -C "$untracked_root" -c user.name='Contract Test' \
  -c user.email=contract@example.invalid commit -q --allow-empty -m 'empty source'
untracked_sha=$(git -C "$untracked_root" rev-parse HEAD)
printf '%s\n' 'export function verifyContract003RollbackCandidates() {}' \
  >"$untracked_root/src/migration-ledger.js"
if CROSS_REPO_CONTRACT_MODE=exact-sha SAMPLE_APP_REPO_ROOT="$untracked_root" \
  SAMPLE_APP_EXPECTED_SHA="$untracked_sha" "$resolver" >/dev/null 2>&1; then
  fail 'exact-SHA mode accepted an untracked verifier path'
fi

optional=$(SAMPLE_APP_VERIFIER_OPTIONAL=1 "$resolver") ||
  fail 'explicit repository-local optional mode was rejected'
[[ -z "$optional" ]] || fail 'optional mode returned an unexpected verifier'

echo "PASS: Sample verifier selection is explicit and exact-SHA mode fails closed."
