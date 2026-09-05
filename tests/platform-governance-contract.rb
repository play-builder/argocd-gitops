require 'yaml'
require 'open3'
Dir.chdir(File.expand_path('..',__dir__))
%w[dev prod].each do |env|
 out,s=Open3.capture2e('kubectl','kustomize',"platform/security/#{env}")
 raise 'platform resource governance absent' unless s.success?
 docs=YAML.load_stream(out).compact
 ns=YAML.load_file("argocd/bootstrap/#{env}/application-namespace.yaml")
 raise 'PSA restricted/version missing' unless ns.dig('metadata','labels','pod-security.kubernetes.io/enforce')=='restricted' && ns.dig('metadata','labels','pod-security.kubernetes.io/enforce-version')=='v1.36'
 quota=docs.find{|d|d['kind']=='ResourceQuota'}
 raise 'quota missing sidecar capacity' unless quota && %w[requests.cpu requests.memory limits.cpu limits.memory pods].all?{|k|quota.dig('spec','hard',k)}
 limit=docs.find{|d|d['kind']=='LimitRange'}.dig('spec','limits',0)
 raise 'request defaults missing' unless limit['defaultRequest']=={'cpu'=>'100m','memory'=>'128Mi'}
 policy=docs.find{|d|d['kind']=='ValidatingAdmissionPolicy'}
 binding=docs.find{|d|d['kind']=='ValidatingAdmissionPolicyBinding'}
 raise 'security enforcement absent' unless policy && policy.dig('spec','failurePolicy')=='Fail' && binding.dig('spec','validationActions')==['Deny']
end
puts 'STATIC_VERIFIED: rendered PSA, VAP, quota and LimitRange; admission runtime unverified'
