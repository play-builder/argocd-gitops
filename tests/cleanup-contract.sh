#!/usr/bin/env bash
set -Eeuo pipefail
test_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd -- "$test_root/.." && pwd)
fixture_root="$test_root/fixtures/cleanup"
fail() { echo "FAIL: $*" >&2; exit 1; }

validate_fixture() {
  local file=$1
  yq -o=json '.' "$file" | jq -e '
    .cleanup.externalSecretLifecycle.targetSecretOwnerReferenceGC == true and
    .cleanup.externalSecretLifecycle.providerSecretRetained == true and
    ((.cleanup.externalSecretLifecycle.providerSecretDeletion // false) == false)
  ' >/dev/null || fail "cleanup permits provider Secret deletion"
}

case_all() {
  local tmp_root invalid_inventory_root invalid_inventory invalid_removal value label timestamp_label
  local invalid_freeze invalid_timestamp_removal
  tmp_root=$(mktemp -d)
  trap 'rm -rf -- "$tmp_root"' RETURN
  set +e
  invalid_output=$(bash "$repository_root/tests/cleanup-contract.sh" --fixture "$fixture_root/provider-secret-deletion.yaml" 2>&1)
  invalid_status=$?
  set -e
  [[ $invalid_status -ne 0 ]] && grep -Fq "cleanup permits provider Secret deletion" <<<"$invalid_output" || fail "invalid provider deletion fixture was not rejected"
  local cleanup_fixture cleanup_output cleanup_status
  for cleanup_fixture in \
    "$fixture_root/removal-unclassified-retained.json" \
    "$fixture_root/removal-writer-active.json" \
    "$fixture_root/provider-secret-digest-mismatch.json"; do
    set +e
    cleanup_output=$(bash "$repository_root/scripts/capture-cleanup-evidence.sh" removal \
      --fixture "$cleanup_fixture" --eks-repo-root "$fixture_root" 2>&1)
    cleanup_status=$?
    set -e
    [[ $cleanup_status -ne 0 ]] || fail "invalid cleanup fixture was accepted: $(basename "$cleanup_fixture")"
  done
  for environment in dev prod; do
    helm template mini-commerce "$repository_root/charts/mini-commerce" \
      -f "$repository_root/envs/$environment/values.yaml" \
      -f "$repository_root/envs/$environment/cleanup-values.yaml" >"$tmp_root/cleanup-$environment.yaml"
    yq eval-all -o=json -I=0 '[.]' "$tmp_root/cleanup-$environment.yaml" | jq -e \
      'map(select(. != null)) | length == 1 and .[0].kind == "Namespace" and .[0].metadata.annotations["argocd.argoproj.io/sync-options"] == "Prune=false"' >/dev/null || fail "cleanup must remove app resources and retain namespace ownership"
  done
  if helm template mini-commerce "$repository_root/charts/mini-commerce" \
    -f "$repository_root/envs/prod/values.yaml" --set-string platformCleanup.workloadsDisabled=false >/dev/null 2>&1; then
    fail "string false must not activate destructive cleanup"
  fi
  if helm template mini-commerce "$repository_root/charts/mini-commerce" \
    -f "$repository_root/envs/prod/values.yaml" --set networkPolicy.enabled=true >/dev/null 2>&1; then
    fail "removed networkPolicy switch was silently accepted"
  fi
  for file in "$fixture_root"/freeze-valid.json "$fixture_root"/removal-valid.json; do jq -e '.evidenceGrade == "CLOUD_RUNTIME"' "$file" >/dev/null || fail "$(basename "$file") is not CLOUD_RUNTIME"; done
  bash "$repository_root/scripts/capture-cleanup-evidence.sh" freeze --fixture "$fixture_root/freeze-valid.json" >/dev/null || fail "valid freeze evidence fixture was rejected"
  bash "$repository_root/scripts/capture-cleanup-evidence.sh" removal --fixture "$fixture_root/removal-valid.json" --eks-repo-root "$fixture_root" >/dev/null || fail "provider Secret projection validation failed"
  while IFS='|' read -r timestamp_label value; do
    invalid_freeze="$tmp_root/freeze-$timestamp_label.json"
    jq --arg value "$value" '.observedAt=$value' \
      "$fixture_root/freeze-valid.json" >"$invalid_freeze"
    if bash "$repository_root/scripts/capture-cleanup-evidence.sh" freeze \
      --fixture "$invalid_freeze" >/dev/null 2>&1; then
      fail "freeze fixture accepted noncanonical observedAt: $timestamp_label"
    fi

    invalid_timestamp_removal="$tmp_root/removal-$timestamp_label.json"
    jq --arg value "$value" '.observedAt=$value' \
      "$fixture_root/removal-valid.json" >"$invalid_timestamp_removal"
    if bash "$repository_root/scripts/capture-cleanup-evidence.sh" removal \
      --fixture "$invalid_timestamp_removal" --eks-repo-root "$fixture_root" \
      >/dev/null 2>&1; then
      fail "removal fixture accepted noncanonical observedAt: $timestamp_label"
    fi

    invalid_inventory_root="$tmp_root/inventory-timestamp-$timestamp_label"
    invalid_inventory="$invalid_inventory_root/evidence/cleanup/ownership-inventory.json"
    mkdir -p "$(dirname "$invalid_inventory")"
    jq --arg value "$value" '.observedAt=$value' \
      "$fixture_root/ownership-valid.json" >"$invalid_inventory"
    if bash "$repository_root/scripts/capture-cleanup-evidence.sh" removal \
      --fixture "$fixture_root/removal-valid.json" \
      --eks-repo-root "$invalid_inventory_root" >/dev/null 2>&1; then
      fail "ownership fixture accepted noncanonical observedAt: $timestamp_label"
    fi
  done <<'TIMESTAMPS'
invalid-calendar|2026-02-31T00:00:00Z
fractional|2026-09-03T00:00:00.123Z
non-z-offset|2026-09-03T09:00:00+09:00
TIMESTAMPS
  for label in ascii-space bom; do
    value=' '
    [[ "$label" == bom ]] && value=$(printf '\357\273\277')
    invalid_inventory_root="$tmp_root/inventory-$label"
    invalid_inventory="$invalid_inventory_root/evidence/cleanup/ownership-inventory.json"
    mkdir -p "$(dirname "$invalid_inventory")"
    jq --arg value "$value" '.ownerId=$value' "$fixture_root/ownership-valid.json" >"$invalid_inventory"
    if bash "$repository_root/scripts/capture-cleanup-evidence.sh" removal \
      --fixture "$fixture_root/removal-valid.json" --eks-repo-root "$invalid_inventory_root" >/dev/null 2>&1; then
      fail "cleanup fixture adapter accepted $label-only ownership ownerId"
    fi
    jq --arg value "$value" \
      '.resources |= map(if .kind=="PersistentVolumeClaim" then .reason=$value else . end)' \
      "$fixture_root/ownership-valid.json" >"$invalid_inventory"
    if bash "$repository_root/scripts/capture-cleanup-evidence.sh" removal \
      --fixture "$fixture_root/removal-valid.json" --eks-repo-root "$invalid_inventory_root" >/dev/null 2>&1; then
      fail "cleanup fixture adapter accepted $label-only retained rationale"
    fi
    invalid_removal="$tmp_root/removal-$label.json"
    jq --arg value "$value" '.retained[0].uid=$value' "$fixture_root/removal-valid.json" >"$invalid_removal"
    if bash "$repository_root/scripts/capture-cleanup-evidence.sh" removal \
      --fixture "$invalid_removal" --eks-repo-root "$fixture_root" >/dev/null 2>&1; then
      fail "cleanup fixture adapter accepted $label-only retained UID"
    fi
  done
  echo "PASS: cleanup ownership and evidence boundaries are valid."
}

case_fixture() { validate_fixture "$1"; echo "PASS: cleanup lifecycle is retained and recoverable."; }
requested=all; fixture=
while (($#)); do case "$1" in --all) requested=all; shift ;; --fixture) requested=fixture; fixture=${2:?missing fixture}; shift 2 ;; *) echo "Usage: $0 --all|--fixture path" >&2; exit 2 ;; esac; done
if [[ "$requested" == fixture ]]; then case_fixture "$fixture"; else case_all; fi
