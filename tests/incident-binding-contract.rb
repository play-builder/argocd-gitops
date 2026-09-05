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
