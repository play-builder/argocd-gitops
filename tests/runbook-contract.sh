#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
# Operational prose is reviewed by humans; this executes the evidence parser it references.
ruby tests/incident-binding-contract.rb
