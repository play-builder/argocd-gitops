require 'yaml'
require 'json'
Dir.chdir(File.expand_path('..',__dir__))
lock=YAML.load_file('versions.lock.yaml')
raise 'Argo version drift' unless lock.dig('delivery','argoCdController')=='3.5.2' && lock.dig('delivery','argoRolloutsController')=='1.9.1'
raise 'numeric identity drift' unless lock.dig('delivery','runtime','repositoryId')==1352247019
require_relative 'application-secrets-contract'
if ENV['EKS_REPO_ROOT']
 eks=File.realpath(ENV['EKS_REPO_ROOT'])
 producer=YAML.load_file(File.join(eks,'versions.lock.yaml'))
 raise 'EKS controller version drift' unless producer.dig('delivery','argoCdController')==lock.dig('delivery','argoCdController') && producer.dig('delivery','argoRolloutsController')==lock.dig('delivery','argoRolloutsController')
end
requirements=YAML.load_file('contracts/platform-requirements.yaml')
raise 'typed ECR handoff mismatch' unless requirements.dig('applicationAttestation','trustedEcrOutput')=='mini_commerce_ecr_repository_url'
raise 'post-cutover workflow mismatch' unless requirements.dig('applicationAttestation','postCutoverWorkflow')=='play-builder/mini-commerce/.github/workflows/ci.yml@refs/heads/main'
if ENV['APPLICATION_REPO_ROOT']
 app=File.realpath(ENV['APPLICATION_REPO_ROOT'])
 package=JSON.parse(File.read(File.join(app,'package.json')))
 raise 'application runtime mismatch' unless package['name']=='mini-commerce'
end
puts 'STATIC_VERIFIED: typed interfaces and immutable controller/repository identities; no sibling execution'
