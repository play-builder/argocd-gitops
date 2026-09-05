require 'json'
require 'digest'
require 'tempfile'
require 'open3'
Dir.chdir(File.expand_path('..',__dir__))
sha='a'*40;digest='sha256:'+'b'*64;arn='arn:aws:eks:us-east-1:111122223333:cluster/prod'
dr={'schemaVersion'=>'platform.argocd-dr/v1','evidenceGrade'=>'CLOUD_RUNTIME','capturedAt'=>'2026-09-05T00:00:00Z',
 'source'=>{'clusterArn'=>arn,'argocdVersion'=>'3.5.2','namespace'=>'argocd','gitopsRevision'=>sha},
 'payload'=>{'bucket'=>'prod-dr','key'=>'exports/export.yaml','versionId'=>'immutable-version','kmsKeyArn'=>'arn:aws:kms:us-east-1:111122223333:key/12345678-1234-1234-1234-123456789012','sha256'=>digest,'sizeBytes'=>1024,'s3ChecksumSha256'=>['b'*64].pack('H*').then{|x|[x].pack('m0')}},
 'restored'=>{'clusterArn'=>'arn:aws:eks:us-east-1:111122223333:cluster/drill','namespace'=>'argocd','argocdVersion'=>'3.5.2','applicationRevisions'=>{'mini-commerce-prod'=>sha},'observedAt'=>'2026-09-05T00:10:00Z'}}
record={'schemaVersion'=>'platform.incident-binding/v1','evidenceGrade'=>'CLOUD_RUNTIME','clusterArn'=>arn,'argocdVersion'=>'3.5.2','application'=>'mini-commerce-prod','applicationRevision'=>sha,'rolloutRevision'=>2,'istioRevision'=>'1-30-4','imageDigest'=>digest,'repositoryId'=>1352247019,'primaryWeights'=>{'mini-commerce-stable'=>100,'mini-commerce-canary'=>0},'notificationEventId'=>'PD-event-123','drMetadataSha256'=>''}
def run(record,dr)
 Tempfile.create(['dr','.json']) do |d|
  d.write(JSON.generate(dr));d.flush
  record=Marshal.load(Marshal.dump(record));record['drMetadataSha256']="sha256:#{Digest::SHA256.file(d.path).hexdigest}"
  Tempfile.create(['incident','.json']) do |r|
   r.write(JSON.generate(record));r.flush
   Open3.capture2e('ruby','scripts/verify-incident-binding.rb',r.path,d.path)
  end
 end
end
out,s=run(record,dr);raise "incident validator missing: #{out}" unless s.success?
[->(r,d){r['repositoryId']=123},
 ->(r,d){r['applicationRevision']='c'*40},
 ->(r,d){d['payload'].delete('versionId')},
 ->(r,d){d['payload']['s3ChecksumSha256']='wrong'},
 ->(r,d){d['restored']['clusterArn']=d['source']['clusterArn']},
 ->(r,d){d['evidenceGrade']='STATIC_VERIFIED'},
 ->(r,d){r['argocdVersion']='3.5.1'},
 ->(r,d){r['notificationEventId']=''},
 ->(r,d){d['payload']['secret']='leak'}
].each do |mutate|
 r,d=Marshal.load(Marshal.dump([record,dr]));mutate.call(r,d)
 _,status=run(r,d);raise 'invalid incident/DR binding accepted' if status.success?
end
puts 'STATIC_VERIFIED: incident/DR parser rejects identity mismatch, metadata-only and grade uplift'
require 'tmpdir'
Dir.mktmpdir('incident-consumer-') do |dir|
 source=File.join(File.realpath(dir),'baseline.json')
 File.write(source,JSON.generate({'evidenceGrade'=>'CLOUD_RUNTIME','clusterArn'=>arn,'gitopsRevision'=>sha,'image'=>{'indexDigest'=>digest},'rollout'=>{'revision'=>2,'trafficWeight'=>100}}))
 raw_dr=JSON.pretty_generate(dr)+"\n"
 incident=Marshal.load(Marshal.dump(record))
 incident['drMetadataSha256']="sha256:#{Digest::SHA256.hexdigest(raw_dr)}"
 companion={'schemaVersion'=>'platform.runtime-capture/v1','evidenceGrade'=>'CLOUD_RUNTIME','sourceSha256'=>"sha256:#{Digest::SHA256.file(source).hexdigest}",'incident'=>incident,'drMetadata'=>raw_dr}
 path="#{source}.platform.json"
 File.write(path,JSON.generate(companion))
 output,status=Open3.capture2e('ruby','scripts/verify-incident-companion.rb',source)
 raise "actual companion consumer missing: #{output}" unless status.success? && output.include?('STATIC_VERIFIED')
 [->(x){x['sourceSha256']='sha256:'+'0'*64},
  ->(x){x['evidenceGrade']='STATIC_VERIFIED'},
  ->(x){x['incident'].delete('notificationEventId')},
  ->(x){x['drMetadata']+=" "},
  ->(x){x['incident']['applicationRevision']='d'*40},
  ->(x){x['incident']['rolloutRevision']=3}
 ].each do |mutate|
  bad=Marshal.load(Marshal.dump(companion));mutate.call(bad)
  File.write(path,JSON.generate(bad))
  _,status=Open3.capture2e('ruby','scripts/verify-incident-companion.rb',source)
  raise 'invalid source/incident companion accepted' if status.success?
 end
 File.unlink(path)
 _,status=Open3.capture2e('ruby','scripts/verify-incident-companion.rb',source)
 raise 'missing incident companion accepted' if status.success?
end
puts 'STATIC_VERIFIED: production source companion requires exact bytes and complete incident/DR binding'
