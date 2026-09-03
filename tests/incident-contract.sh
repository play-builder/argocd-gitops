#!/usr/bin/env bash
set -Eeuo pipefail

test_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repository_root=$(cd -- "$test_root/.." && pwd)
catalog_root="$repository_root/incidents/catalog"
expected_ids='INC-AWS-01 INC-AWS-02 INC-AWS-03 INC-AWS-04 INC-AWS-05 INC-CI-01 INC-CI-02 INC-SC-01 INC-SC-02 INC-SC-03 INC-SC-04 INC-GO-01 INC-GO-02 INC-SEC-01 INC-K8S-01 INC-K8S-02 INC-K8S-03 INC-K8S-04 INC-OBS-01 INC-OBS-02 INC-REL-01 INC-REL-02 INC-REL-03 INC-REL-04 INC-DB-01 INC-DB-02 INC-DB-03 INC-DB-04 INC-DB-05 INC-DB-06 INC-RES-01 INC-RES-02 INC-CAP-01 INC-CAP-02 INC-CLN-01 INC-CLN-02 INC-CLN-03'

fail() { echo "FAIL: $*" >&2; exit 1; }

validate_file() {
  local file=$1 json id case_name test_file
  [[ -f "$file" ]] || fail "incident file not found: $file"
  json=$(yq -o=json '.' "$file") || fail "$(basename "$file") is not valid YAML"
  jq -e '
    (keys | sort) == ["chapter","cleanup","evidence","id","inject","maximumDuration","preventionTest","scope","stop","tier"] and
    (.id | test("^INC-[A-Z0-9]+-[0-9]{2}$")) and
    (.chapter | type == "number") and (.tier | IN("Core-must","Core-should","Extended")) and
    (.maximumDuration | test("^[1-9][0-9]*[sm]$")) and
    (.scope | type == "object" and (.environment|type=="string" and length>0) and (.namespaces|type=="array" and length>0) and (.forbiddenNamespaces|type=="array")) and
    (.inject | type == "object" and (.action|type=="string" and length>0)) and
    (.stop | type == "object" and (.action|type=="string" and length>0)) and
    (.evidence | (keys|sort) == ["baseline","cleanup","detect","inject","mitigate","prevent","reconcile","recover"] and all(to_entries[]; .value|type=="array" and length>0)) and
    (.cleanup | type=="object" and (.action|type=="string" and length>0) and .externalSecretLifecycle.targetSecretOwnerReferenceGC == true and .externalSecretLifecycle.providerSecretRetained == true)
  ' <<<"$json" >/dev/null || fail "$(basename "$file") has an incomplete incident lifecycle"
  id=$(jq -r .id <<<"$json")
  case_name=$(jq -r '.preventionTest' <<<"$json")
  [[ "$case_name" =~ ^(tests/[A-Za-z0-9_./-]+\.sh)[[:space:]]--case[[:space:]]([A-Za-z0-9_.-]+)$ ]] || fail "$(basename "$file") has an unsafe preventionTest"
  test_file="$repository_root/${BASH_REMATCH[1]}"
  [[ -x "$test_file" ]] || fail "$(basename "$file") prevention test is not executable"
  grep -Eq "(case_|\|[[:space:]]*${BASH_REMATCH[2]}\)|${BASH_REMATCH[2]})" "$test_file" || fail "$(basename "$file") references an unknown prevention case"
  bash "$test_file" --case "${BASH_REMATCH[2]}" >/dev/null || fail "$(basename "$file") preventionTest failed"
}

validate_catalog() {
  local ids actual file
  [[ -d "$catalog_root" ]] || fail "incident catalog directory not found"
  actual=$(find "$catalog_root" -maxdepth 1 -type f -name 'INC-*.yaml' -exec basename {} .yaml \; | sort | tr '\n' ' ' | sed 's/[[:space:]]*$//')
  ids=$(printf '%s\n' $expected_ids | sort | tr '\n' ' ' | sed 's/[[:space:]]*$//')
  [[ "$actual" == "$ids" ]] || fail "incident catalog IDs do not match the canonical 37-ID set"
  for file in "$catalog_root"/INC-*.yaml; do validate_file "$file"; done
}

requested=all
fixture=
while (($#)); do case "$1" in --all) requested=all; shift ;; --fixture) fixture=${2:?missing fixture}; requested=fixture; shift 2 ;; *) echo "Usage: $0 --all|--fixture path" >&2; exit 2 ;; esac; done
if [[ "$requested" == fixture ]]; then validate_file "$fixture"; else validate_catalog; fi
echo "PASS: incident lifecycle metadata is valid."
