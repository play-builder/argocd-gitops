require 'yaml'
def valid(c)
 c['schemaVersion']=='platform.slo/v1' && c['owner']=='EKS-infra' &&
 c['objective']==0.999 && c['windows']==['5m','1h'] && c['requestRateFloor'].is_a?(Numeric) && c['requestRateFloor']>0 &&
 c['labels'].sort==%w[environment runbook service severity] &&
 c['metrics'].sort==%w[istio_request_duration_milliseconds_bucket istio_requests_total] &&
 c['selector']=={'reporter'=>'destination','destination_service_name'=>'mini-commerce'}
end
c=YAML.load_file('contracts/amp-slo-consumer.yaml')
abort 'FAIL: invalid EKS SLO consumer schema' unless valid(c)
[->(x){x['labels']<<'gitops_revision'},->(x){x['labels']<<'customer_id'},->(x){x['requestRateFloor']=0},->(x){x['selector']['reporter']='source'},->(x){x['metrics'].pop}].each do |f|
 x=Marshal.load(Marshal.dump(c));f.call(x);abort 'FAIL: unsafe SLO mutation accepted' if valid(x)
end
abort 'FAIL: GitOps must not deploy EKS-owned AMP rules' unless Dir.glob('platform/**/*').none?{|p|File.file?(p)&&File.basename(p).match?(/amp.*rules/)}
puts 'PASS: EKS-owned AMP SLO consumer, bounded labels and traffic floor'
