require 'yaml'
require 'open3'
Dir.chdir(File.expand_path('..',__dir__))
def check(ok, message); raise message unless ok; end
def render(env,*args)
 Open3.capture2e('helm','template','mini-commerce','charts/mini-commerce','-f',"envs/#{env}/values.yaml",
 '--set-string','image.repository=example.invalid/mini-commerce','--set-string',"image.digest=sha256:#{'a'*64}",
 '--set-string','database.migrationImage.repository=example.invalid/mini-commerce','--set-string',"database.migrationImage.digest=sha256:#{'a'*64}",*args)
end
mode=ARGV.fetch(0,'all')
if %w[all migration].include?(mode)
 app=YAML.load_file('argocd/bootstrap/prod/mini-commerce.yaml')
 check(app.dig('spec','generators',0,'list','elements',0,'phaseValuesFile')=='envs/prod/migration-expand-values.yaml','Prod current V2-prime app requires the expand baseline')
 check(app.dig('spec','template','spec','source','helm','valueFiles').include?('../../{{ .phaseValuesFile }}'),'Prod phase overlay disconnected')
 %w[dev prod].each do |env|
  appset=YAML.load_file("argocd/bootstrap/#{env}/mini-commerce.yaml")
  element=appset.dig('spec','generators',0,'list','elements',0)
  args=appset.dig('spec','template','spec','source','helm','valueFiles').flat_map do |value|
   key=value.match(/\{\{ \.(\w+) \}\}/)[1]
   ['-f',element.fetch(key)]
  end
  output,status=render(env,*args,'--set','database.enabled=true')
  check(status.success?,output)
  job=YAML.load_stream(output).compact.find{|d|d['kind']=='Job'}
  check(job.dig('spec','template','spec','containers',0,'args')==['--target','002_expand_product_display_name'],"#{env} current V2-prime must not activate on initial-only schema")
 end
 %w[initial expand contract finalize].zip(%w[001_initial_commerce 002_expand_product_display_name 003_contract_product_name 003_contract_product_name]).each do |phase,target|
  output,status=render('prod','--set','database.enabled=true','-f',"envs/prod/migration-#{phase}-values.yaml")
  check(status.success?,output)
  docs=YAML.load_stream(output).compact
  check(docs.none?{|d|d['kind']=='StatefulSet'},'Prod RDS must not regain StatefulSet ownership')
  job=docs.find{|d|d['kind']=='Job'};pod=job.dig('spec','template','spec');container=pod['containers'].find{|c|c['name']=='migrate'}
  check(container['args']==['--target',target],"#{phase} migration target mismatch")
  check(pod.dig('securityContext','runAsUser')==10001 && pod.dig('securityContext','fsGroup')==10001,'migration writable volume identity differs from application image')
  check(container['env'].find{|e|e['name']=='DB_PASSWORD'}.dig('valueFrom','secretKeyRef','name')=='mini-commerce-migration','DDL credential separation lost')
  evidence=container['env'].select{|e|e['name'].start_with?('ROLLBACK_')}
  check((!evidence.empty?)==(phase=='contract'),"#{phase} has wrong rollback evidence lifecycle")
  check((pod['volumes']||[]).any?{|v|v['name']=='rollback-candidates'}==(phase=='contract'),'rollback volume remains during finalize')
 end
 %w[contract-without-evidence finalize-with-evidence expand-wrong-target unsupported-phase paused-unsupported-phase missing-target].each do |suffix|
  output,status=render('prod','--set','database.enabled=true','-f',"tests/fixtures/values/migration-#{suffix}.yaml")
  check(!status.success? && output.include?('migration'),"invalid migration #{suffix} accepted")
 end
end
if %w[all telemetry].include?(mode)
 %w[dev prod].each do |env|
  output,status=render(env);check(status.success?,output)
  docs=YAML.load_stream(output).compact
  check(docs.none?{|d|d.dig('data','OTEL_EXPORTER_OTLP_ENDPOINT')},'traces enabled without actual X-Ray platform handoff')
  check(docs.any?{|d|d['kind']=='Telemetry'},'disabled traces must not disable Istio metric hash producer')
 end
 output,status=render('dev','-f','tests/fixtures/values/telemetry-platform-ready.yaml');check(status.success?,output)
 check(YAML.load_stream(output).compact.any?{|d|d.dig('data','OTEL_EXPORTER_OTLP_PROTOCOL')=='http/protobuf'},'valid trace handoff missing')
 %w[wrong-path wrong-protocol xray-inactive].each do |suffix|
  output,status=render('dev','-f',"tests/fixtures/values/telemetry-#{suffix}.yaml")
  check(!status.success? && output.include?('telemetry'),"invalid telemetry #{suffix} accepted")
 end
end
if %w[all project-scope].include?(mode)
 %w[dev prod].each do |env|
  output,status=Open3.capture2e('kubectl','kustomize',"argocd/bootstrap/#{env}");check(status.success?,output)
  projects=YAML.load_stream(output).compact.select{|d|d['kind']=='AppProject'}.to_h{|d|[d.dig('metadata','name'),d['spec']]}
  manifest,status=render(env,'--set','database.enabled=true','-f',"envs/#{env}/pre-cutover-ownership-values.yaml");check(status.success?,manifest)
  project=projects.fetch("platform-#{env}")
  YAML.load_stream(manifest).compact.each do |doc|
   group=doc['apiVersion'].include?('/') ? doc['apiVersion'].split('/')[0] : ''
   scope=doc.dig('metadata','namespace') ? 'namespaceResourceWhitelist' : 'clusterResourceWhitelist'
   check(project.fetch(scope,[]).include?({'group'=>group,'kind'=>doc['kind']}),"#{env} project missing #{scope} #{group}/#{doc['kind']}")
  end
  legacy=projects.fetch("course-#{env}")
  check(!legacy['clusterResourceWhitelist'].include?({'group'=>'gateway.k8s.aws','kind'=>'LoadBalancerConfiguration'}),'LoadBalancerConfiguration wrongly cluster-scoped')
  check(legacy['namespaceResourceWhitelist'].include?({'group'=>'gateway.k8s.aws','kind'=>'LoadBalancerConfiguration'}),'legacy namespaced LoadBalancerConfiguration permission lost')
 end
end
puts "STATIC_VERIFIED: main RC #{mode} semantics on enterprise owners"
