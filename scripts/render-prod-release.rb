#!/usr/bin/env ruby
# Render the exact supported ApplicationSet source; fail closed on unknown overrides.
require 'yaml'
require 'json'
require 'open3'

begin
  root = File.realpath(ARGV.fetch(0, File.expand_path('..', __dir__)))
  read_path = lambda do |relative|
    path = File.realpath(File.join(root, relative))
    raise "input escapes repository: #{relative}" unless path.start_with?(root + '/') && File.file?(path)
    path
  end
  appset = YAML.load_file(read_path.call('argocd/bootstrap/prod/mini-commerce.yaml'))
  raise 'expected the canonical production ApplicationSet' unless appset['kind'] == 'ApplicationSet' && appset.dig('metadata', 'name') == 'mini-commerce-prod'
  raise 'templatePatch is not an approved production source interface' if appset.fetch('spec').key?('templatePatch')
  raise 'production source requires the committed Go template mode' unless appset.dig('spec', 'goTemplate') == true
  generators = appset.dig('spec', 'generators')
  raise 'review renderer before changing the production generator' unless generators&.length == 1 && generators[0].keys == ['list']
  elements = generators[0].dig('list', 'elements')
  raise 'exactly one production environment is required' unless elements&.length == 1 && elements[0]['environment'] == 'prod'
  element = elements.first
  spec = appset.dig('spec', 'template', 'spec')
  source = spec.fetch('source')
  raise 'unreviewed production source overrides' unless (source.keys - %w[repoURL targetRevision path helm]).empty?
  raise 'production source must remain the local mini-commerce chart on main' unless source['path'] == 'charts/mini-commerce' && source['targetRevision'] == 'main' && !spec.key?('sources')
  raise 'Prod source must use the verified GitOps origin' unless ARGV[1] == '--base' || source['repoURL'] == 'https://github.com/play-builder/argocd-gitops.git'
  helm = source.fetch('helm')
  # Deliberately support the committed values-file interface only. Inline/parameter
  # overrides hide release identity from review; use an explicit values file.
  raise 'use reviewed valueFiles; Helm parameters/inline values are not supported' unless (helm.keys - %w[releaseName valueFiles]).empty?
  raise 'canonical releaseName must be mini-commerce' unless helm['releaseName'] == 'mini-commerce'
  files = helm.fetch('valueFiles').map do |pattern|
    resolved = pattern.gsub(/\{\{\s*\.([A-Za-z][A-Za-z0-9]*)\s*\}\}/) { element.fetch(Regexp.last_match(1)) }
    raise 'unsupported valueFiles template' if resolved.include?('{{')
    read_path.call(File.join(source['path'], resolved))
  end
  raise 'production values must begin with envs/prod/values.yaml' unless files.first == read_path.call('envs/prod/values.yaml')
  args = ['helm', 'template', 'mini-commerce', read_path.call('charts/mini-commerce/Chart.yaml').sub(%r{/Chart.yaml\z}, ''), '--namespace', 'app-prod']
  files.each { |file| args.concat(['--values', file]) }
  manifest, stderr, status = Open3.capture3(*args)
  raise "production render failed: #{stderr}" unless status.success?
  documents = YAML.load_stream(manifest).compact
  cleanup = files.reduce(false) do |enabled, file|
    configured = YAML.load_file(file).dig('platformCleanup', 'workloadsDisabled')
    configured.nil? ? enabled : configured == true
  end
  workloads = documents.select { |doc| %w[Deployment Rollout].include?(doc['kind']) }
  if cleanup && workloads.empty?
    puts '[]'
    exit 0
  end
  raise 'exactly one canonical production Rollout is required' unless workloads.length == 1 && workloads[0]['kind'] == 'Rollout' && workloads[0].dig('metadata', 'name') == 'mini-commerce' && workloads[0].dig('metadata', 'namespace') == 'app-prod'
  images = documents.map do |doc|
    next unless %w[Deployment Rollout Job].include?(doc['kind'])
    pod = doc.dig('spec', 'template', 'spec') || {}
    %w[initContainers containers].flat_map do |field|
      (pod[field] || []).map { |container| [doc['kind'], doc.dig('metadata', 'name'), field, container.fetch('name'), container.fetch('image')] }
    end
  end.compact.flatten(1).sort
  puts JSON.generate(images)
rescue StandardError => e
  warn "FAIL: #{e.message}"
  exit 1
end
