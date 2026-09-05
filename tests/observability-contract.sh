#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
ruby tests/data-governance-contract.rb
ruby tests/management-mesh-contract.rb
