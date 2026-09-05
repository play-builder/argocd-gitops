#!/usr/bin/env ruby
require 'yaml'
require 'tmpdir'
require 'fileutils'
require 'open3'
Dir.chdir(File.expand_path('..',__dir__))
step=YAML.load_file('.github/workflows/validate.yml').dig('jobs','validate','steps').find{|s|s['name']=='Install exact yq'}
Dir.mktmpdir('ci-tools-') do |dir|
 bin=File.join(dir,'bin');FileUtils.mkdir_p(bin)
 # GitHub applies GITHUB_PATH only to later steps. Simulate an otherwise clean runner.
 File.write(File.join(bin,'go'),"#!/usr/bin/env ruby\nrequire 'fileutils'\nFileUtils.mkdir_p(ENV.fetch('GOBIN'))\np=File.join(ENV.fetch('GOBIN'),'yq')\nFile.write(p, \"#!/bin/sh\\necho 'yq version v4.53.6'\\n\")\nFile.chmod(0755,p)\n")
 File.chmod(0755,File.join(bin,'go'))
 output,status=Open3.capture2e({'PATH'=>"#{bin}:/usr/bin:/bin",'RUNNER_TEMP'=>dir,'GITHUB_PATH'=>File.join(dir,'github-path')},'/bin/bash','-e','-o','pipefail','-c',step.fetch('run'))
 raise "same-step installed tool unavailable: #{output}" unless status.success?
 raise 'tool path not exported for later steps' unless File.read(File.join(dir,'github-path')).strip==File.join(dir,'yq-bin')
end
puts 'STATIC_VERIFIED: CI executes the installed yq before GITHUB_PATH takes effect'
