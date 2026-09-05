require 'yaml'
require 'open3'
Dir.chdir(File.expand_path('..',__dir__))
%w[dev prod].each do |env|
 out,s=Open3.capture2e('kubectl','kustomize',"platform/istio/overlays/#{env}")
 raise out unless s.success?
 docs=YAML.load_stream(out)
 peer=docs.find{|d|d['kind']=='PeerAuthentication' && d['metadata']['name']=='mini-commerce-management'}
 raise 'management mTLS exception missing' unless peer.dig('spec','portLevelMtls')=={3001=>{'mode'=>'DISABLE'}} || peer.dig('spec','portLevelMtls')=={'3001'=>{'mode'=>'DISABLE'}}
 np=docs.find{|d|d['kind']=='NetworkPolicy'}
 mgmt=np['spec']['ingress'].find{|r|r['ports'].any?{|p|p['port']==3001}}
 raise 'management not collector-only' unless mgmt['from']==[{'namespaceSelector'=>{'matchLabels'=>{'kubernetes.io/metadata.name'=>'opentelemetry-operator-system'}},'podSelector'=>{'matchLabels'=>{'app.kubernetes.io/name'=>'adot-collector-prometheus-collector'}}}]
 raise 'proxy scrape missing' unless mgmt['ports'].any?{|p|p['port']==15090}
 docs.select{|d|d['kind']=='AuthorizationPolicy'}.flat_map{|d|d.dig('spec','rules')||[]}.each do |r|
   next unless (r['to']||[]).any?{|to|to.dig('operation','ports')==['3001']}
   raise 'plaintext scraper requires exact metrics path without fictitious mTLS identity' unless r=={'to'=>[{'operation'=>{'ports'=>['3001'],'paths'=>['/metrics']}}]}
 end
end
puts 'STATIC_VERIFIED: collector-only split scrapes and exact management mTLS exception'
