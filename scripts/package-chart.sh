#!/usr/bin/env bash
set -Eeuo pipefail

repository_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
destination=${1:?Usage: $0 OUTPUT_DIRECTORY}
mkdir -p "$destination"
for chart in mini-commerce mini-commerce-db-dev mini-commerce-recovery; do
  version=$(ruby -ryaml -e 'puts YAML.load_file(ARGV.fetch(0)).fetch("version")' "$repository_root/charts/$chart/Chart.yaml")
  helm package "$repository_root/charts/$chart" --destination "$destination" >/dev/null
  archive="$chart-$version.tgz"
  [[ -f "$destination/$archive" ]] || { echo "FAIL: Helm package did not produce $archive" >&2; exit 1; }
  (cd "$destination" && shasum -a 256 "$archive" > "$archive.sha256" && shasum -a 256 -c "$archive.sha256")
  echo "[STATIC] packaged $destination/$archive"
done
