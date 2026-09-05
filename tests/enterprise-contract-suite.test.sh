#!/usr/bin/env bash
set -Eeuo pipefail

test_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
fixture_root=$(mktemp -d)
dispatch_log=$(mktemp)
trap 'rm -rf "$fixture_root" "$dispatch_log"' EXIT

contracts=(
  argocd-tenancy-contract.sh notification-contract.sh source-integrity-contract.sh
  sigstore-policy-contract.sh resource-governance-contract.sh istio-platform-contract.sh
  mesh-security-contract.sh istio-routing-contract.sh ignore-differences-contract.sh
  managed-database-contract.sh chaos-separation-contract.sh recovery-separation-contract.sh
  kubeconform-contract.sh runbook-contract.sh burn-rate-contract.sh
)

for contract in "${contracts[@]}"; do
  name=${contract%.sh}
  cat >"$fixture_root/$contract" <<EOF
#!/usr/bin/env bash
echo "$name" >>"\$DISPATCH_LOG"
EOF
done
cat >>"$fixture_root/notification-contract.sh" <<'EOF'
exit 47
EOF

set +e
CONTRACT_ROOT="$fixture_root" DISPATCH_LOG="$dispatch_log" bash "$test_root/enterprise-contract-suite.sh"
status=$?
set -e
if [[ "$status" != "47" ]]; then
  echo "FAIL: enterprise suite must propagate the first contract failure" >&2
  exit 1
fi

[[ "$(cat "$dispatch_log")" == $'argocd-tenancy-contract\nnotification-contract' ]] || {
  echo "FAIL: enterprise suite dispatch order is not deterministic" >&2
  cat "$dispatch_log" >&2
  exit 1
}

echo "PASS: enterprise suite preserves ordered failure propagation"
