#!/usr/bin/env ruby
require 'yaml'
require 'json'
require 'tmpdir'
require 'fileutils'
require 'digest'
require 'open3'
require 'rbconfig'

Dir.chdir(File.expand_path('..', __dir__))
lock = YAML.load_file('versions.lock.yaml')
external = lock.fetch('delivery').fetch('helmSources').find { |source| source['chart'] == 'external-secrets' }
raise 'External Secrets chart lock is missing' unless external

# The official Helm index publishes this release asset, not an archive below the
# index host. Exercise the real loader with empty caches so a cached archive
# cannot hide an invalid source URL. Only the external HTTP boundary is doubled.
published_url = 'https://github.com/external-secrets/external-secrets/releases/download/helm-chart-2.10.0/external-secrets-2.10.0.tgz'

Dir.mktmpdir('chart-download-contract-') do |dir|
  bin = File.join(dir, 'bin')
  FileUtils.mkdir_p(bin)
  sources = [external, lock.fetch('delivery').fetch('operationSchemaSources').fetch('chaosMesh')]
  downloads = {}
  sources.each do |source|
    chart = File.join(dir, source.fetch('chart'))
    FileUtils.mkdir_p(chart)
    File.write(File.join(chart, 'Chart.yaml'), YAML.dump({
      'apiVersion' => 'v2', 'name' => source.fetch('chart'), 'version' => source.fetch('version')
    }))
    output, status = Open3.capture2e('helm', 'package', chart, '--destination', dir)
    raise "fixture chart packaging failed: #{output}" unless status.success?
    archive = File.join(dir, "#{source.fetch('chart')}-#{source.fetch('version')}.tgz")
    source['sha256'] = Digest::SHA256.file(archive).hexdigest
    downloads[source['chart'] == 'external-secrets' ? published_url : source.fetch('url')] = archive
  end
  lock['delivery']['helmSources'] = [external]
  lock['delivery']['operationSchemaSources']['snapshotCrds'] = []
  lock_path = File.join(dir, 'versions.json')
  downloads_path = File.join(dir, 'downloads.json')
  File.write(downloads_path, JSON.generate(downloads))
  File.write(File.join(bin, 'curl'), <<~RUBY)
    #!#{RbConfig.ruby}
    require 'json'
    require 'fileutils'
    sources = JSON.parse(File.read(ENV.fetch('FIXTURE_DOWNLOADS')))
    destination = ARGV.index('-o')
    source = destination && sources[ARGV[destination - 1]]
    unless source
      warn 'curl: (22) The requested URL returned error: 404'
      exit 22
    end
    FileUtils.cp(source, ARGV[destination + 1])
  RUBY
  File.chmod(0755, File.join(bin, 'curl'))
  run_loader = lambda do |name|
    File.write(lock_path, JSON.generate(lock))
    cache = File.join(dir, name)
    raise 'test cache must start empty' if File.exist?(cache)
    env = {'VERSION_LOCK' => lock_path, 'CHART_CACHE_DIR' => cache,
           'FIXTURE_DOWNLOADS' => downloads_path, 'PATH' => "#{bin}:#{ENV.fetch('PATH')}"}
    output, status = Open3.capture2e(env, RbConfig.ruby, 'scripts/validate-rendered-manifests.rb', '--locks-only')
    [output, status, cache]
  end

  output, status, cache = run_loader.call('cold-cache')
  raise "cold-cache chart download failed: #{output}" unless status.success?
  archive = File.join(cache, 'external-secrets-2.10.0.tgz')
  raise 'loader did not cache the verified chart' unless File.file?(archive) && Digest::SHA256.file(archive).hexdigest == external['sha256']
  puts 'PASS: cold-cache loader fetches the published External Secrets archive'

  external['url'] = 'https://user:fixture-password@downloads.example.invalid/missing.tgz?token=fixture-query-token#fixture-fragment'
  output, status = run_loader.call('failed-cache')
  raise 'missing chart download was accepted' if status.success?
  raise "download failure lacks asset context: #{output}" unless output.include?('external-secrets-2.10.0.tgz')
  raise "download failure lacks safe source context: #{output}" unless output.include?('https://downloads.example.invalid/missing.tgz')
  %w[fixture-password fixture-query-token fixture-fragment].each do |secret|
    raise 'download failure exposed URL credentials' if output.include?(secret)
  end
  puts 'PASS: failed chart download identifies its asset and source without URL credentials'

  external['url'] = 'https://user:fixture-password@downloads.example.invalid/missing.tgz?token=fixture-query-token#invalid fragment'
  output, status = run_loader.call('malformed-url-cache')
  raise 'malformed chart download was accepted' if status.success?
  %w[fixture-password fixture-query-token].each do |secret|
    raise 'malformed URL failure exposed credentials' if output.include?(secret)
  end
  raise 'malformed URL failure lost asset context' unless output.include?('external-secrets-2.10.0.tgz')
  raise 'malformed URL failure lacks safe placeholder' unless output.include?('[invalid URL]')
  puts 'PASS: malformed download URL preserves asset context without exposing credentials'
end
