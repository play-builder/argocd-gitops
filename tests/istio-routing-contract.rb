require 'yaml'
require 'open3'
def check(ok, message); raise message unless ok; end
Dir.chdir(File.expand_path('..', __dir__))
def render(env)
  out,s=Open3.capture2e('helm','template','mini-commerce','charts/mini-commerce','-f',"envs/#{env}/values.yaml",'--set-string','image.repository=example.invalid/mini-commerce','--set-string',"image.digest=sha256:#{'a'*64}")
  raise out unless s.success?
  YAML.load_stream(out).compact
end
%w[dev prod].each do |env|
  docs=render(env)
  check(docs.none?{|d| d['apiVersion'].start_with?('gateway.')}, 'main chart must not own legacy Gateway routing')
  vs=docs.find{|d|d['kind']=='VirtualService'}
  check(vs && vs['metadata']['name']=='mini-commerce','native VirtualService missing')
  check(vs.dig('spec','gateways')==['istio-system/mini-commerce-internal'],'wrong ingress attachment')
  primary=vs['spec']['http'].find{|r|r['name']=='primary'}
  check(primary['route'].map{|r|r['weight']}==(env=='prod' ? [100,0] : [100]),'initial routing is not stable-only')
  workload=docs.find{|d|%w[Deployment Rollout].include?(d['kind'])}
  check(workload.dig('spec','template','metadata','labels','service.istio.io/canonical-name')=='mini-commerce','canonical service producer missing')
  next if env=='dev'
  canary=workload.dig('spec','strategy','canary')
  check(canary['trafficRouting']=={'istio'=>{'virtualService'=>{'name'=>'mini-commerce','routes'=>['primary']}}},'Rollout does not bind native Istio')
  check(canary['steps'].map{|s|s['setWeight']}.compact==[5,20,50,100],'incorrect rollout sequence')
  check(canary['steps'].index({'pause'=>{}})<canary['steps'].index({'setWeight'=>100}),'human approval must precede 100 percent')
  analysis=docs.find{|d|d['kind']=='AnalysisTemplate'}
  metrics=analysis.dig('spec','metrics')
  check(metrics.map{|m|m['name']}.sort==%w[latency request-rate success-rate],'analysis must gate traffic, availability and latency')
  metrics.each do |metric|
    q=metric.dig('provider','prometheus','query')
    check(q.include?('reporter="destination"') && q.include?('destination_canonical_service="mini-commerce"') && q.include?('destination_rollout_hash="{{args.latest-hash}}"'),'analysis must bind actual destination hash producer')
    check(!q.include?('http_requests_total'),'removed app RED metric used')
  end
  telemetry=docs.find{|d|d['kind']=='Telemetry'}
  override=telemetry.dig('spec','metrics',0,'overrides',0)
  check(override.dig('match','mode')=='SERVER','hash must describe destination proxy')
  check(override.dig('tagOverrides','destination_rollout_hash','value')=="node.metadata['LABELS']['rollouts-pod-template-hash']",'missing real hash label producer')
end
puts 'STATIC_VERIFIED: native Istio rendering and destination telemetry contract'
