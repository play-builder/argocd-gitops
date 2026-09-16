#!/usr/bin/env ruby
require_relative 'lib/platform_mirror'
begin
  handoff = JSON.parse(File.read(ARGV.fetch(0))); env = ARGV.fetch(1)
  raise 'environment must be dev or prod' unless %w[dev prod].include?(env)
  repository = PlatformMirror.repository(handoff)
  apps = YAML.load_stream(File.read(File.join(PlatformMirror::ROOT, "argocd/bootstrap/#{env}/istio-platform.yaml"))).compact
  apps.select { |a| a.dig('spec', 'source', 'chart') == 'istiod' }.each do |a|
    values = a['spec']['source']['helm']['valuesObject']
    release = PlatformMirror.releases.find { |r| r['version'] == a['spec']['source']['targetRevision'] }
    %w[proxy proxy_init].each do |key|
      expected = "#{PlatformMirror::TOKEN}@#{release['indexDigest']}"
      raise 'injector and approved image lock differ' unless values.dig('global', key, 'image') == expected
      values['global'][key]['image'] = "#{repository}@#{release['indexDigest']}"
    end
    puts YAML.dump(a)
  end
  puts YAML.dump(PlatformMirror.policy(repository, env))
rescue StandardError => e
  warn "FAIL: #{e.message}"; exit 1
end
