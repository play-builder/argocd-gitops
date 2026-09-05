require 'json'
require 'yaml'
require 'open3'
require 'tmpdir'
def check(value, message); abort "FAIL: #{message}" unless value; end
renderer = 'scripts/render-platform-images.rb'
check(File.file?(renderer), 'typed platform image renderer is required')
handoff = {'schemaVersion' => 'platform.requirements/v2', 'outputs' => {
  'platform_istio_proxy_repository_url' => '111122223333.dkr.ecr.ap-northeast-2.amazonaws.com/playdevops/platform/istio-proxyv2',
  'platform_image_publisher_role_arn' => 'arn:aws:iam::111122223333:role/prod-playdevops-platform-image-publisher'}}
Dir.mktmpdir('mirror-handoff-') do |dir|
  file = "#{dir}/handoff.json"
  File.write(file, JSON.generate(handoff))
  out, status = Open3.capture2e('ruby', renderer, file, 'prod')
  check(status.success?, out)
  docs = YAML.load_stream(out).compact
  check(docs.count { |d| d['kind'] == 'Application' } == 2, 'renderer must not rewrite unrelated Applications')
  check(docs.count { |d| d['kind'] == 'ClusterImagePolicy' } == 1, 'renderer must not rewrite business policies')
  check(!out.include?('REPLACE_'), 'renderer left unresolved output placeholders')
  cases = {
    'public registry' => ['platform_istio_proxy_repository_url', 'docker.io/istio/proxyv2'],
    'wrong path' => ['platform_istio_proxy_repository_url', handoff['outputs']['platform_istio_proxy_repository_url'].sub('/platform/', '/')],
    'application role' => ['platform_image_publisher_role_arn', 'arn:aws:iam::111122223333:role/prod-playdevops-mini-commerce'],
    'cross account role' => ['platform_image_publisher_role_arn', 'arn:aws:iam::444455556666:role/prod-platform-image-publisher']
  }
  cases.each do |name, (key, value)|
    bad = Marshal.load(Marshal.dump(handoff)); bad['outputs'][key] = value
    File.write(file, JSON.generate(bad))
    _, status = Open3.capture2e('ruby', renderer, file, 'prod')
    check(!status.success?, "renderer accepted #{name}")
  end
  File.write(file, JSON.generate(handoff))
  _, status = Open3.capture2e('ruby', 'scripts/verify-platform-mirror-activation.rb', file, 'prod')
  check(!status.success?, 'activation must not accept static-only checks without explicit live verification')
  # A fork is supported only through reviewed owner configuration, never the handoff itself.
  fork = YAML.load_file('contracts/platform-requirements.yaml')
  publisher = fork['platformImageMirror']['publisher']
  publisher['repository'] = 'example-platform/EKS-infra'; publisher['repositoryId'] = '999888777'
  publisher['workflow'] = 'https://github.com/example-platform/EKS-infra/.github/workflows/publish-platform-images.yml@refs/heads/main'
  fork['platformImageMirror']['predicateType'] = 'https://github.com/example-platform/EKS-infra/attestations/platform.image-mirror/v1'
  File.write("#{dir}/fork.yaml", YAML.dump(fork))
  out, status = Open3.capture2e({'PLATFORM_CONTRACT' => "#{dir}/fork.yaml"}, 'ruby', renderer, file, 'prod')
  check(status.success? && out.include?(publisher['workflow']) && !out.include?('play-builder/EKS-infra') && out.include?('999888777'), 'reviewed fork owner configuration did not bind rendered trust')
  lock = YAML.load_file('versions.lock.yaml')
  bad_locks = {}
  bad_locks['unknown upstream'] = Marshal.load(Marshal.dump(lock))
  bad_locks['unknown upstream']['delivery']['platformImages']['istioProxy'][0]['upstreamReference'] = 'evil.invalid/proxy@sha256:' + 'a' * 64
  bad_locks['missing architecture'] = Marshal.load(Marshal.dump(lock))
  bad_locks['missing architecture']['delivery']['platformImages']['istioProxy'][0]['architectureDigests'].delete('linux/arm64')
  bad_locks['lock/image mismatch'] = Marshal.load(Marshal.dump(lock))
  release = bad_locks['lock/image mismatch']['delivery']['platformImages']['istioProxy'][0]
  release['indexDigest'] = 'sha256:' + 'a' * 64
  release['upstreamReference'] = 'registry.istio.io/release/proxyv2@' + release['indexDigest']
  bad_locks.each do |name, invalid|
    File.write("#{dir}/lock.yaml", YAML.dump(invalid))
    _, status = Open3.capture2e({'VERSION_LOCK' => "#{dir}/lock.yaml"}, 'ruby', renderer, file, 'prod')
    check(!status.success?, "renderer accepted #{name}")
  end
end
require_relative '../scripts/lib/platform_mirror'
contract = PlatformMirror.contract
release = PlatformMirror.releases.first
statement = {'_type' => 'https://in-toto.io/Statement/v1', 'predicateType' => contract['predicateType'],
  'subject' => [{'name' => handoff['outputs']['platform_istio_proxy_repository_url'], 'digest' => {'sha256' => release['indexDigest'].delete_prefix('sha256:')}}],
  'predicate' => {'schemaVersion' => 'platform.image-mirror/v1', 'upstreamReference' => release['upstreamReference'],
    'upstreamDigest' => release['indexDigest'], 'mirroredDigest' => release['indexDigest'], 'version' => release['version'],
    'publisher' => contract['publisher'].slice('repositoryId', 'workflow')}}
PlatformMirror.validate_statement!(statement, handoff['outputs']['platform_istio_proxy_repository_url'], release)
%w[upstreamReference upstreamDigest mirroredDigest version publisher].each do |key|
  invalid = Marshal.load(Marshal.dump(statement)); invalid['predicate'].delete(key)
  rejected = false
  begin; PlatformMirror.validate_statement!(invalid, handoff['outputs']['platform_istio_proxy_repository_url'], release); rescue StandardError; rejected = true; end
  check(rejected, "activation statement accepted missing #{key}")
end
ready = {'metadata' => {'generation' => 2}, 'status' => {'observedGeneration' => 2, 'conditions' => [{'type' => 'Ready', 'status' => 'True'}]}}
PlatformMirror.ready!(ready)
[{'observedGeneration' => 1, 'conditions' => [{'type' => 'Ready', 'status' => 'True'}]},
 {'observedGeneration' => 2, 'conditions' => [{'type' => 'Ready', 'status' => 'False'}]}].each do |status|
  rejected = false
  begin; PlatformMirror.ready!(ready.merge('status' => status)); rescue StandardError; rejected = true; end
  check(rejected, 'stale or unready admission prerequisite accepted')
end
puts 'PASS: typed mirror handoff and fail-closed activation statement validation; no live verification performed'
