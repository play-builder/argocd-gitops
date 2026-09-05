require 'yaml'
require 'open3'
Dir.chdir(File.expand_path('..', __dir__))
def check(ok, message); raise message unless ok; end
%w[dev prod].each do |env|
  rendered, status = Open3.capture2e('kubectl','kustomize',"argocd/bootstrap/#{env}")
  check(status.success?, rendered)
  docs = YAML.load_stream(rendered).compact
  namespaces = docs.select { |r| r['kind']=='Namespace' && r.dig('metadata','name')=="app-#{env}" }
  check(namespaces.length==1, 'root must produce exactly one application Namespace before namespaced stores')
  ns=namespaces.first
  wave=->(r){Integer(r.dig('metadata','annotations','argocd.argoproj.io/sync-wave') || '0')}
  stores=docs.select{|r| %w[ServiceAccount SecretStore].include?(r['kind']) && r.dig('metadata','namespace')=="app-#{env}"}
  check(!stores.empty? && stores.all?{|r|wave.call(ns)<wave.call(r)},'Namespace must precede every root-owned store/reader')
  check(ns.dig('metadata','labels','policy.sigstore.dev/include')=='true' && ns.dig('metadata','labels','pod-security.kubernetes.io/enforce')=='restricted','final security labels must not be bypassed')
  governance=YAML.load_stream(Open3.capture2('kubectl','kustomize',"platform/security/#{env}").first).compact
  check(governance.none?{|r|r['kind']=='Namespace'},'governance must relinquish Namespace in the same commit')
  legacy=docs.find{|r|r['kind']=='ApplicationSet' && r.dig('metadata','name')=="sample-app-#{env}"}
  check(legacy.dig('spec','template','spec','source','helm','parameters').include?({'name'=>'namespace.create','value'=>'false'}),'legacy Helm Namespace producer must be disabled')
  check(!legacy.dig('spec','template','spec','syncPolicy').key?('managedNamespaceMetadata'),'legacy metadata ownership must be relinquished')
  check(!legacy.dig('spec','template','spec','syncPolicy','syncOptions').include?('CreateNamespace=true'),'legacy Namespace creation must be disabled')
end
check(File.file?('scripts/namespace-enforcement-preflight.rb'),'controller/policy readiness preflight missing')
runbook=File.read('docs/runbooks/namespace-bootstrap.md')
%w[non-cascading policy-controller-webhook ClusterImagePolicy full-root-sync].each{|term|check(runbook.include?(term),"missing prerequisite/cutover: #{term}")}
puts 'STATIC_VERIFIED: root-only Namespace ownership and non-circular bootstrap prerequisites'

require_relative '../scripts/lib/namespace-enforcement'
deployment={'metadata'=>{'generation'=>2},'spec'=>{'replicas'=>1},'status'=>{'observedGeneration'=>2,'updatedReplicas'=>1,'readyReplicas'=>1,'availableReplicas'=>1}}
slices={'items'=>[{'endpoints'=>[{'conditions'=>{'ready'=>true},'addresses'=>['10.0.1.5']}]}]}
hook={'name'=>'policy.sigstore.dev','failurePolicy'=>'Fail','clientConfig'=>{'service'=>{'name'=>'webhook','namespace'=>'cosign-system'},'caBundle'=>'test-only-ca'},
 'rules'=>[{'resources'=>['pods']}],'namespaceSelector'=>{'matchExpressions'=>[{'key'=>'policy.sigstore.dev/include','operator'=>'In','values'=>['true']}]}}
hooks=Array.new(4){ {'webhooks'=>[Marshal.load(Marshal.dump(hook))]} }
desired=NamespaceEnforcement::REQUIRED_POLICIES.map{|name|{'metadata'=>{'name'=>name},'spec'=>{'mode'=>'enforce','images'=>[{'glob'=>'example.invalid/*'}]}}}
actual=Marshal.load(Marshal.dump(desired));actual.each{|r|r['metadata']['generation']=3;r['status']={'observedGeneration'=>3,'conditions'=>[{'type'=>'Ready','status'=>'True'}]}}
bundle=[deployment,slices,hooks,desired,actual]
check(NamespaceEnforcement.ready!(*bundle),'valid controller/policy prerequisites rejected')
[->(b){b[0]['status']['observedGeneration']=1},
 ->(b){b[1]['items'][0]['endpoints'][0]['conditions']['ready']=false},
 ->(b){b[2][0]['webhooks'][0]['failurePolicy']='Ignore'},
 ->(b){b[2][0]['webhooks'][0]['clientConfig'].delete('caBundle')},
 ->(b){b[2][0]['webhooks'][0]['rules']=[]},
 ->(b){b[4][0]['status']['observedGeneration']=2},
 ->(b){b[4][0]['status']['conditions'][0]['status']='False'},
 ->(b){b[4][0]['spec']['mode']='warn'},
 ->(b){b[4].pop}
].each do |mutation|
 bad=Marshal.load(Marshal.dump(bundle));mutation.call(bad)
 accepted=begin;NamespaceEnforcement.ready!(*bad);true;rescue StandardError;false;end
 check(!accepted,'stale/missing/bypassed admission prerequisite accepted')
end
puts 'STATIC_VERIFIED: prerequisite parser rejects stale controller/policy generation, unavailable endpoint and webhook bypass'
