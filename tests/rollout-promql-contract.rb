require 'yaml'
require 'open3'
require 'tmpdir'
Dir.chdir(File.expand_path('..',__dir__))
out,s=Open3.capture2e('helm','template','mini-commerce','charts/mini-commerce','-f','envs/prod/values.yaml')
raise out unless s.success?
metrics=YAML.load_stream(out).compact.find{|d|d['kind']=='AnalysisTemplate'}.dig('spec','metrics')
selectors='reporter="destination",destination_canonical_service="mini-commerce",destination_workload_namespace="app-prod",destination_rollout_hash="new"'
cases=[
 ['healthy',6000,0,6000,1,1,1],
 ['below-floor',5.4,0,5.4,0,1,1],
 ['bad-errors',5880,120,6000,1,0,1],
 ['bad-latency',6000,0,0,1,1,0]
]
tests=cases.map do |name,success,errors,fast,want_rate,want_success,want_latency|
 series=[
  {'series'=>"istio_requests_total{#{selectors},response_code=\"200\"}",'values'=>"0+#{success}x10"},
  {'series'=>"istio_requests_total{#{selectors},response_code=\"500\"}",'values'=>"0+#{errors}x10"},
  {'series'=>"istio_request_duration_milliseconds_bucket{#{selectors},le=\"100\"}",'values'=>"0+#{fast}x10"},
  {'series'=>"istio_request_duration_milliseconds_bucket{#{selectors},le=\"1000\"}",'values'=>"0+#{success+errors}x10"},
  {'series'=>"istio_request_duration_milliseconds_bucket{#{selectors},le=\"+Inf\"}",'values'=>"0+#{success+errors}x10"}
 ]
 expected={'request-rate'=>[">= bool 0.1",want_rate],'success-rate'=>[">= bool 99",want_success],'latency'=>["<= bool 500",want_latency]}
 {'name'=>name,'interval'=>'1m','input_series'=>series,'promql_expr_test'=>metrics.map do |m|
   suffix,want=expected.fetch(m['name'])
   {'expr'=>"(#{m.dig('provider','prometheus','query').gsub('{{args.latest-hash}}','new')}) #{suffix}",'eval_time'=>'5m','exp_samples'=>[{'labels'=>'{}','value'=>want}]}
 end}
end
Dir.mktmpdir('rollout-promql-') do |dir|
 file=File.join(dir,'tests.yaml')
 File.write(file,YAML.dump({'evaluation_interval'=>'1m','tests'=>tests}))
 output,status=Open3.capture2e('promtool','test','rules',file)
 raise output unless status.success?
 puts output
end
