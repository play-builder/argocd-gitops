require 'yaml'
require 'open3'
Dir.chdir(File.expand_path('..',__dir__))
def check(ok,msg);raise msg unless ok;end
def render(env,*extra)
 out,s=Open3.capture2e('helm','template','mini-commerce','charts/mini-commerce','-f',"envs/#{env}/values.yaml",'--set-string','image.repository=example.invalid/mini-commerce','--set-string',"image.digest=sha256:#{'a'*64}",'--set-string','database.migrationImage.repository=example.invalid/mini-commerce','--set-string',"database.migrationImage.digest=sha256:#{'a'*64}",*extra)
 raise out unless s.success?
 YAML.load_stream(out).compact
end
%w[dev prod].each do |env|
 docs=render(env,'--set','database.enabled=true')
 check(docs.none?{|d|%w[StatefulSet PodChaos NetworkChaos VolumeSnapshot PersistentVolumeClaim].include?(d['kind'])},'main chart still owns data or chaos')
 work=docs.find{|d|%w[Deployment Rollout].include?(d['kind'])}
 pod=work.dig('spec','template')
 c=pod['spec']['containers'][0]
 check((c['env'].map{|v|v['name']}&%w[FAILURE_RATE LATENCY_MS]).empty?,'main workload still carries fault injection')
 check(pod.dig('metadata','annotations','prometheus.istio.io/merge-metrics')=='false','metrics incorrectly merged')
 services=docs.select{|d|d['kind']=='Service'}
 check(services.all?{|s|s['spec']['ports']==[{'name'=>'http','port'=>3000,'targetPort'=>'public','protocol'=>'TCP'}]},'public service contract changed')
 check(c.dig('livenessProbe','httpGet','port')=='management' && c.dig('readinessProbe','httpGet','port')=='management','probes expose public path')
 migration=docs.find{|d|d['kind']=='Job'}
 mc=migration.dig('spec','template','spec','containers',0)
 runtime_db=c['env'].find{|v|v['name']=='DB_PASSWORD'}.dig('valueFrom','secretKeyRef','name')
 migration_db=mc['env'].find{|v|v['name']=='DB_PASSWORD'}.dig('valueFrom','secretKeyRef','name')
 check(runtime_db=='mini-commerce-database' && migration_db=='mini-commerce-migration','DML and DDL credential separation missing')
 secrets=docs.select{|d|d['kind']=='ExternalSecret'}
 check(secrets.find{|d|d['metadata']['name']==migration_db}.dig('spec','secretStoreRef','name')=='mini-commerce-migration-secrets','migration must use DDL-only reader')
 check(secrets.find{|d|d['metadata']['name']==runtime_db}.dig('spec','secretStoreRef','name')=='mini-commerce-secrets','runtime reader missing')
 [c,mc].each do |container|
  check(%w[requests limits].all?{|k|%w[cpu memory].all?{|v|container.dig('resources',k,v)}},'missing container resources')
  next if env=='dev'
  check(container['env'].any?{|e|e=={'name'=>'DB_SSL','value'=>'true'}},'production TLS disabled')
  check(container['env'].any?{|e|e['name']=='NODE_EXTRA_CA_CERTS' && e['value']=='/etc/rds-ca/global-bundle.pem'},'RDS CA trust missing')
  check(container['env'].any?{|e|e=={'name'=>'APP_ENV','value'=>'production'}},'production runtime validation disabled')
 end
 next if env=='dev'
 check(work.dig('spec','replicas')>=3,'initial Rollout replicas must satisfy availability before HPA starts')
 check(pod.dig('spec','topologySpreadConstraints').map{|s|s['topologyKey']}.sort==%w[kubernetes.io/hostname topology.kubernetes.io/zone],'zone and node spread missing')
 check(pod['spec']['topologySpreadConstraints'].all?{|s|s['whenUnsatisfiable']=='DoNotSchedule'},'production spread is best effort')
 check(docs.find{|d|d['kind']=='PodDisruptionBudget'}.dig('spec','minAvailable')==2,'production availability below 2')
 check(docs.find{|d|d['kind']=='HorizontalPodAutoscaler'}.dig('spec','minReplicas')>=3,'production replicas below 3')
end
puts 'STATIC_VERIFIED: main app data isolation, TLS and resource governance'
%w[0.0.0.0/0 8.8.8.8/32 10.1.2.3/16 172.16.0.0/11].each do |cidr|
 out,s=Open3.capture2e('helm','template','mini-commerce','charts/mini-commerce','-f','envs/prod/values.yaml','--set','database.enabled=true','--set-string',"database.allowedCidrs[0]=#{cidr}")
 check(!s.success? && out.include?('database.allowedCidrs'),'database egress permits unbounded/nonprivate CIDRs')
end
