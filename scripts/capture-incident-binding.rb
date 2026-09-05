#!/usr/bin/env ruby
require 'json'
require 'open3'
require 'digest'
require 'tempfile'
def query(*cmd)
 out,s=Open3.capture2e(*cmd)
 raise "read-only capture failed: #{cmd.first}" unless s.success?
 out
end
begin
 dr_path,notification_event_id=ARGV
 raise 'Usage: capture-incident-binding.rb DR_METADATA_JSON REVIEWED_NOTIFICATION_EVENT_ID' unless dr_path && notification_event_id && !notification_event_id.strip.empty?
 d=JSON.parse(File.read(dr_path));cluster=d.fetch('source').fetch('clusterArn')
 region=cluster.split(':')[3];name=cluster.split('/').last
 aws=JSON.parse(query('aws','eks','describe-cluster','--region',region,'--name',name,'--output','json'))
 config=JSON.parse(query('kubectl','config','view','--minify','-o','json'))
 raise 'active kubeconfig does not bind DR source cluster' unless aws.dig('cluster','arn')==cluster && config.fetch('clusters').length==1 && config.dig('clusters',0,'cluster','server')==aws.dig('cluster','endpoint')
 version=query('argocd','version','--short')
 raise 'Argo server version must match 3.5.2' unless version.match?(/^argocd-server: v3\.5\.2(?:\+|$)/)
 app=JSON.parse(query('kubectl','-n','argocd','get','application','mini-commerce-prod','-o','json'))
 rollout=JSON.parse(query('kubectl','-n','app-prod','get','rollout','mini-commerce','-o','json'))
 vs=JSON.parse(query('kubectl','-n','app-prod','get','virtualservice','mini-commerce','-o','json'))
 pods=JSON.parse(query('kubectl','-n','app-prod','get','pods','-l','app.kubernetes.io/name=mini-commerce','-o','json'))
 replicas=JSON.parse(query('kubectl','-n','app-prod','get','replicasets','-o','json'))
 stable=rollout.fetch('status').fetch('stableRS')
 matching=replicas.fetch('items').select{|r|r.dig('metadata','labels','rollouts-pod-template-hash')==stable && (r.dig('metadata','ownerReferences')||[]).any?{|o|o['uid']==rollout.dig('metadata','uid') && o['controller']==true}}
 raise 'stable ReplicaSet identity ambiguous' unless matching.length==1
 revisions=pods.fetch('items').select{|p|p.dig('metadata','labels','rollouts-pod-template-hash')==stable}.map{|p|JSON.parse(p.dig('metadata','annotations','sidecar.istio.io/status')||'{}')['revision']}.uniq
 raise 'stable injected revision missing/ambiguous' unless revisions.length==1 && revisions[0]
 routes=vs.fetch('spec').fetch('http').select{|r|r['name']=='primary'}
 raise 'primary route ambiguous' unless routes.length==1 && routes[0]['route'].length==2
 images=rollout.dig('spec','template','spec','containers').select{|c|c['name']=='mini-commerce'}
 raise 'app image ambiguous' unless images.length==1
 r={'schemaVersion'=>'platform.incident-binding/v1','evidenceGrade'=>'CLOUD_RUNTIME','clusterArn'=>cluster,'argocdVersion'=>'3.5.2','application'=>'mini-commerce-prod','applicationRevision'=>app.dig('status','sync','revision'),'rolloutRevision'=>Integer(matching[0].dig('metadata','annotations','rollout.argoproj.io/revision')),'istioRevision'=>revisions[0],'imageDigest'=>images[0]['image'].split('@')[1],'repositoryId'=>1352247019,'primaryWeights'=>Hash[routes[0]['route'].map{|x|[x.dig('destination','host'),x['weight']]}],'notificationEventId'=>notification_event_id,'drMetadataSha256'=>"sha256:#{Digest::SHA256.file(dr_path).hexdigest}"}
 Tempfile.create(['incident-binding','.json']) do |f|
  f.write(JSON.generate(r));f.flush
  query('ruby',File.join(__dir__,'verify-incident-binding.rb'),f.path,dr_path)
 end
 puts JSON.pretty_generate(r)
rescue StandardError=>e
 warn "FAIL: #{e.message}";exit 1
end
