#!/usr/bin/env ruby
# Operator-invoked READ-ONLY live gate. Does not label namespaces, sync, or copy/sign images.
require 'open3'
require_relative 'lib/platform_mirror'
def command(*cmd)
  out, err, status = Open3.capture3(*cmd)
  raise "#{cmd.first} verification failed: #{err}" unless status.success?
  JSON.parse(out)
end
begin
  raise 'requires explicit --verify-live; static fixtures never authorize activation' unless ARGV[2] == '--verify-live'
  handoff = JSON.parse(File.read(ARGV.fetch(0))); env = ARGV.fetch(1)
  raise 'environment must be dev or prod' unless %w[dev prod].include?(env)
  repository = PlatformMirror.repository(handoff)
  contract = PlatformMirror.contract
  PlatformMirror.releases.each do |release|
    verified = command('gh', 'attestation', 'verify', "oci://#{repository}@#{release['indexDigest']}", '--bundle-from-oci',
      '--repo', contract['publisher']['repository'], '--cert-identity', contract['publisher']['workflow'],
      '--cert-oidc-issuer', 'https://token.actions.githubusercontent.com', '--source-ref', 'refs/heads/main',
      '--predicate-type', contract['predicateType'], '--format', 'json')
    raise 'no matching cryptographically verified mirror statement' unless verified.any? do |result|
      begin
        PlatformMirror.validate_statement!(result.fetch('verificationResult').fetch('statement'), repository, release)
      rescue StandardError
        false
      end
    end
  end
  expected = PlatformMirror.policy(repository, env)
  actual = command('kubectl', 'get', 'clusterimagepolicy', 'platform-istio-mirror', '-o', 'json')
  raise 'live platform CIP does not match reviewed policy' unless actual['spec'] == expected['spec']
  PlatformMirror.ready!(actual)
  %w[mini-commerce-slsa mini-commerce-spdx].each do |name|
    business = command('kubectl', 'get', 'clusterimagepolicy', name, '-o', 'json')
    PlatformMirror.ready!(business)
    repository_url = handoff.fetch('outputs').fetch('mini_commerce_ecr_repository_url')
    raise 'private business ECR required' unless repository_url.match?(/\A[0-9]{12}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com\/[a-z0-9._\/-]+\z/)
    filename = name.delete_prefix('mini-commerce-') + '-policy.yaml'
    original = YAML.load_file(File.join(PlatformMirror::ROOT, 'platform/security/sigstore/base', filename))
    expected_spec = JSON.parse(JSON.generate(original['spec']).gsub('REPLACE_FROM_EKS_MINI_COMMERCE_ECR', repository_url))
    expected_spec['mode'] = env == 'prod' ? 'enforce' : 'warn'
    raise 'business SLSA/SPDX policy drifted' unless business['spec'] == expected_spec
  end
  PlatformMirror.ready!(command('kubectl', 'get', 'trustroot', 'github', '-o', 'json'))
  deployment = command('kubectl', '-n', 'cosign-system', 'get', 'deployment', 'policy-controller-webhook', '-o', 'json')
  raise 'two current policy-controller replicas required' unless deployment.dig('status', 'observedGeneration') == deployment.dig('metadata', 'generation') && deployment.dig('status', 'availableReplicas').to_i >= 2
  webhook = command('kubectl', 'get', 'validatingwebhookconfiguration', 'policy.sigstore.dev', '-o', 'json')
  raise 'fail-closed admission webhook required' unless webhook.fetch('webhooks').any? && webhook['webhooks'].all? { |w| w['failurePolicy'] == 'Fail' }
  config = command('kubectl', '-n', 'cosign-system', 'get', 'configmap', 'config-policy-controller', '-o', 'json')
  raise 'no-match policy must remain deny' unless [nil, 'deny'].include?(config.dig('data', 'no-match-policy'))
  puts 'VERIFIED: live mirror signatures and admission prerequisites; no namespace was activated.'
  puts 'STOP: manual approval, actual injected Pod admission (including negative probes), Task 9 traffic, and reinjection gates still required.'
rescue StandardError => e
  warn "FAIL: #{e.message}"; exit 1
end
