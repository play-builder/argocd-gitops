#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
ruby scripts/validate-rendered-manifests.rb "$@"

