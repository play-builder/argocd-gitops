#!/usr/bin/env ruby
require 'json'
require 'digest'
require 'time'
def check(ok,message); raise message unless ok;end
begin
 incident_path,dr_path,source_path=ARGV
 r=JSON.parse(File.read(incident_path));d=JSON.parse(File.read(dr_path))
 check(r.keys.sort==%w[application applicationRevision argocdVersion clusterArn drMetadataSha256 evidenceGrade imageDigest istioRevision notificationEventId primaryWeights repositoryId rolloutRevision schemaVersion],'incident fields mismatch')
 check(r['schemaVersion']=='platform.incident-binding/v1' && r['evidenceGrade']=='CLOUD_RUNTIME','runtime incident required; fixture validation never writes evidence')
 check(r['argocdVersion']=='3.5.2' && r['application']=='mini-commerce-prod' && r['repositoryId']==1352247019,'release identity mismatch')
 check(r['applicationRevision'].match?(/\A[0-9a-f]{40}\z/) && r['imageDigest'].match?(/\Asha256:[0-9a-f]{64}\z/),'release digest/revision invalid')
 check(r['rolloutRevision'].is_a?(Integer) && r['rolloutRevision']>0 && %w[1-30-4 1-31-0].include?(r['istioRevision']),'controller revision invalid')
 check(r['primaryWeights']=={'mini-commerce-stable'=>100,'mini-commerce-canary'=>0},'release primary weights not stable')
 check(r['notificationEventId'].is_a?(String) && !r['notificationEventId'].strip.empty?,'notification delivery event missing')
 check(r['drMetadataSha256']=="sha256:#{Digest::SHA256.file(dr_path).hexdigest}",'DR metadata checksum mismatch')
 check(d['schemaVersion']=='platform.argocd-dr/v1' && d['evidenceGrade']=='CLOUD_RUNTIME','DR runtime evidence required')
 source=d.fetch('source');payload=d.fetch('payload');restored=d.fetch('restored')
 check(source['clusterArn']==r['clusterArn'] && source['argocdVersion']=='3.5.2' && source['namespace']=='argocd' && source['gitopsRevision']==r['applicationRevision'],'DR source identity mismatch')
 check(r['clusterArn'].match?(/\Aarn:aws:eks:[a-z0-9-]+:[0-9]{12}:cluster\/[A-Za-z0-9_-]+\z/),'cluster ARN invalid')
 check(payload.keys.sort==%w[bucket key kmsKeyArn s3ChecksumSha256 sha256 sizeBytes versionId],'DR payload fields incomplete or unsafe')
 %w[bucket key versionId kmsKeyArn].each{|k|check(payload[k].is_a?(String) && !payload[k].strip.empty?,"DR payload #{k} missing")}
 check(payload['versionId']!='null' && payload['kmsKeyArn'].match?(/\Aarn:aws:kms:[a-z0-9-]+:[0-9]{12}:key\/[A-Za-z0-9-]+\z/),'immutable encrypted object required')
 check(payload['sizeBytes'].is_a?(Integer) && payload['sizeBytes']>0 && payload['sha256'].match?(/\Asha256:[0-9a-f]{64}\z/),'actual payload size/hash required')
 expected=[[payload['sha256'].delete_prefix('sha256:')].pack('H*')].pack('m0')
 check(payload['s3ChecksumSha256']==expected,'S3 checksum not bound to payload')
 check(restored['clusterArn']!=source['clusterArn'] && restored['clusterArn'].match?(/\Aarn:aws:eks:[a-z0-9-]+:[0-9]{12}:cluster\/[A-Za-z0-9_-]+\z/) && restored['argocdVersion']=='3.5.2' && restored['namespace']=='argocd','restore must be same version and isolated')
 check(restored['applicationRevisions'].is_a?(Hash) && restored['applicationRevisions'][r['application']]==r['applicationRevision'],'restored Application revision mismatch')
 check(Time.iso8601(restored['observedAt'])>=Time.iso8601(d['capturedAt']),'restore timestamp precedes capture')
 if source_path
  s=JSON.parse(File.read(source_path))
  check(s['evidenceGrade']=='CLOUD_RUNTIME' && s['clusterArn']==r['clusterArn'] && s['gitopsRevision']==r['applicationRevision'],'capture source identity mismatch')
  check(s.dig('image','indexDigest')==r['imageDigest'],'capture source image mismatch') if s.key?('image')
 end
 puts 'STATIC_VERIFIED: runtime evidence structure/binding accepted; no cloud execution performed'
rescue StandardError=>e
 warn "FAIL: #{e.message}";exit 1
end
