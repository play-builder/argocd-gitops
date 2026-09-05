#!/usr/bin/env ruby
require 'open3'
require 'tmpdir'
require 'yaml'
require 'digest'
Dir.chdir(File.expand_path('..', __dir__))
Dir.mktmpdir('gitops-package-') do |destination|
  output, status = Open3.capture2e('bash', 'scripts/package-chart.sh', destination)
  abort output unless status.success?
  %w[mini-commerce mini-commerce-db-dev mini-commerce-recovery].each do |chart|
    metadata = YAML.load_file("charts/#{chart}/Chart.yaml")
    archive = File.join(destination, "#{chart}-#{metadata.fetch('version')}.tgz")
    abort "FAIL: missing package #{chart}" unless File.file?(archive)
    checksum = File.read("#{archive}.sha256").split.first
    abort 'FAIL: package checksum mismatch' unless checksum == Digest::SHA256.file(archive).hexdigest
    rendered, result = Open3.capture2e('helm', 'show', 'chart', archive)
    abort 'FAIL: archive identity mismatch' unless result.success? && YAML.load(rendered)['name'] == chart
  end
end
puts 'STATIC_VERIFIED: three Helm packages and checksums; no registry publishing'
