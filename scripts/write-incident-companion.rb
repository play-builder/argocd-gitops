#!/usr/bin/env ruby
require 'json'
require 'digest'
source,incident,dr=ARGV
abort 'capture and incident/DR paths required' unless source && incident && dr
abort 'incident binding rejected' unless system('ruby',File.join(__dir__,'verify-incident-binding.rb'),incident,dr,source)
target="#{source}.platform.json"
record={'schemaVersion'=>'platform.runtime-capture/v1','evidenceGrade'=>'CLOUD_RUNTIME','sourceSha256'=>"sha256:#{Digest::SHA256.file(source).hexdigest}",'incident'=>JSON.parse(File.read(incident)),'drMetadata'=>File.read(dr)}
File.open(target,File::WRONLY|File::CREAT|File::EXCL,0600){|f|f.write(JSON.pretty_generate(record)+"\n")}
