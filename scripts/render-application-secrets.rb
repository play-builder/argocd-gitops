#!/usr/bin/env ruby
require 'json'
require 'yaml'
def check(ok,message);raise message unless ok;end
begin
 file,env=ARGV
 check(%w[dev prod recovery].include?(env),'environment required')
 input=JSON.parse(File.read(file))
 input=input.fetch('mini_commerce_secrets',input.fetch('recovery_secrets',input))
 input=input['value'] if input.key?('value')
 ns="app-#{env}"
 check(input['namespace']==ns,'secret namespace mismatch')
 sources=input.fetch('sources');readers=input.fetch('readers')
 check(sources.keys.sort==%w[database migration runtime] && readers.keys.sort==%w[migration runtime],'secret roles mismatch')
 accounts=[];regions=[]
 values={'externalSecrets'=>{'enabled'=>true,'createSecretStore'=>false,'createReaderServiceAccount'=>false}}
 sources.each do |kind,source|
  check(source.keys.sort==%w[properties sourceArn sourceName targetName],'secret values or unknown fields prohibited')
  props=kind=='runtime' ? ['API_KEY'] : %w[DB_HOST DB_PORT DB_NAME DB_USER DB_PASSWORD]
  check(source['properties']==Hash[props.map{|x|[x,x]}],'secret properties mismatch')
  check(source['targetName']=="mini-commerce-#{kind}",'secret target mismatch')
  match=/\Aarn:aws:secretsmanager:([a-z0-9-]+):([0-9]{12}):secret:(.+)-[A-Za-z0-9]{6}\z/.match(source['sourceArn'])
  check(match && match[3]==source['sourceName'],'source ARN/name mismatch')
  accounts<<match[2];regions<<match[1]
  values['externalSecrets'][kind]={'remoteSecretName'=>source['sourceArn'],'targetSecretName'=>source['targetName']}
 end
 check(accounts.uniq.length==1 && regions.uniq.length==1,'cross-account or cross-region secret sources')
 resources=[]
 readers.each do |kind,reader|
  name=kind=='runtime' ? 'mini-commerce-secrets' : 'mini-commerce-migration-secrets'
  sa="#{name}-reader"
  check(reader.keys.sort==%w[roleArn secretStore serviceAccountName],'reader fields mismatch')
  check(reader['serviceAccountName']==sa,'reader service account mismatch')
  check(reader['roleArn'].match?(/\Aarn:aws:iam::#{accounts[0]}:role\/[A-Za-z0-9+=,.@_\/-]+\z/),'reader account mismatch')
  store=reader['secretStore']
  check(store=={'name'=>name,'kind'=>'SecretStore','namespace'=>ns,'region'=>regions[0]},'store identity mismatch')
  meta={'name'=>sa,'namespace'=>ns,'annotations'=>{'argocd.argoproj.io/sync-wave'=>'-15','eks.amazonaws.com/role-arn'=>reader['roleArn']}}
  resources<<{'apiVersion'=>'v1','kind'=>'ServiceAccount','metadata'=>meta}
  resources<<{'apiVersion'=>'external-secrets.io/v1','kind'=>'SecretStore','metadata'=>{'name'=>name,'namespace'=>ns,'annotations'=>{'argocd.argoproj.io/sync-wave'=>'-15'}},'spec'=>{'provider'=>{'aws'=>{'service'=>'SecretsManager','region'=>regions[0],'auth'=>{'jwt'=>{'serviceAccountRef'=>{'name'=>sa}}}}}}}
 end
 puts JSON.pretty_generate({'evidenceGrade'=>'STATIC_VERIFIED','resources'=>resources,'helmValues'=>values})
rescue StandardError=>e
 warn "FAIL: #{e.message}";exit 1
end
