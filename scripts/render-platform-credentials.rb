#!/usr/bin/env ruby
# Reads reference metadata only; never retrieves or writes secret values.
require 'json'
require 'yaml'
begin
  h=JSON.parse(File.read(ARGV.fetch(0))); env=ARGV.fetch(1)
  raise 'environment must be dev or prod' unless %w[dev prod].include?(env)
  raise 'platform.requirements/v2 required' unless h['schemaVersion']=='platform.requirements/v2'
  a=h.fetch('argocd'); s=a.fetch('secretStore'); c=h.fetch('sigstoreController')
  raise 'Argo namespace/version mismatch' unless a.values_at('namespace','chartVersion','controllerVersion')==['argocd','10.4.3','v3.5.2']
  raise 'Prod requires HA' if env=='prod' && a['haEnabled']!=true
  raise 'explicit public bootstrap required' unless a['bootstrapMode']=='public'
  raise 'EKS namespace-scoped SecretStore required' unless s.values_at('kind','name','namespace')==['SecretStore','argocd-secrets','argocd']
  raise 'invalid RBAC policy hash' unless a.fetch('rbacPolicyHash').match?(/\A[0-9a-f]{64}\z/)
  raise 'Sigstore prerequisite mismatch' unless c.values_at('namespace','chartVersion','appVersion')==['cosign-system','0.10.5','0.13.1']
  repository=h.fetch('outputs').fetch('mini_commerce_ecr_repository_url')
  raise 'typed ECR repository URL required' unless repository.match?(/\A[0-9]{12}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com\/[a-z0-9][a-z0-9._\/-]*\z/)
  routes=a.fetch('notifications').fetch('routes')
  expected_routes={'paging'=>{'service'=>'pagerdutyv2','recipient'=>'platform-prod'},'deployment'=>{'service'=>'slack','recipient'=>'platform-deployments','secretKey'=>'slack-token'}}
  raise 'notification route handoff mismatch' unless routes==expected_routes
  expected={
    'oidc'=>['argocd-oidc',{'clientSecret'=>'clientSecret'}],
    'notifications'=>['argocd-notifications-secret',{'pagerduty-integration-key'=>'pagerdutyIntegrationKey','slack-token'=>'slackToken'}],
    'repositoryCredentials'=>['argocd-repository-credentials',{'url'=>'url','username'=>'username','password'=>'password'}]
  }
  docs=expected.map do |name,(target,properties)|
    v=a.fetch(name)
    allowed=%w[sourceArn sourceName targetName properties clientSecretRef routes]
    raise 'literal or unknown secret fields forbidden' unless (v.keys-allowed).empty?
    raise 'source ARN required' unless v.fetch('sourceArn').match?(/\Aarn:aws:secretsmanager:[a-z0-9-]+:\d{12}:secret:[A-Za-z0-9\/_+=.@-]+\z/)
    raise 'source name required' unless v.fetch('sourceName').is_a?(String) && !v['sourceName'].empty?
    raise 'target/property mapping mismatch' unless v['targetName']==target && v['properties']==properties
    labels={'app.kubernetes.io/part-of'=>'argocd'}
    labels['argocd.argoproj.io/secret-type']='repo-creds' if name=='repositoryCredentials'
    template={'metadata'=>{'labels'=>labels}}
    template['data']={'type'=>'git','url'=>'{{ .url }}','username'=>'{{ .username }}','password'=>'{{ .password }}'} if name=='repositoryCredentials'
    {'apiVersion'=>'external-secrets.io/v1','kind'=>'ExternalSecret',
     'metadata'=>{'name'=>target,'namespace'=>'argocd','annotations'=>{'argocd.argoproj.io/sync-wave'=>'-40'}},
     'spec'=>{'refreshInterval'=>'1h','secretStoreRef'=>{'kind'=>s['kind'],'name'=>s['name']},
     'target'=>{'name'=>target,'creationPolicy'=>'Merge','deletionPolicy'=>'Retain','template'=>template},
     'data'=>properties.map{|key,property|{'secretKey'=>key,'remoteRef'=>{'key'=>v['sourceArn'],'property'=>property}}}}}
  end
  # ESO owns the separately named Secrets; Argo's internal argocd-secret is not replaced.
  docs.each{|d|d['spec']['target']['creationPolicy']='Owner'; puts YAML.dump(d)}
rescue KeyError, ArgumentError, JSON::ParserError, RuntimeError => e
  warn "FAIL: #{e.message}"; exit 1
end
