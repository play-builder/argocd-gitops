#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
ruby tests/platform-governance-contract.rb
