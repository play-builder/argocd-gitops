#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
# Main-chart legacy ownership was retired; validate the independently rendered owners.
ruby tests/data-governance-contract.rb
ruby tests/isolated-operations-contract.rb

ruby tests/rc-integration-contract.rb migration
