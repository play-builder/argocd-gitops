#!/usr/bin/env bash
set -Eeuo pipefail

[[ -n ${FAKE_RUNTIME_DIR:-} ]] || {
  echo 'FAIL: FAKE_RUNTIME_DIR is required' >&2
  exit 64
}

tool=${0##*/}
if [[ "$tool" == git ]]; then
  case " $* " in
    *' status --porcelain --untracked-files=all -- . :(exclude)evidence '*) source="$FAKE_RUNTIME_DIR/git-status.txt" ;;
    *' rev-parse HEAD '*) source="$FAKE_RUNTIME_DIR/git-revision.txt" ;;
    *)
      echo "FAIL: unexpected fake CLI invocation: $tool $*" >&2
      exit 64
      ;;
  esac
elif [[ "$tool" == kubectl ]]; then
  case "$*" in
    'config view --minify -o json') source="$FAKE_RUNTIME_DIR/kubeconfig.json" ;;
    '-n app-prod get rollout sample-app -o json') source="$FAKE_RUNTIME_DIR/rollout.json" ;;
    -n\ app-prod\ get\ replicasets\ -l\ rollouts-pod-template-hash=*\ -o\ json) source="$FAKE_RUNTIME_DIR/replicasets.json" ;;
    '-n app-prod get httproute sample-app -o json') source="$FAKE_RUNTIME_DIR/httproute.json" ;;
    '-n app-prod get analysisruns.argoproj.io -o json') source="$FAKE_RUNTIME_DIR/analysisruns.json" ;;
    *)
      echo "FAIL: unexpected fake CLI invocation: $tool $*" >&2
      exit 64
      ;;
  esac
else
case "$tool:$*" in
  'argocd:app get sample-app-prod -o json') source="$FAKE_RUNTIME_DIR/application.json" ;;
  'aws:eks describe-cluster --name course-prod --region ap-northeast-2 --output json') source="$FAKE_RUNTIME_DIR/cluster.json" ;;
  *)
    echo "FAIL: unexpected fake CLI invocation: $tool $*" >&2
    exit 64
    ;;
esac
fi

[[ -f "$source" ]] || {
  echo "FAIL: fake response is missing: $source" >&2
  exit 64
}
command cat "$source"
