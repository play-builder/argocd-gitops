#!/usr/bin/env bash
set -Eeuo pipefail

[[ -n ${FAKE_ROLLBACK_DIR:-} ]] || { echo 'FAIL: FAKE_ROLLBACK_DIR is required' >&2; exit 64; }
tool=${0##*/}
emit() { [[ -f "$1" ]] || { echo "FAIL: missing fake response $1" >&2; exit 64; }; command cat "$1"; }

case "$tool" in
  git)
    case " $* " in
      *' status --porcelain --untracked-files=all -- . :(exclude)evidence '*) emit "$FAKE_ROLLBACK_DIR/git-status.txt" ;;
      *' rev-parse HEAD '*) emit "$FAKE_ROLLBACK_DIR/git-revision.txt" ;;
      *) echo "FAIL: unexpected fake git invocation: $*" >&2; exit 64 ;;
    esac
    ;;
  argocd)
    [[ "$*" == 'app get mini-commerce-prod -o json' ]] || { echo "FAIL: unexpected fake argocd invocation: $*" >&2; exit 64; }
    emit "$FAKE_ROLLBACK_DIR/application.json"
    ;;
  aws)
    [[ "$*" == eks\ describe-cluster\ --name\ *\ --region\ *\ --output\ json ]] || { echo "FAIL: unexpected fake aws invocation: $*" >&2; exit 64; }
    emit "$FAKE_ROLLBACK_DIR/cluster.json"
    ;;
  kubectl)
    printf '%s\n' "$*" >>"$FAKE_ROLLBACK_DIR/kubectl.log"
    case "$*" in
      'config view --minify -o json') emit "$FAKE_ROLLBACK_DIR/kubeconfig.json" ;;
      '-n app-prod get rollout mini-commerce -o json') emit "$FAKE_ROLLBACK_DIR/rollout.json" ;;
      '-n app-prod get replicasets -l app.kubernetes.io/instance=mini-commerce -o json') emit "$FAKE_ROLLBACK_DIR/replicasets.json" ;;
      'auth can-i create configmaps --namespace app-prod') emit "$FAKE_ROLLBACK_DIR/configmap-create-permission.txt" ;;
      'auth can-i delete configmaps --namespace app-prod') emit "$FAKE_ROLLBACK_DIR/configmap-delete-permission.txt" ;;
      '-n app-prod get configmap mini-commerce-rollback-candidates -o json --ignore-not-found') emit "$FAKE_ROLLBACK_DIR/existing-configmap.json" ;;
      '-n app-prod get job mini-commerce-migration -o json') emit "$FAKE_ROLLBACK_DIR/migration-job.json" ;;
      -n\ app-prod\ create\ -f\ *)
        [[ ${*: -1} != '-' ]] || { echo 'FAIL: ConfigMap create must use a validated regular file' >&2; exit 64; }
        cp "${*: -1}" "$FAKE_ROLLBACK_DIR/created-configmap.json"
        echo 'configmap/mini-commerce-rollback-candidates created'
        ;;
      delete\ --raw=/api/v1/namespaces/app-prod/configmaps/mini-commerce-rollback-candidates\ -f\ *)
        cp "${*: -1}" "$FAKE_ROLLBACK_DIR/delete-options.json"
        : >"$FAKE_ROLLBACK_DIR/existing-configmap.json"
        echo 'configmap "mini-commerce-rollback-candidates" deleted'
        ;;
      *) echo "FAIL: unexpected fake kubectl invocation: $*" >&2; exit 64 ;;
    esac
    ;;
  *) echo "FAIL: unexpected fake CLI: $tool" >&2; exit 64 ;;
esac
