require 'yaml'
require 'json'
require 'open3'
require 'tmpdir'
require 'digest'
require 'timeout'

Dir.chdir(File.expand_path('..', __dir__))
def check(value, message)
  abort "FAIL: #{message}" unless value
end
def run(*cmd)
  out, status = Timeout.timeout(30) { Open3.capture2e(*cmd) }
  check(status.success?, "#{cmd.first}: #{out}")
  out
end
def restricted(pod)
  spec = pod.fetch('spec')
  check(!spec['hostNetwork'] && !spec['hostPID'] && !spec['hostIPC'], 'application must not share host namespaces')
  check(!spec.fetch('volumes', []).any? { |v| v.key?('hostPath') }, 'application hostPath forbidden')
  check(spec.dig('securityContext', 'seccompProfile', 'type') == 'RuntimeDefault', 'application seccomp profile missing')
  (spec.fetch('containers') + spec.fetch('initContainers', [])).each do |container|
    sc = container.fetch('securityContext', {})
    check(sc['allowPrivilegeEscalation'] == false && sc['privileged'] != true, "#{container['name']} permits privilege escalation")
    check(sc.dig('capabilities', 'drop').to_a.include?('ALL') && (sc.dig('capabilities', 'add').to_a - ['NET_BIND_SERVICE']).empty?, "#{container['name']} has restricted-forbidden capabilities")
    effective = spec.fetch('securityContext', {}).merge(sc)
    check(effective['runAsNonRoot'] == true && effective.fetch('runAsUser', 1) != 0, "#{container['name']} can run as root")
  end
end
cache = ENV.fetch('CHART_CACHE_DIR', '/tmp/mini-commerce-locked-charts')
lock = YAML.load_file('versions.lock.yaml')
repository = '111122223333.dkr.ecr.ap-northeast-2.amazonaws.com/playdevops/platform/istio-proxyv2'
%w[dev prod].each do |environment|
  bootstrap = YAML.load_stream(run('kubectl', 'kustomize', "argocd/bootstrap/#{environment}")).compact
  app_render = YAML.load_stream(run('helm', 'template', 'mini-commerce', 'charts/mini-commerce',
    '-f', "envs/#{environment}/values.yaml", '-f', "envs/#{environment}/pre-cutover-ownership-values.yaml",
    '--set-string', 'image.repository=example.invalid/mini-commerce', '--set-string', "image.digest=sha256:#{'a' * 64}",
    '--set-string', 'database.migrationImage.repository=example.invalid/mini-commerce', '--set-string', "database.migrationImage.digest=sha256:#{'a' * 64}")).compact
  workload = app_render.find { |r| %w[Deployment Rollout].include?(r['kind']) && r['metadata']['name'] == 'mini-commerce' }
  check(workload, 'actual Mini Commerce workload render missing')
  bootstrap.select { |r| r.dig('spec', 'source', 'chart') == 'istiod' }.each do |application|
    source = application['spec']['source']
    version = source['targetRevision']
    chart = lock['delivery']['helmSources'].find { |c| c['chart'] == 'istiod' && c['version'] == version }
    archive = File.join(cache, "istiod-#{version}.tgz")
    check(Digest::SHA256.file(archive).hexdigest == chart['sha256'], 'injector archive integrity failure')
    Dir.mktmpdir('cni-injection-') do |directory|
      values = JSON.parse(JSON.generate(source['helm']['valuesObject']).gsub('REPLACE_FROM_EKS_PLATFORM_ISTIO_PROXY_ECR', repository))
      File.write("#{directory}/helm.yaml", YAML.dump(values))
      docs = YAML.load_stream(run('helm', 'template', source['helm']['releaseName'], archive, '--namespace', 'istio-system', '-f', "#{directory}/helm.yaml")).compact
      injector = docs.find { |r| r['kind'] == 'ConfigMap' && r.dig('data', 'config') && r.dig('data', 'values') }
      mesh = docs.find { |r| r['kind'] == 'ConfigMap' && r.dig('data', 'mesh') }
      File.write("#{directory}/inject.yaml", injector['data']['config'])
      File.write("#{directory}/values.json", injector['data']['values'])
      File.write("#{directory}/mesh.yaml", mesh['data']['mesh'])
      pod = {'apiVersion' => 'v1', 'kind' => 'Pod', 'metadata' => workload['spec']['template']['metadata'].merge('name' => 'mini-commerce', 'namespace' => "app-#{environment}"), 'spec' => workload['spec']['template']['spec']}
      File.write("#{directory}/pod.yaml", YAML.dump(pod))
      injected = YAML.load(run({'KUBECONFIG' => '/dev/null'}, 'istioctl', 'kube-inject', '--kubeconfig', '/dev/null', '--revision', values['revision'],
        '--injectConfigFile', "#{directory}/inject.yaml", '--meshConfigFile', "#{directory}/mesh.yaml", '--valuesFile', "#{directory}/values.json", '-f', "#{directory}/pod.yaml"))
      restricted(injected)
      init = injected['spec'].fetch('initContainers')
      check(init.map { |c| c['name'] } == ['istio-validation'], 'privileged networking init must be replaced by CNI validation')
      check(init[0]['args'].include?('--skip-rule-apply') && init[0]['args'].include?('--run-validation'), 'new-node race validation disabled')
      proxy = injected['spec']['containers'].find { |c| c['name'] == 'istio-proxy' }
      check(proxy && [proxy, init[0]].all? { |c| c['image'] == values['global']['proxy']['image'] }, 'actual CNI validation/proxy injection must keep trusted ECR digest')
      puts "PASS: actual #{environment}/#{version} app injection satisfies restricted checks"
    end
  end
  cni = bootstrap.select { |r| r.dig('spec', 'source', 'chart') == 'cni' }
  check(cni.length == 1, 'one singleton CNI Application per cluster required')
  application = cni[0]
  source = application['spec']['source']
  check(source['targetRevision'] == '1.31.0' && source.dig('helm', 'releaseName') == 'istio-cni', 'CNI singleton revision drift')
  chart = lock['delivery']['helmSources'].find { |c| c['chart'] == 'cni' && c['version'] == source['targetRevision'] }
  archive = File.join(cache, 'cni-1.31.0.tgz')
  check(chart['url'] == 'https://blob.istio.io/istio-release/charts/cni-1.31.0.tgz' && Digest::SHA256.file(archive).hexdigest == chart['sha256'], 'official CNI chart integrity mismatch')
  chart_meta = YAML.load(run('helm', 'show', 'chart', archive))
  check(chart_meta['name'] == 'cni' && chart_meta['version'] == '1.31.0', 'wrong CNI archive identity')
  namespace = bootstrap.find { |r| r['kind'] == 'Namespace' && r['metadata']['name'] == 'istio-cni' }
  check(namespace.dig('metadata', 'labels', 'pod-security.kubernetes.io/enforce') == 'privileged', 'CNI infrastructure namespace must admit elevated node agent')
  governance = YAML.load_stream(run('kubectl', 'kustomize', "platform/security/#{environment}")).compact
  app_namespace = governance.find { |r| r['kind'] == 'Namespace' && r['metadata']['name'] == "app-#{environment}" }
  check(app_namespace.dig('metadata', 'labels', 'pod-security.kubernetes.io/enforce') == 'restricted', 'application PSA weakened')
  project = bootstrap.find { |r| r['kind'] == 'AppProject' && r['metadata']['name'] == application['spec']['project'] }
  check(project.dig('spec', 'destinations').map { |d| d['namespace'] } == ['istio-cni'], 'CNI controller project can write application namespaces')
  base = bootstrap.find { |r| r.dig('spec', 'source', 'chart') == 'base' }
  controls = bootstrap.select { |r| r.dig('spec', 'source', 'chart') == 'istiod' }
  wave = ->(r) { r.dig('metadata', 'annotations', 'argocd.argoproj.io/sync-wave').to_i }
  check(wave.call(project) < wave.call(namespace) && wave.call(namespace) < wave.call(base) && wave.call(base) < wave.call(application) && controls.all? { |r| wave.call(application) < wave.call(r) }, 'CNI prerequisite declaration order invalid')
  check(!application.dig('spec', 'syncPolicy', 'automated') && application.dig('metadata', 'annotations', 'argocd.argoproj.io/sync-options') == 'Prune=confirm', 'CNI upgrade/prune must remain operator controlled')
  Dir.mktmpdir('cni-chart-') do |directory|
    values_path = "#{directory}/values.yaml"
    File.write(values_path, YAML.dump(source['helm']['valuesObject']))
    rendered = YAML.load_stream(run('helm', 'template', 'istio-cni', archive, '--namespace', 'istio-cni', '-f', values_path)).compact
    daemonsets = rendered.select { |r| r['kind'] == 'DaemonSet' }
    check(daemonsets.size == 1 && daemonsets[0]['metadata']['name'] == 'istio-cni-node', 'chart must render one revision-independent CNI DaemonSet')
    daemonset = daemonsets[0]
    spec = daemonset.dig('spec', 'template', 'spec')
    check(spec['nodeSelector'] == {'kubernetes.io/os' => 'linux'} && !spec['affinity'], 'CNI must cover all Linux worker architectures/pools')
    check(%w[NoSchedule NoExecute].all? { |effect| spec['tolerations'].any? { |t| t['effect'] == effect && t['operator'] == 'Exists' && !t['key'] } }, 'CNI cannot cover tainted worker pools')
    check(spec['priorityClassName'] == 'system-node-critical', 'node networking priority missing')
    image = lock['delivery']['platformImages']['istioCni']
    check(spec['containers'].map { |c| c['image'] } == [image['upstreamReference']] && image['upstreamReference'].end_with?('@' + image['indexDigest']), 'CNI image must use verified upstream index digest')
    check(image['architectureDigests'].keys.sort == ['linux/amd64', 'linux/arm64'], 'CNI image architecture support incomplete')
    check(daemonset.dig('spec', 'updateStrategy', 'rollingUpdate', 'maxUnavailable') == 1, 'unbounded CNI rolling outage')
    config = rendered.find { |r| r['kind'] == 'ConfigMap' }['data']
    check(config['CHAINED_CNI_PLUGIN'] == 'true' && config['ISTIO_OWNED_CNI_CONFIG'] == 'false', 'CNI must chain behind AWS VPC CNI')
    check(config['AMBIENT_ENABLED'] == 'false' && !spec['hostNetwork'], 'ambient/ztunnel configuration is out of scope')
    check(config.values_at('REPAIR_ENABLED', 'REPAIR_REPAIR_PODS', 'REPAIR_DELETE_PODS', 'REPAIR_LABEL_PODS') == %w[true true false false], 'new-node repair must not delete/label workloads')
    check(config['EXCLUDE_NAMESPACES'].split(',').sort == %w[istio-cni istio-system kube-system], 'infrastructure namespace exclusions invalid')
    rendered.each do |resource|
      group = resource['apiVersion'].include?('/') ? resource['apiVersion'].split('/')[0] : ''
      allow = project['spec'][resource.dig('metadata', 'namespace') ? 'namespaceResourceWhitelist' : 'clusterResourceWhitelist']
      check(allow.include?({'group' => group, 'kind' => resource['kind']}), "CNI AppProject rejects rendered #{resource['kind']}")
    end
  end
end
puts 'STATIC_VERIFIED: CNI singleton/chart/PSA/injection contract; no node networking or admission runtime executed'
