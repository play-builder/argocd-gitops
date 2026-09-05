require 'yaml'
require 'json'
require 'open3'
require 'tempfile'
def check(x,m);abort("FAIL: #{m}") unless x;end
docs=YAML.load_stream(Open3.capture2('kubectl','kustomize','platform/istio/overlays/prod')[0])
waf=docs.find{|d|d['kind']=='LoadBalancerConfiguration'}
waf['spec']['wafV2']['webACL']='arn:aws:wafv2:ap-northeast-2:123456789012:regional/webacl/fixture/12345678-1234-1234-1234-123456789012'
waf['spec']['listenerConfigurations'][0]['defaultCertificate']='arn:aws:acm:ap-northeast-2:123456789012:certificate/12345678-1234-1234-1234-123456789012'
def accepted(docs)
 Tempfile.create(['mesh','.yaml']) do |f|
  f.write(docs.map{|d|YAML.dump(d)}.join);f.flush
  _,s=Open3.capture2e('ruby','scripts/validate-mesh-inputs.rb',f.path)
  s.success?
 end
end
check(accepted(docs),'valid fixture rejected')
[
 ->(d){d.find{|x|x['kind']=='LoadBalancerConfiguration'}['spec']['wafV2']['webACL']=''},
 ->(d){d.find{|x|x['kind']=='LoadBalancerConfiguration'}['spec']['wafv2ACLArn']='bad'},
 ->(d){d.find{|x|x['kind']=='HTTPRoute'}['spec']['rules'][0]['backendRefs'][0]['port']=3001},
 ->(d){d.find{|x|x['kind']=='Gateway'&&x['apiVersion'].start_with?('gateway.networking')}['spec']['listeners'][0]['protocol']='HTTP'},
 ->(d){d.find{|x|x['kind']=='Gateway'&&x['apiVersion'].start_with?('gateway.networking')}['spec']['listeners'][0]['hostname']='*.example.com'},
 ->(d){d.find{|x|x['kind']=='AuthorizationPolicy'&&x['metadata']['name']=='mini-commerce-ingress'}['spec']['rules'][0]['from'][0]['source']['principals']=['*']},
 ->(d){d.reject!{|x|x['kind']=='NetworkPolicy'}},
 ->(d){d.find{|x|x['kind']=='PeerAuthentication'}['spec']['mtls']['mode']='PERMISSIVE'}
].each{|f|v=Marshal.load(Marshal.dump(docs));f.call(v);check(!accepted(v),'unsafe mesh input accepted')}
puts 'PASS: real rendered mesh inputs reject WAF/TLS/management/authz/policy mutations'
