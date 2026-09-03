#!/usr/bin/env bash
set -Eeuo pipefail

repository_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
destination=${1:?Usage: $0 OUTPUT_DIRECTORY}
mkdir -p "$destination"
helm package "$repository_root/charts/sample-app" --destination "$destination" >/dev/null
archive="$destination/sample-app-1.1.0.tgz"
[[ -f "$archive" ]] || { echo "FAIL: Helm package did not produce $archive" >&2; exit 1; }
(cd "$destination" && shasum -a 256 "$(basename "$archive")" > sample-app-1.1.0.tgz.sha256 && shasum -a 256 -c sample-app-1.1.0.tgz.sha256)
echo "[STATIC] packaged $archive"
