#!/usr/bin/env ruby
require 'yaml'
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'rbconfig'
Dir.chdir(File.expand_path('..',__dir__))
steps=YAML.load_file('.github/workflows/validate.yml').dig('jobs','validate','steps')
step=steps.find{|s|s['name']=='Install exact yq'}

Dir.mktmpdir('ci-host-tools-') do |dir|
 bin=File.join(dir,'bin');FileUtils.mkdir_p(bin)
 host_bin=File.join(dir,'host-bin');FileUtils.mkdir_p(host_bin)
 File.write(File.join(host_bin,'rg'),"#!/bin/sh\nexit 0\n")
 File.chmod(0755,File.join(host_bin,'rg'))
 %w[cat chmod grep uname].each do |name|
   source=ENV.fetch('PATH').split(File::PATH_SEPARATOR).map{|entry|File.join(entry,name)}.find{|path|File.file?(path)&&File.executable?(path)}
   raise "required fixture tool is unavailable: #{name}" unless source
   FileUtils.ln_s(source,File.join(bin,name))
 end
 FileUtils.ln_s(RbConfig.ruby,File.join(bin,'ruby'))
 File.write(File.join(bin,'sudo'),"#!/bin/sh\nexec \"$@\"\n")
 File.write(File.join(bin,'apt-get'),<<~'SH')
   #!/bin/sh
   set -eu
   case " ${*} " in
     *" update "*)
       : > "${RUNNER_TEMP}/apt-updated"
       ;;
     *" install "*)
       test -f "${RUNNER_TEMP}/apt-updated"
       case " ${*} " in
         *" ripgrep "*)
           cat > "${RUNNER_TEMP}/bin/rg" <<'RG'
   #!/bin/sh
   exec grep "$@"
   RG
           chmod 0755 "${RUNNER_TEMP}/bin/rg"
           ;;
       esac
       ;;
   esac
 SH
 File.write(File.join(bin,'go'),"#!/usr/bin/env ruby\nrequire 'fileutils'\nFileUtils.mkdir_p(ENV.fetch('GOBIN'))\np=File.join(ENV.fetch('GOBIN'),'yq')\nFile.write(p, \"#!/bin/sh\\necho 'yq version v4.53.6'\\n\")\nFile.chmod(0755,p)\n")
 %w[sudo apt-get go].each{|name|File.chmod(0755,File.join(bin,name))}

 gate_index=steps.index{|candidate|candidate['name']=='Assert compatibility pins'} or
   raise 'compatibility gate is missing'
 host_env={'PATH'=>host_bin}
 raise 'host rg experiment is invalid' unless system(host_env,'/bin/sh','-c','command -v rg >/dev/null 2>&1')
 env={'PATH'=>bin,'RUNNER_TEMP'=>dir,'GITHUB_PATH'=>File.join(dir,'github-path')}
 raise 'clean runner unexpectedly provides rg' if system(env,'/bin/sh','-c','command -v rg >/dev/null 2>&1')
 steps.first(gate_index).map{|candidate|candidate['run']}.compact.each do |run|
   output,status=Open3.capture2e(env,'/bin/bash','-e','-o','pipefail','-c',run)
   raise "pre-gate workflow step failed: #{output}" unless status.success?
 end
 fixture=File.join(dir,'fixture.txt');File.write(fixture,"workflow prerequisite ready\n")
 output,status=Open3.capture2e(env,'/bin/sh','-c','rg "workflow prerequisite" "$1"','sh',fixture)
 raise "pre-gate workflow did not install a working rg: #{output}" unless status.success? && output.include?('workflow prerequisite ready')
end
puts 'STATIC_VERIFIED: CI installs a working rg before the first validation gate'

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
