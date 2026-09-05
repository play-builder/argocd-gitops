#!/usr/bin/env bash
set -Eeuo pipefail

[[ -n ${FAKE_CLEANUP_DIR:-} ]] || {
  echo 'FAIL: FAKE_CLEANUP_DIR is required' >&2
  exit 64
}

tool=${0##*/}
emit() {
  [[ -f "$1" ]] || {
    echo "FAIL: fake cleanup response is missing: $1" >&2
    exit 64
  }
  command cat "$1"
}

if [[ "$tool" == git ]]; then
  case " $* " in
    *' rev-parse HEAD '*) emit "$FAKE_CLEANUP_DIR/git-revision.txt" ;;
    *' status --porcelain --untracked-files=all -- . :(exclude)evidence '*) emit "$FAKE_CLEANUP_DIR/git-status.txt" ;;
    *) echo "FAIL: unexpected fake git invocation: $*" >&2; exit 64 ;;
  esac
  exit 0
fi

if [[ "$tool" == aws ]]; then
  case "$*" in
    'eks describe-cluster --name course-dev --region ap-northeast-2 --output json') emit "$FAKE_CLEANUP_DIR/dev-cluster.json" ;;
    'eks describe-cluster --name course-prod --region ap-northeast-2 --output json') emit "$FAKE_CLEANUP_DIR/prod-cluster.json" ;;
    secretsmanager\ describe-secret\ --secret-id\ *' --region ap-northeast-2 --output json') emit "$FAKE_CLEANUP_DIR/provider-secret.json" ;;
    *) echo "FAIL: unexpected fake aws invocation: $*" >&2; exit 64 ;;
  esac
  exit 0
fi

[[ "$tool" == kubectl ]] || {
  echo "FAIL: unexpected fake CLI: $tool" >&2
  exit 64
}
[[ ${1:-} == --context && -n ${2:-} ]] || {
  echo "FAIL: fake kubectl requires an explicit context" >&2
  exit 64
}
context=$2
shift 2
case "$context" in
  dev-context) environment=dev ;;
  prod-context) environment=prod ;;
  *) echo "FAIL: unknown fake Kubernetes context: $context" >&2; exit 64 ;;
esac

case "$*" in
  'config view --minify -o json') emit "$FAKE_CLEANUP_DIR/$environment-kubeconfig.json" ;;
  'api-resources -o name') emit "$FAKE_CLEANUP_DIR/$environment-api-resources.txt" ;;
  "-n argocd get application mini-commerce-$environment -o json") emit "$FAKE_CLEANUP_DIR/$environment-application.json" ;;
  "-n argocd get application mini-commerce-$environment -o name --ignore-not-found") emit "$FAKE_CLEANUP_DIR/$environment-application-name.txt" ;;
  'get jobs.batch -A -o json') emit "$FAKE_CLEANUP_DIR/$environment-jobs.json" ;;
  'get statefulsets.apps -A -o json') emit "$FAKE_CLEANUP_DIR/$environment-statefulsets.json" ;;
  'get testruns.k6.io -A -o json') emit "$FAKE_CLEANUP_DIR/$environment-load.json" ;;
  'get podchaos.chaos-mesh.org,networkchaos.chaos-mesh.org -A -o json') emit "$FAKE_CLEANUP_DIR/$environment-chaos.json" ;;
  'get volumesnapshotcontents.snapshot.storage.k8s.io -o json') emit "$FAKE_CLEANUP_DIR/$environment-snapshotcontents.json" ;;
  '-n app-prod get configmap mini-commerce-rollback-candidates -o name --ignore-not-found') emit "$FAKE_CLEANUP_DIR/prod-rollback-configmap-name.txt" ;;
  'get namespace '*'-o json --ignore-not-found')
    namespace=$3
    emit "$FAKE_CLEANUP_DIR/$environment-$namespace-namespace.json"
    ;;
  'get rollouts.argoproj.io,deployments.apps,statefulsets.apps,jobs.batch,externalsecrets.external-secrets.io,podchaos.chaos-mesh.org,networkchaos.chaos-mesh.org -n '*'-o json')
    namespace=${*: -3:1}
    emit "$FAKE_CLEANUP_DIR/$environment-$namespace-workloads.json"
    ;;
  'get persistentvolumeclaims -n '*'-o json')
    namespace=${*: -3:1}
    emit "$FAKE_CLEANUP_DIR/$environment-$namespace-pvcs.json"
    ;;
  'get volumesnapshots.snapshot.storage.k8s.io -n '*'-o json')
    namespace=${*: -3:1}
    emit "$FAKE_CLEANUP_DIR/$environment-$namespace-snapshots.json"
    ;;
  *) echo "FAIL: unexpected fake kubectl invocation: --context $context $*" >&2; exit 64 ;;
esac
