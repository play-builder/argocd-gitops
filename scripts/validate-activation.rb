#!/usr/bin/env ruby
# Read-only configuration gate. It never applies resources or invents AWS inputs.
require 'yaml'
require 'open3'
require 'tmpdir'

begin
  environment = ARGV.fetch(0)
  raise 'Usage: ruby scripts/validate-activation.rb dev|prod' unless %w[dev prod].include?(environment) && ARGV.length == 1
  Dir.chdir(File.expand_path('..', __dir__))
  failures = []
  run = lambda do |*args|
    output, error, status = Open3.capture3(*args)
    raise "#{args.first} failed: #{error}" unless status.success?
    output
  end
  inspect_values = lambda do |value, path|
    case value
    when Hash
      value.each { |key, item| inspect_values.call(item, "#{path}.#{key}") }
    when Array
      value.each_with_index { |item, index| inspect_values.call(item, "#{path}[#{index}]") }
    when String
      if value.match?(/REPLACE_(?:ME|FROM|WITH)|(?:example\.(?:com|invalid|test))|sha256:0{64}/)
        failures << "#{path}: unresolved deployment input"
      end
    end
  end
  %W[argocd/bootstrap/#{environment} platform/istio/overlays/#{environment} platform/security/#{environment} platform/security/sigstore/overlays/#{environment}].each do |path|
    YAML.load_stream(run.call('kubectl', 'kustomize', path)).compact.each do |doc|
      inspect_values.call(doc, "#{path}/#{doc['kind']}/#{doc.dig('metadata', 'name')}")
    end
  end
  appset = YAML.load_file("argocd/bootstrap/#{environment}/mini-commerce.yaml")
  raise 'templatePatch requires an explicit source review' if appset.fetch('spec').key?('templatePatch')
  generators = appset.dig('spec', 'generators')
  raise 'activation requires one explicit environment generator' unless generators.length == 1 && generators[0].keys == ['list'] && generators[0].dig('list', 'elements').length == 1
  source = appset.dig('spec', 'template', 'spec', 'source')
  raise 'unreviewed application source overrides' unless (source.keys - %w[repoURL targetRevision path helm]).empty?
  raise 'application must use the verified GitOps origin' unless source['repoURL'] == 'https://github.com/play-builder/argocd-gitops.git'
  raise 'application chart path changed; review activation gate' unless source['path'] == 'charts/mini-commerce' && source['targetRevision'] == 'main'
  raise 'activation requires explicit values-file configuration' unless (source.fetch('helm').keys - %w[releaseName valueFiles]).empty?
  element = appset.dig('spec', 'generators', 0, 'list', 'elements', 0)
  raise 'unexpected environment generator' unless element['environment'] == environment
  args = ['helm', 'template', 'mini-commerce', 'charts/mini-commerce']
  source.dig('helm', 'valueFiles').each do |pattern|
    relative = pattern.gsub(/\{\{\s*\.([A-Za-z][A-Za-z0-9]*)\s*\}\}/) { element.fetch(Regexp.last_match(1)) }
    file = File.realpath(File.join(source['path'], relative))
    raise 'values file escaped repository' unless file.start_with?(Dir.pwd + '/')
    args.concat(['--values', file])
  end
  documents = YAML.load_stream(run.call(*args)).compact
  documents.each { |doc| inspect_values.call(doc, "rendered/#{doc['kind']}/#{doc.dig('metadata', 'name')}") }
  workload = documents.find { |doc| %w[Deployment Rollout].include?(doc['kind']) }
  raise 'activation cannot use a cleanup profile' unless workload
  container = workload.dig('spec', 'template', 'spec', 'containers').find { |item| item['name'] == 'mini-commerce' }
  images = documents.select { |doc| %w[Deployment Rollout Job].include?(doc['kind']) }.flat_map { |doc| doc.dig('spec', 'template', 'spec', 'containers') || [] }
  images.each do |item|
    failures << 'app/migration image: canonical immutable Network ECR identity required' unless item['image'].to_s.match?(/\A[0-9]{12}\.dkr\.ecr\.(ap-northeast-2|us-east-1)\.amazonaws\.com\/[a-z0-9]+([._\/-][a-z0-9]+)*@sha256:[0-9a-f]{64}\z/)
  end
  if environment == 'prod'
    failures << 'envs/prod/stateful-values.yaml: enable initialized RDS clients before production activation' unless container['env'].any? { |item| item['name'] == 'DATABASE_ENABLED' && item['value'] == 'true' }
    policy = documents.find { |doc| doc['kind'] == 'NetworkPolicy' && doc.dig('metadata', 'name') == 'mini-commerce-database-egress' }
    failures << 'envs/prod/values.yaml: explicit private RDS egress CIDRs required' unless (policy&.dig('spec', 'egress') || []).any? { |rule| (rule['to'] || []).any? { |peer| peer.key?('ipBlock') } }
  end
  virtual_service = documents.find { |doc| doc['kind'] == 'VirtualService' }
  hostname = virtual_service&.dig('spec', 'hosts', 0)
  mesh = YAML.load_stream(run.call('kubectl', 'kustomize', "platform/istio/overlays/#{environment}")).compact
  mesh.select { |doc| doc['kind'] == 'HTTPRoute' }.each do |route|
    failures << 'mesh HTTPRoute hostname differs from application VirtualService' unless route.dig('spec', 'hostnames') == [hostname]
  end
  if File.read('.github/CODEOWNERS').include?('@REPLACE_ME')
    failures << '.github/CODEOWNERS: configure an actual user/team with repository write access'
  end
  unless failures.empty?
    warn failures.uniq.map { |failure| "BLOCKED: #{failure}" }.join("\n")
    exit 1
  end
  Dir.mktmpdir('mesh-activation-') do |tmp|
    path = File.join(tmp, 'mesh.yaml')
    File.write(path, mesh.map { |doc| YAML.dump(doc) }.join)
    run.call('ruby', 'scripts/validate-mesh-inputs.rb', path)
  end
  puts "STATIC_VERIFIED: #{environment} activation configuration; IAM, admission, routing, data recovery and runtime SLO are still unverified"
rescue StandardError => e
  warn "BLOCKED: #{e.message}"
  exit 1
end
