#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
ruby tests/cross-repository-contract.rb
