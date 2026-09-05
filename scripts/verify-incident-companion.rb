#!/usr/bin/env ruby
require 'json'
require 'digest'
require 'tempfile'
require 'open3'
begin
 source=ARGV.fetch(0)
 path="#{source}.platform.json"
 [source,path].each do |file|
  raise 'regular non-symlink evidence required' unless File.file?(file) && !File.symlink?(file) && File.realpath(file)==File.expand_path(file)
 end
 record=JSON.parse(File.read(path))
 raise 'capture companion fields mismatch' unless record.keys.sort==%w[drMetadata evidenceGrade incident schemaVersion sourceSha256]
 raise 'runtime companion required' unless record['schemaVersion']=='platform.runtime-capture/v1' && record['evidenceGrade']=='CLOUD_RUNTIME'
 raise 'source checksum mismatch' unless record['sourceSha256']=="sha256:#{Digest::SHA256.file(source).hexdigest}"
 raise 'raw DR metadata required' unless record['drMetadata'].is_a?(String)
 Tempfile.create(['incident','.json']) do |incident|
  Tempfile.create(['dr','.json']) do |dr|
   incident.write(JSON.generate(record.fetch('incident')));incident.flush
   dr.write(record.fetch('drMetadata'));dr.flush
   output,status=Open3.capture2e('ruby',File.join(__dir__,'verify-incident-binding.rb'),incident.path,dr.path,source)
   raise 'incident/DR/source binding rejected' unless status.success?
  end
 end
 puts 'STATIC_VERIFIED: exact source bytes and incident/DR companion accepted; no runtime execution'
rescue StandardError => error
 warn "FAIL: #{error.message}";exit 1
end
