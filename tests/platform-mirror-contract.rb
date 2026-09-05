require 'yaml'
require 'json'
require 'open3'
require 'tmpdir'
require 'timeout'
require 'digest'

def check(value, message)
  abort "FAIL: #{message}" unless value
end

def run(*cmd)
  Open3.popen3(*cmd) do |stdin, stdout, stderr, wait|
    stdin.close
    out = Thread.new { stdout.read }
    err = Thread.new { stderr.read }
    begin
      Timeout.timeout(25) { wait.value }
    rescue Timeout::Error
      Process.kill('TERM', wait.pid)
      abort "FAIL: bounded local command timed out: #{cmd.first}"
    end
    check(wait.value.success?, "#{cmd.first}: #{err.value}")
    out.value
  end
end

expected = {
  '1.30.4' => 'sha256:43b6aeab7428470d3d0ea6b6f0bc217e5b36df2b279bba337643df48590226d9',
  '1.31.0' => 'sha256:e3b973cce2442c2883188d8cf839dff8a21075fab0e00e5079df6ef28c9caf17'
}
repository = '111122223333.dkr.ecr.ap-northeast-2.amazonaws.com/playdevops/platform/istio-proxyv2'
cache = ENV.fetch('CHART_CACHE_DIR', '/tmp/mini-commerce-locked-charts')
lock = YAML.load_file('versions.lock.yaml')
check(run('cue', 'version').lines.first.strip == "cue version v#{lock['tooling']['cue']['version']}", 'use the same CUE version as the locked policy-controller')
check(run('istioctl', 'version', '--remote=false').lines.first.include?(lock['tooling']['istioctl']['version']), 'use locked istioctl')
%w[dev prod].each do |env|
  apps = YAML.load_stream(run('kubectl', 'kustomize', "argocd/bootstrap/#{env}")).compact
  apps.select { |a| a.dig('spec', 'source', 'chart') == 'istiod' }.each do |app|
    source = app['spec']['source']
    version = source['targetRevision']
    archive = File.join(cache, "istiod-#{version}.tgz")
    chart_lock = lock['delivery']['helmSources'].find { |c| c['chart'] == 'istiod' && c['version'] == version }
    check(Digest::SHA256.file(archive).hexdigest == chart_lock['sha256'], 'untrusted injector chart')
    Dir.mktmpdir('mirror-inject-') do |dir|
      values = JSON.parse(JSON.generate(source['helm']['valuesObject']).gsub('REPLACE_FROM_EKS_PLATFORM_ISTIO_PROXY_ECR', repository))
      File.write("#{dir}/helm.yaml", YAML.dump(values))
      rendered = YAML.load_stream(run('helm', 'template', source['helm']['releaseName'], archive,
                                     '--namespace', 'istio-system', '-f', "#{dir}/helm.yaml")).compact
      injector = rendered.find { |d| d['kind'] == 'ConfigMap' && d.dig('data', 'config') && d.dig('data', 'values') }
      mesh = rendered.find { |d| d['kind'] == 'ConfigMap' && d.dig('data', 'mesh') }
      File.write("#{dir}/inject.yaml", injector['data']['config'])
      File.write("#{dir}/values.json", injector['data']['values'])
      File.write("#{dir}/mesh.yaml", mesh['data']['mesh'])
      File.write("#{dir}/pod.yaml", YAML.dump({
        'apiVersion' => 'v1', 'kind' => 'Pod',
        'metadata' => {'name' => 'mirror-fixture', 'namespace' => "app-#{env}"},
        'spec' => {'containers' => [{'name' => 'app', 'image' => 'fixture.invalid/business@sha256:' + 'a' * 64}]}
      }))
      # An explicit revision avoids RevisionOrDefault's cluster lookup even with local files.
      result = YAML.load(run({'KUBECONFIG' => '/dev/null'}, 'istioctl', 'kube-inject',
                             '--kubeconfig', '/dev/null', '--revision', values['revision'],
                             '--injectConfigFile', "#{dir}/inject.yaml", '--meshConfigFile', "#{dir}/mesh.yaml",
                             '--valuesFile', "#{dir}/values.json", '-f', "#{dir}/pod.yaml"))
      containers = result['spec'].fetch('containers') + result['spec'].fetch('initContainers', [])
      check(containers.reject { |c| c['name'] == 'app' }.map { |c| c['name'] }.sort == %w[istio-init istio-proxy],
            'an unreviewed injected container appeared')
      proxy = containers.find { |c| c['name'] == 'istio-proxy' }
      init = containers.find { |c| c['name'] == 'istio-init' }
      check(proxy && init, 'actual injector must cover proxy and init')
      [proxy, init].each do |container|
        check(container['image'] == "#{repository}@#{expected.fetch(version)}",
              "#{env}/#{version}/#{container['name']} not exact private ECR digest: #{container['image']}")
      end
      gateway = apps.find { |a| a.dig('spec', 'source', 'chart') == 'gateway' && a.dig('spec', 'source', 'targetRevision') == version }
      gs = gateway['spec']['source']
      gateway_archive = File.join(cache, "gateway-#{version}.tgz")
      gateway_lock = lock['delivery']['helmSources'].find { |c| c['chart'] == 'gateway' && c['version'] == version }
      check(Digest::SHA256.file(gateway_archive).hexdigest == gateway_lock['sha256'], 'untrusted gateway chart')
      File.write("#{dir}/gateway-values.yaml", YAML.dump(gs['helm']['valuesObject']))
      gateway_docs = YAML.load_stream(run('helm', 'template', gs['helm']['releaseName'], gateway_archive,
                                         '--namespace', 'istio-system', '-f', "#{dir}/gateway-values.yaml")).compact
      deployment = gateway_docs.find { |d| d['kind'] == 'Deployment' }
      File.write("#{dir}/gateway.yaml", YAML.dump(deployment))
      injected_gateway = YAML.load(run({'KUBECONFIG' => '/dev/null'}, 'istioctl', 'kube-inject',
                                       '--kubeconfig', '/dev/null', '--revision', values['revision'],
                                       '--injectConfigFile', "#{dir}/inject.yaml", '--meshConfigFile', "#{dir}/mesh.yaml",
                                       '--valuesFile', "#{dir}/values.json", '-f', "#{dir}/gateway.yaml"))
      pod = injected_gateway.dig('spec', 'template', 'spec')
      images = (pod.fetch('containers') + pod.fetch('initContainers', [])).map { |c| c['image'] }
      check(images == ["#{repository}@#{expected.fetch(version)}"], "actual gateway injection escaped private ECR: #{images}")
    end
  end
end
puts 'PASS: actual locked Istio injector proxy/init and gateway images use private ECR index digests'

# Fail if a platform image exemption is static, wildcarded, or lacks semantic predicate checks.
%w[dev prod].each do |env|
  policies = YAML.load_stream(run('kubectl', 'kustomize', "platform/security/sigstore/overlays/#{env}")).compact
  policy = policies.find { |d| d.dig('metadata', 'name') == 'platform-istio-mirror' }
  check(policy, 'dedicated platform mirror CIP required')
  globs = policy['spec']['images'].map { |i| i['glob'].sub('REPLACE_FROM_EKS_PLATFORM_ISTIO_PROXY_ECR', repository) }
  check(globs.sort == expected.values.map { |d| "#{repository}@#{d}" }.sort, 'only two approved ECR images may match')
  ['docker.io/istio/proxyv2@' + expected.values.first, repository + '@sha256:' + 'b' * 64,
   repository.sub('/platform/', '/unknown/') + '@' + expected.values.first,
   '111122223333.dkr.ecr.ap-northeast-2.amazonaws.com/playdevops/mini-commerce@' + expected.values.first].each do |image|
    check(globs.none? { |glob| File.fnmatch?(glob, image) }, "no-match deny would be bypassed: #{image}")
  end
  policy['spec']['authorities'].each do |authority|
    check(!authority.key?('static'), 'unsigned static exemption forbidden')
    check(authority['signatureFormat'] == 'bundle', 'signed bundle required')
    identities = authority.dig('keyless', 'identities')
    check(identities == [{'issuer' => 'https://token.actions.githubusercontent.com',
                         'subject' => 'https://github.com/play-builder/EKS-infra/.github/workflows/publish-platform-images.yml@refs/heads/main'}],
          'exact platform publisher identity required')
    attestation = authority.fetch('attestations').fetch(0)
    check(attestation['predicateType'] == 'https://github.com/play-builder/EKS-infra/attestations/platform.image-mirror/v1', 'wrong mirror predicate')
    check(attestation.dig('policy', 'type') == 'cue', 'semantic predicate validation required')
    Dir.mktmpdir('mirror-cue-') do |dir|
      File.write("#{dir}/policy.cue", attestation['policy']['data'].gsub('REPLACE_FROM_EKS_PLATFORM_ISTIO_PROXY_ECR', repository))
      expected.each do |version, digest|
        upstream = version == '1.30.4' ? 'registry.istio.io/release/proxyv2' : 'docker.io/istio/proxyv2'
        valid = {'_type' => 'https://in-toto.io/Statement/v1',
                 'subject' => [{'name' => repository, 'digest' => {'sha256' => digest.delete_prefix('sha256:')}}],
                 'predicateType' => attestation['predicateType'],
                 'predicate' => {'schemaVersion' => 'platform.image-mirror/v1', 'version' => version,
                                 'upstreamReference' => "#{upstream}@#{digest}", 'upstreamDigest' => digest,
                                 'mirroredDigest' => digest, 'publisher' => {'repositoryId' => '405337777',
                                 'workflow' => identities[0]['subject']}}}
        cases = {'valid' => valid}
        {'unknown-source' => ['upstreamReference', "evil.invalid/proxy@#{digest}"],
         'unknown-digest' => ['upstreamDigest', 'sha256:' + 'a' * 64],
         'changed-target' => ['mirroredDigest', 'sha256:' + 'b' * 64],
         'version-confusion' => ['version', '1.29.0']}.each do |name, (key, value)|
          cases[name] = Marshal.load(Marshal.dump(valid)); cases[name]['predicate'][key] = value
        end
        cases['wrong-publisher'] = Marshal.load(Marshal.dump(valid)); cases['wrong-publisher']['predicate']['publisher']['repositoryId'] = '123'
        cases['wrong-workflow'] = Marshal.load(Marshal.dump(valid)); cases['wrong-workflow']['predicate']['publisher']['workflow'] = 'https://github.com/play-builder/EKS-infra/.github/workflows/other.yml@refs/heads/main'
        cases['wrong-subject'] = Marshal.load(Marshal.dump(valid)); cases['wrong-subject']['subject'][0]['digest']['sha256'] = 'c' * 64
        cases['missing-predicate'] = Marshal.load(Marshal.dump(valid)); cases['missing-predicate'].delete('predicate')
        cases.each do |name, statement|
          File.write("#{dir}/statement.json", JSON.generate(statement))
          output, status = Open3.capture2e('cue', 'vet', '-c', "#{dir}/policy.cue", "#{dir}/statement.json")
          check(status.success? == (name == 'valid'), "actual CUE evaluator #{env}/#{version}/#{name}: #{output}")
        end
      end
    end
  end
end
puts 'PASS: rendered platform CIP and actual CUE positive/negative predicates (not cryptographic verification)'
