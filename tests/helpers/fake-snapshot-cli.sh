#!/usr/bin/env bash
set -Eeuo pipefail

tool=$(basename -- "$0")
root=${FAKE_SNAPSHOT_DIR:?FAKE_SNAPSHOT_DIR is required}
phase=${FAKE_SNAPSHOT_PHASE:?FAKE_SNAPSHOT_PHASE is required}
phase_root="$root/$phase"
printf '%s %s\n' "$tool" "$*" >>"$root/calls.log"

phase_file() {
  local name=$1
  if [[ -f "$phase_root/$name" ]]; then
    printf '%s\n' "$phase_root/$name"
  else
    printf '%s\n' "$root/$name"
  fi
}

case "$tool" in
  git)
    case "$*" in
      -C\ *\ rev-parse\ HEAD) cat "$phase_root/git-revision.txt" ;;
      -C\ *\ status\ --short\ --untracked-files=no) cat "$phase_root/git-status.txt" ;;
      -C\ *\ diff\ --name-only\ *) cat "$phase_root/git-diff-names.txt" ;;
      -C\ *\ merge-base\ --is-ancestor\ *\ HEAD) exit 0 ;;
      -C\ *\ show\ *:envs/dev/snapshot-maintenance-values.yaml) cat "$root/a1/phase-values.yaml" ;;
      *) echo "FAIL: unexpected fake git invocation: $*" >&2; exit 64 ;;
    esac
    ;;
  argocd)
    [[ "$*" == "app get sample-app-dev -o json" ]] || { echo "FAIL: unexpected fake argocd invocation: $*" >&2; exit 64; }
    cat "$phase_root/application.json"
    ;;
  aws)
    [[ "$*" == "eks describe-cluster --name course-dev --region ap-northeast-2 --output json" ]] || { echo "FAIL: unexpected fake aws invocation: $*" >&2; exit 64; }
    cat "$root/cluster.json"
    ;;
  kubectl)
    case "$*" in
      "config view --minify -o json") cat "$root/kubeconfig.json" ;;
      "-n app-dev get deployment sample-app -o json") cat "$(phase_file deployment.json)" ;;
      "-n app-dev get jobs -l app.kubernetes.io/part-of=sample-app,app.kubernetes.io/component=migration -o json") cat "$(phase_file jobs.json)" ;;
      "-n app-dev get statefulset sample-app-postgresql -o json") cat "$(phase_file statefulset.json)" ;;
      "-n app-dev get pods -l app.kubernetes.io/name=postgresql,app.kubernetes.io/instance=sample-app -o json") cat "$(phase_file pods.json)" ;;
      "-n app-dev get pods -o json") cat "$(phase_file all-pods.json)" ;;
      "-n app-dev get pod sample-app-postgresql-0 -o json --ignore-not-found") cat "$(phase_file start-pod.json)" ;;
      "-n app-dev get pvc data-sample-app-postgresql-0 -o json") cat "$(phase_file pvc.json)" ;;
      "get pv pvc-11111111-1111-1111-1111-111111111111 -o json") cat "$(phase_file pv.json)" ;;
      "get volumeattachment -o json") cat "$(phase_file volumeattachments.json)" ;;
      "-n app-dev get volumesnapshot -o json --ignore-not-found") cat "$(phase_file volumesnapshots.json)" ;;
      "-n app-dev get volumesnapshot sample-app-postgresql-snapshot -o json") cat "$(phase_file snapshot.json)" ;;
      "get volumesnapshotcontent snapcontent-22222222-2222-2222-2222-222222222222 -o json") cat "$(phase_file snapshot-content.json)" ;;
      "-n app-dev exec sample-app-postgresql-0 -c postgresql --"*) cat "$phase_root/checksum.json" ;;
      "-n app-dev logs -f sample-app-postgresql-0 -c postgresql --timestamps") cat "$phase_root/shutdown.log" ;;
      *) echo "FAIL: unexpected fake kubectl invocation: $*" >&2; exit 64 ;;
    esac
    ;;
  *) echo "FAIL: unexpected fake CLI: $tool" >&2; exit 64 ;;
esac
