#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
ruby tests/burn-rate-contract.rb
