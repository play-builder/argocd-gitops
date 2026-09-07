# Canonical DEV_READY identity and capture validity. Call with --arg now UTC.
    def canonical_utc_seconds:
      . as $value |
      type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$") and
      (try ((fromdateiso8601 | strftime("%Y-%m-%dT%H:%M:%SZ")) == $value) catch false);
    . as $root |
    .workflow as $workflow |
    (.workflow.runUrl | capture("^https://github\\.com/(?<repository>[^/\\s]+/mini-commerce)/actions/runs/(?<id>[0-9]+)$")) as $run |
    (.image.repository | capture("^(?<account>[0-9]{12})\\.dkr\\.ecr\\.(?<region>ap-northeast-2|us-east-1)\\.amazonaws\\.com/(?<name>[a-z0-9]+([._/-][a-z0-9]+)*)$")) as $ecr |
    (.cluster.arn | capture("^arn:aws:eks:(?<region>ap-northeast-2|us-east-1):(?<account>[0-9]{12}):cluster/[A-Za-z0-9][A-Za-z0-9_-]{0,99}$")) as $cluster |
    ((.schemaVersion == "playbuilder.dev-ready/v1" and keys == ["attestation","cluster","environment","expiresAt","gitops","image","issuedAt","region","schemaVersion","slo","sourceSha","workflow"]) or
     (.schemaVersion == "playbuilder.dev-ready/v2" and .repositoryId == "1352247019" and keys == ["attestation","cluster","environment","expiresAt","gitops","image","issuedAt","region","repositoryId","schemaVersion","slo","sourceSha","workflow"])) and .environment == "dev" and
    (.region | IN("ap-northeast-2","us-east-1")) and
    (.sourceSha | test("^[0-9a-f]{40}$")) and
    ($workflow | (keys | sort) == ["event","name","runAttempt","runId","runUrl"]) and
    $workflow.name == "ci" and $workflow.event == "push" and
    ($workflow.runId | type == "string" and test("^[0-9]+$")) and
    ($workflow.runAttempt | type == "number" and floor == . and . >= 1) and
    $run.id == $workflow.runId and
    (.image | (keys | sort) == ["indexDigest","platforms","repository"]) and
    .image.platforms == ["linux/amd64","linux/arm64"] and
    (.image.indexDigest | test("^sha256:[0-9a-f]{64}$")) and
    (($ecr.name | length) >= 2 and ($ecr.name | length) <= 256) and
    (.attestation | (keys | sort) == ["githubId","githubUrl","ociProvenanceDigest","ociSbomDigest"]) and
    (.attestation.githubId | type == "string" and test("^[0-9]+$")) and
    .attestation.githubUrl == ("https://github.com/" + $run.repository + "/attestations/" + .attestation.githubId) and
    (.attestation.ociSbomDigest | test("^sha256:[0-9a-f]{64}$")) and
    (.attestation.ociProvenanceDigest | test("^sha256:[0-9a-f]{64}$")) and
    (.gitops | (keys | sort) == ["devRevision"]) and (.gitops.devRevision | test("^[0-9a-f]{40}$")) and
    (.cluster | (keys | sort) == ["arn"]) and (.slo | (keys | sort) == ["evidenceId"]) and
    (.slo.evidenceId | type == "string" and test("[^[:space:]\uFEFF]")) and
    $ecr.region == $root.region and $cluster.region == $root.region and
    (.issuedAt | canonical_utc_seconds) and (.expiresAt | canonical_utc_seconds) and
    ($now | canonical_utc_seconds) and
    ((.issuedAt | fromdateiso8601) <= ($now | fromdateiso8601) and ($now | fromdateiso8601) < (.expiresAt | fromdateiso8601))
