#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
ruby -ryaml -rjson -rtempfile -ropen3 -e '
lock=YAML.load_file("versions.lock.yaml")
lock["delivery"]["helmSources"][0]["sha256"]="0"*64
Tempfile.create(["invalid-lock",".json"]) do |f|
 f.write(JSON.generate(lock));f.flush
 out,s=Open3.capture2e({"VERSION_LOCK"=>f.path},"bash","scripts/validate-rendered-manifests.sh","--locks-only")
 abort "FAIL: corrupted archive lock accepted" if s.success? || !out.include?("checksum mismatch")
end
puts "PASS: actual archive checksum gate rejects corrupted lock"
'
