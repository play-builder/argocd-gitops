#!/usr/bin/env ruby
require 'open3'
Dir.chdir(File.expand_path('..', __dir__))
output, status = Open3.capture2e('ruby', 'scripts/validate-rendered-manifests.rb', '--negative')
abort output unless status.success?
%w[StatefulSet VolumeSnapshot VolumeSnapshotContent PodChaos NetworkChaos].each do |kind|
  abort "FAIL: missing strict operation schema coverage #{kind}" unless output.include?("PASS: operation schema #{kind}")
end
puts output
