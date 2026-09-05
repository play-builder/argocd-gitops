require 'yaml'
require 'open3'
require 'json'
def check(x,m);abort("FAIL: #{m}") unless x;end
%w[dev prod].each do |env|
 docs=YAML.load_stream(Open3.capture2('kubectl','kustomize',"argocd/bootstrap/#{env}")[0])
 p=docs.find{|d|d['kind']=='AppProject' && d['metadata']['name']=="platform-#{env}"}
 policy=p.dig('spec','sourceIntegrity','git','policies',0)
 check(policy && policy.dig('gpg','mode')=='head' && !policy.dig('gpg','keys').empty?,'Git HEAD verification policy missing')
 check(!p['spec'].key?('signatureKeys'),'deprecated GPG API')
 out,s=Open3.capture2e('kubectl','kustomize',"platform/security/sigstore/overlays/#{env}")
 check(s.success?,'Sigstore overlay missing')
 docs=YAML.load_stream(out)
 policies=docs.select{|d|d['kind']=='ClusterImagePolicy' && d['metadata']['name'].start_with?('mini-commerce-')}
 check(policies.length==2,'SLSA and SPDX policies must both match')
 check(docs.count{|d|d['kind']=='TrustRoot'}==1,'GitHub TrustRoot missing')
 policies.each do |d|
  check(d['spec']['mode']==(env=='prod' ? 'enforce':'warn'),'incorrect enforcement mode')
  check(d['spec']['authorities'].map{|a|a['name']}.sort==['github','public-good'],'public GitHub attestations need public-good trust authority')
  check(d['spec']['images']==[{'glob'=>'REPLACE_FROM_EKS_MINI_COMMERCE_ECR@sha256:*'}],'trusted digest scope missing')
  d['spec']['authorities'].each do |auth|
  check(auth['signatureFormat']=='bundle' && auth.dig('keyless','identities').length==2,'bundle cutover identity pair missing')
  check(auth['keyless']['identities'].all?{|i|i['issuer']=='https://token.actions.githubusercontent.com' && i['subject'].start_with?('https://github.com/play-builder/')},'wrong issuer/workflow')
  check(auth['attestations']==d['spec']['authorities'][0]['attestations'],'public authority must enforce the same predicate')
  end
 end
 check(policies.map{|d|d.dig('spec','authorities',0,'attestations',0,'predicateType')}.sort==['https://slsa.dev/provenance/v1','https://spdx.dev/Document/v2.3'],'two predicates required')
 # Local policy contract evaluation, not cryptographic admission verification.
 trusted=YAML.load_file('tests/fixtures/source-integrity/platform-handoff.yaml')['outputs']['mini_commerce_ecr_repository_url']
 matches=lambda do |evidence|
  image="#{evidence['imageRepository']}@#{evidence['indexDigest']}"
  evidence['indexDigest'].match?(/\Asha256:[0-9a-f]{64}\z/) && policies.all? do |d|
   glob=d['spec']['images'][0]['glob'].sub('REPLACE_FROM_EKS_MINI_COMMERCE_ECR',trusted)
   File.fnmatch?(glob,image) && d['spec']['authorities'].any? do |authority|
    authority['keyless']['identities'].any?{|i|i['issuer']==evidence['issuer'] && i['subject']=="https://github.com/#{evidence['workflow']}"} &&
    authority['attestations'].all?{|a|evidence['predicates'].include?(a['predicateType'])}
   end
  end
 end
 check(matches.call(JSON.parse(File.read('tests/fixtures/source-integrity/pre-cutover-valid.json'))),'rendered policies reject valid evidence')
 unsigned=JSON.parse(File.read('tests/fixtures/source-integrity/pre-cutover-valid.json'));unsigned['predicates']=[]
 check(!matches.call(unsigned),'business image without attestations must remain rejected')
 %w[wrong-workflow wrong-issuer wrong-digest missing-spdx public-image].each do |name|
  check(!matches.call(JSON.parse(File.read("tests/fixtures/source-integrity/#{name}.json"))),"rendered policy accepted #{name}")
 end
end
lock=YAML.load_file('versions.lock.yaml')
check(lock.dig('delivery','helmSources').is_a?(Array) && lock['delivery']['helmSources'].length>=7,'chart archive locks absent')
puts 'PASS: GPG HEAD and rendered two-policy Sigstore desired state'
