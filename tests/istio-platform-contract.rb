require 'yaml'
require 'open3'
def check(x,m);abort("FAIL: #{m}") unless x;end
%w[dev prod].each do |env|
 out,s=Open3.capture2e('kubectl','kustomize',"argocd/bootstrap/#{env}");check(s.success?,'bootstrap render failed')
 docs=YAML.load_stream(out); apps=docs.select{|d|d['kind']=='Application' && d.dig('spec','source','repoURL')=='https://blob.istio.io/istio-release/charts'}
 check(apps.length==5,'need one base, two istiod and two gateways')
 base=apps.select{|d|d.dig('spec','source','chart')=='base'}
 check(base.length==1 && base[0].dig('spec','source','targetRevision')=='1.31.0' && base[0].dig('spec','source','helm','valuesObject','defaultRevision')=='1-30-4','shared base revision wrong')
 control=apps.select{|d|d.dig('spec','source','chart')=='istiod'}
 check(control.map{|d|d.dig('spec','source','helm','valuesObject','revision')}.sort==['1-30-4','1-31-0'],'two real revisions absent')
 tags=control.flat_map{|d|d.dig('spec','source','helm','valuesObject','revisionTags')||[]}
 check(tags.sort==(env=='dev' ? ['dev-stable'] : ['prod-canary','prod-stable']),'revision tag ownership duplicated')
 check(apps.all?{|d|!d.dig('spec','syncPolicy','automated') && d.dig('metadata','annotations','argocd.argoproj.io/sync-options')=='Prune=confirm'},'premature revision pruning enabled')
 out,s=Open3.capture2e('kubectl','kustomize',"platform/istio/overlays/#{env}");check(s.success?,'mesh overlay missing')
 mesh=YAML.load_stream(out)
 check(mesh.any?{|d|d['kind']=='PeerAuthentication' && d.dig('spec','mtls','mode')=='STRICT'},'final mTLS must be strict')
 check(mesh.any?{|d|d['kind']=='AuthorizationPolicy' && d['spec']=={}},'default deny absent')
 check(mesh.any?{|d|d['kind']=='NetworkPolicy'},'mesh traffic paths unbounded')
 edge=mesh.find{|d|d['kind']=='Gateway' && d['apiVersion'].start_with?('gateway.networking')}
 check(edge && edge['spec']['listeners'].all?{|l|l['protocol']=='HTTPS' && l['port']==443 && !l['hostname'].include?('*')},'public TLS listener invalid')
 routes=mesh.select{|d|d['kind']=='HTTPRoute'}
 check(routes.flat_map{|d|d['spec']['rules']}.flat_map{|r|r['backendRefs']}.all?{|r|r['name']=='istio-ingress-stable' && r['port']==80},'public management exposure or wrong ingress')
 waf=mesh.find{|d|d['kind']=='LoadBalancerConfiguration'}
 check(waf.dig('spec','wafV2','webACL')=='REPLACE_FROM_EKS_MINI_COMMERCE_WAF_WEB_ACL_ARN','typed WAF reference absent')
end
puts 'PASS: revisioned Istio, one base/tag owner and scoped mesh/HTTPS edge'
stage=YAML.load_stream(Open3.capture2('kubectl','kustomize','platform/istio/migration/dev-permissive')[0])
check(stage.any?{|d|d['kind']=='PeerAuthentication' && d.dig('spec','mtls','mode')=='PERMISSIVE'},'Dev migration inventory lacks actual permissive stage')
