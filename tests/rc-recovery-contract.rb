require 'yaml'
require 'json'
require 'open3'
require 'tmpdir'
Dir.chdir(File.expand_path('..',__dir__))
def check(ok,message);raise message unless ok;end
Dir.mktmpdir('rc-recovery-') do |tmp|
 generated=File.join(tmp,'values.yaml')
 fixture='tests/fixtures/recovery/snapshot-ready-valid.json'
 out,status=Open3.capture2e('bash','scripts/render-recovery-values.sh','--fixture',fixture,generated,'--now','2026-09-03T01:10:30Z')
 check(status.success?,out)
 values=YAML.load_file(generated)
 check(values['snapshotHandle']=='snap-0123456789abcdef0','validated receipt must target isolated recovery chart')
 output,status=Open3.capture2e('helm','template','mini-commerce','charts/mini-commerce-recovery','-f',generated)
 check(status.success?,output)
 docs=YAML.load_stream(output).compact
 content=docs.find{|d|d['kind']=='VolumeSnapshotContent'}
 check(content.dig('spec','deletionPolicy')=='Retain' && content.dig('spec','source','snapshotHandle')==values['snapshotHandle'],'retained snapshot binding lost')
 job=docs.find{|d|d['kind']=='Job'}
 check(job.dig('spec','template','spec','automountServiceAccountToken')==false,'recovery workload must not borrow IRSA reader identity')
 check(docs.none?{|d|%w[StatefulSet SecretStore ExternalSecret].include?(d['kind'])},'snapshot inspection must not regain managed-DB/reader ownership')
 %w[snapshot-ready-fake-handle snapshot-ready-wrong-class snapshot-ready-normal-reader-role snapshot-ready-volume-handle-mismatch].each do |name|
  File.write(generated,'sentinel')
  _,status=Open3.capture2e('bash','scripts/render-recovery-values.sh','--fixture',"tests/fixtures/recovery/#{name}.json",generated,'--now','2026-09-03T01:10:30Z')
  check(!status.success? && File.read(generated)=='sentinel',"invalid recovery #{name} accepted or replaced output")
 end
 %w[2026-09-03T01:09:59Z 2026-09-03T02:10:00Z].each do |clock|
  _,status=Open3.capture2e('bash','scripts/render-recovery-values.sh','--fixture',fixture,generated,'--now',clock)
  check(!status.success?,'future/expired snapshot accepted')
 end
 %w[A1 A2 A3].each do |phase|
  args=phase=='A1' ? ['-f','envs/dev/snapshot-maintenance-values.yaml'] : phase=='A2' ? ['-f','envs/dev/snapshot-maintenance-values.yaml','--set','database.replicaCount=0'] : ['-f','envs/dev/snapshot-capture-values.yaml']
  output,status=Open3.capture2e('helm','template','mini-commerce','charts/mini-commerce-db-dev',*args)
  check(status.success?,output);docs=YAML.load_stream(output).compact
  check(docs.find{|d|d['kind']=='StatefulSet'}.dig('spec','replicas')==(phase=='A1' ? 1 : 0),"#{phase} Dev DB replica contract lost")
  check(docs.count{|d|d['kind']=='VolumeSnapshot'}==(phase=='A3' ? 1 : 0),"#{phase} snapshot capture owner missing or premature")
 end
end
puts 'STATIC_VERIFIED: RC snapshot receipt, freshness, source-volume binding and separate DB capture owner'
