#!/usr/bin/env bash
set -Eeuo pipefail

render_lib_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd -- "$render_lib_dir/../.." && pwd)

render_environment() {
  local environment=$1
  local output=$2
  shift 2

  case "$environment" in
    dev | prod) ;;
    *)
      echo "FAIL: unsupported render environment: $environment" >&2
      return 2
      ;;
  esac

  local -a helm_arguments=(
    --values "$repository_root/envs/$environment/values.yaml"
    --set-string image.repository=example.invalid/sample-app
    --set-string image.digest=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    --set-string database.migrationImage.repository=example.invalid/sample-app
    --set-string database.migrationImage.digest=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  )

  local overlay
  for overlay in "$@"; do
    if [[ "$overlay" != /* ]]; then
      overlay="$repository_root/$overlay"
    fi
    helm_arguments+=(--values "$overlay")
  done

  helm template sample-app "$repository_root/charts/sample-app" \
    "${helm_arguments[@]}" >"$output"
}
