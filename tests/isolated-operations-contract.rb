require 'yaml'
require 'open3'
Dir.chdir(File.expand_path('..',__dir__))
def check(ok,msg); raise msg unless ok; end
def render(chart,*args)
 out,s=Open3.capture2e('helm','template','mini-commerce',"charts/#{chart}",*args)
 check(s.success?,out);YAML.load_stream(out).compact
end
check(File.directory?('charts/mini-commerce-db-dev'),'isolated Dev DB chart missing')
db=render('mini-commerce-db-dev')
stateful=db.find{|d|d['kind']=='StatefulSet'}
check(stateful.dig('spec','persistentVolumeClaimRetentionPolicy')=={'whenDeleted'=>'Retain','whenScaled'=>'Retain'},'database PVC retention missing')
check(stateful['metadata']['name']=='mini-commerce-postgresql','database ownership migration must preserve StatefulSet and PVC identity')
check(stateful.dig('spec','volumeClaimTemplates',0,'metadata','name')=='data','data PVC renamed')
check(stateful.dig('spec','template','spec','containers',0,'resources','requests','memory'),'database resources missing')
%w[mini-commerce-db-dev mini-commerce-recovery].each do |chart|
 out,s=Open3.capture2e('helm','template','mini-commerce',"charts/#{chart}",'--set','environment=prod')
 check(!s.success? && out.include?('dev-only'), 'prod operation chart accepted')
end
recovery=render('mini-commerce-recovery','--set-string','snapshotHandle=snap-0123456789abcdef0')
content=recovery.find{|d|d['kind']=='VolumeSnapshotContent'}
check(content.dig('spec','deletionPolicy')=='Retain','snapshot source must be retained')
check(content.dig('spec','source','snapshotHandle')=='snap-0123456789abcdef0','snapshot identity lost')
check(recovery.find{|d|d['kind']=='Job'}.dig('spec','activeDeadlineSeconds')<=300,'unbounded recovery job')
%w[mini-commerce-db-dev mini-commerce-recovery mini-commerce-chaos].each do |name|
 app=YAML.load_file("argocd/bootstrap/dev/#{name}.yaml")
 check(!app.dig('spec','syncPolicy','automated'),'operation must require manual sync')
 check(app.dig('spec','destination','namespace')!='app-prod','operation targets prod')
end
chaos,s=Open3.capture2e('kubectl','kustomize','experiments/chaos/dev')
check(s.success?,chaos)
YAML.load_stream(chaos).compact.each do |d|
 check(d['spec']['duration']=='5m','chaos duration unbounded')
 check(d.dig('spec','selector','namespaces')==['app-dev'],'chaos namespace escape')
 check(d.dig('metadata','labels','operations.mini-commerce.io/cleanup')=='manual-dev','chaos cleanup identity missing')
end
puts 'STATIC_VERIFIED: manual Dev DB, retained snapshots and bounded isolated chaos'
