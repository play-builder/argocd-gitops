require 'yaml'
require 'json'

# References and verified statements only. Never authenticates to or writes a registry.
module PlatformMirror
  ROOT = File.expand_path('../..', __dir__)
  TOKEN = 'REPLACE_FROM_EKS_PLATFORM_ISTIO_PROXY_ECR'
  DIGEST = /\Asha256:[a-f0-9]{64}\z/
  def self.contract
    config = YAML.load_file(ENV.fetch('PLATFORM_CONTRACT', File.join(ROOT, 'contracts/platform-requirements.yaml'))).fetch('platformImageMirror')
    p = config.fetch('publisher')
    raise 'exact reviewed publisher repository required' unless p['repository'].match?(/\A[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\z/)
    raise 'numeric publisher repository ID required' unless p['repositoryId'].is_a?(String) && p['repositoryId'].match?(/\A[1-9][0-9]*\z/)
    raise 'exact protected publisher workflow required' unless p['workflow'] == "https://github.com/#{p['repository']}/.github/workflows/publish-platform-images.yml@refs/heads/main" && p['environment'] == 'production'
    raise 'predicate owner mismatch' unless config['predicateType'] == "https://github.com/#{p['repository']}/attestations/platform.image-mirror/v1"
    config
  end

  def self.releases
    entries = YAML.load_file(ENV.fetch('VERSION_LOCK', File.join(ROOT, 'versions.lock.yaml'))).fetch('delivery').fetch('platformImages').fetch('istioProxy')
    raise 'exact stable and candidate releases required' unless entries.map { |r| r['version'] }.sort == %w[1.30.4 1.31.0]
    entries.each do |r|
      source = r['version'] == '1.30.4' ? 'registry.istio.io/release/proxyv2' : 'docker.io/istio/proxyv2'
      raise 'invalid approved index digest' unless r['indexDigest'].match?(DIGEST)
      raise 'source must be exact approved repository and index' unless r['upstreamReference'] == "#{source}@#{r['indexDigest']}"
      raise 'two architecture child digests required' unless r['architectureDigests'].keys.sort == %w[linux/amd64 linux/arm64] && r['architectureDigests'].values.all? { |d| d.match?(DIGEST) }
    end
    entries
  end

  def self.repository(handoff)
    raise 'platform.requirements/v2 required' unless handoff['schemaVersion'] == 'platform.requirements/v2'
    c = contract
    url = handoff.fetch('outputs').fetch(c['repositoryOutput'])
    match = /\A([0-9]{12})\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com\/[a-z0-9][a-z0-9._\/-]*\/platform\/istio-proxyv2\z/.match(url)
    raise 'dedicated private ECR platform repository required' unless match
    role = handoff['outputs'].fetch(c['publisherRoleOutput'])
    raise 'dedicated same-account platform publisher role required' unless role.match?(/\Aarn:aws:iam::#{match[1]}:role\/[A-Za-z0-9+=,.@_-]+-platform-image-publisher\z/)
    url
  end

  def self.policy(repository, env)
    policy = YAML.load_file(File.join(ROOT, 'platform/security/sigstore/base/platform-mirror-policy.yaml'))
    c = contract
    # Forks must change the reviewed owner contract, not supply a trusted identity in an untrusted handoff.
    json = JSON.generate(policy).gsub(TOKEN, repository)
    json = json.gsub('https://github.com/play-builder/EKS-infra', "https://github.com/#{c['publisher']['repository']}").gsub('405337777', c['publisher']['repositoryId'])
    policy = JSON.parse(json)
    policy['spec']['mode'] = env == 'prod' ? 'enforce' : 'warn'
    expected = releases.map { |r| {'glob' => "#{repository}@#{r['indexDigest']}"} }
    raise 'CIP and approved image lock differ' unless policy['spec']['images'] == expected
    policy
  end

  def self.validate_statement!(statement, repository, release)
    c = contract
    expected = {'schemaVersion' => 'platform.image-mirror/v1', 'upstreamReference' => release['upstreamReference'],
                'upstreamDigest' => release['indexDigest'], 'mirroredDigest' => release['indexDigest'], 'version' => release['version'],
                'publisher' => c['publisher'].slice('repositoryId', 'workflow')}
    subject = [{'name' => repository, 'digest' => {'sha256' => release['indexDigest'].delete_prefix('sha256:')}}]
    raise 'verified statement type/predicate/subject mismatch' unless statement['_type'] == 'https://in-toto.io/Statement/v1' && statement['predicateType'] == c['predicateType'] && statement['subject'] == subject
    raise 'mirror statement mismatch; not upstream build provenance' unless statement['predicate'] == expected
    true
  end

  def self.ready!(resource)
    raise 'current observedGeneration required' unless resource.dig('status', 'observedGeneration') == resource.dig('metadata', 'generation') && resource.dig('metadata', 'generation').is_a?(Integer)
    raise 'Ready=True required' unless resource.dig('status', 'conditions').to_a.any? { |c| c['type'] == 'Ready' && c['status'] == 'True' }
  end
end
