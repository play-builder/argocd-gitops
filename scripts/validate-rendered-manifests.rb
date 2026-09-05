#!/usr/bin/env ruby
require 'yaml'
require 'json'
require 'digest'
require 'open3'
require 'tmpdir'
require 'fileutils'
def run(*cmd)
 out,status=Open3.capture2e(*cmd)
 raise "#{cmd.first} failed: #{out}" unless status.success?
 out
end
def download(url,path,headers=[])
 run('curl','-fsSL','--retry','2','--max-time','90',*headers,url,'-o',path)
end
def strict(schema)
 return unless schema.is_a?(Hash)
 if schema['properties'] && !schema['x-kubernetes-preserve-unknown-fields'] && !schema.key?('additionalProperties')
  schema['additionalProperties']=false
 end
 schema.each_value{|v|v.is_a?(Array) ? v.each{|x|strict(x)} : strict(v)}
end
begin
 lock=YAML.load_file(ENV.fetch('VERSION_LOCK','versions.lock.yaml'))
 cache=ENV.fetch('CHART_CACHE_DIR',File.join(Dir.tmpdir,'mini-commerce-locked-charts'))
 FileUtils.mkdir_p(cache)
 charts={}
 lock.fetch('delivery').fetch('helmSources').each do |c|
  raise 'chart digest required' unless c.fetch('sha256').match?(/\A[0-9a-f]{64}\z/)
  path=File.join(cache,"#{c.fetch('chart')}-#{c.fetch('version')}.tgz")
  unless File.exist?(path)
   if c['url'].start_with?('oci://')
    registry=c['url'].delete_prefix('oci://ghcr.io/')
    token=JSON.parse(run('curl','-fsSL','--max-time','30',"https://ghcr.io/token?scope=repository:#{registry}:pull&service=ghcr.io")).fetch('token')
    headers=['-H',"Authorization: Bearer #{token}"]
    manifest=run('curl','-fsSL','--max-time','30',*headers,'-H','Accept: application/vnd.oci.image.manifest.v1+json',"https://ghcr.io/v2/#{registry}/manifests/#{c['version']}")
    raise 'OCI manifest digest mismatch' unless "sha256:#{Digest::SHA256.hexdigest(manifest)}"==c.fetch('ociDigest')
    layer=JSON.parse(manifest).fetch('layers').find{|l|l['mediaType']=='application/vnd.cncf.helm.chart.content.v1.tar+gzip'}
    raise 'OCI layer mismatch' unless layer['digest']=="sha256:#{c['sha256']}"
    download("https://ghcr.io/v2/#{registry}/blobs/#{layer['digest']}",path,headers)
   else
    download(c.fetch('url'),path)
   end
  end
  raise "chart checksum mismatch #{path}" unless Digest::SHA256.file(path).hexdigest==c['sha256']
  meta=YAML.load(run('helm','show','chart',path))
  raise 'chart identity mismatch' unless meta['name']==c['chart'] && meta['version'].to_s==c['version'].to_s
  charts[[c['chart'],c['version']]]=path
 end
 if ARGV.include?('--locks-only')
  puts 'PASS: every chart archive checksum and chart identity verified'
  exit
 end
 Dir.mktmpdir('gitops-schema-') do |tmp|
  schemas=File.join(tmp,'schemas');FileUtils.mkdir_p(schemas)
  crds=[]
  [['argo-cd','10.4.3'],['argo-rollouts','2.42.0'],['external-secrets','2.10.0'],['policy-controller','0.10.5'],['aws-load-balancer-controller','3.5.0'],['base','1.31.0']].each do |key|
   args=['helm','template','schema',charts.fetch(key),'--include-crds']
   args+=['--set','clusterName=static-fixture'] if key[0]=='aws-load-balancer-controller'
   crds+=YAML.load_stream(run(*args)).compact.select{|d|d['kind']=='CustomResourceDefinition'}
  end
  gateway=lock.fetch('delivery').fetch('gatewayApiStandard')
  gp=File.join(cache,'gateway-api-standard.yaml')
  download(gateway.fetch('url'),gp) unless File.exist?(gp)
  raise 'Gateway API checksum mismatch' unless Digest::SHA256.file(gp).hexdigest==gateway['sha256']
  crds+=YAML.load_stream(File.read(gp)).compact
  crds.each do |d|
   next unless d['kind']=='CustomResourceDefinition'
   d.fetch('spec').fetch('versions').select{|v|v['served']}.each do |v|
    schema=v.dig('schema','openAPIV3Schema');next unless schema
    strict(schema)
    schema['properties']||={}
    schema['properties'].merge!({'apiVersion'=>{'type'=>'string'},'kind'=>{'type'=>'string'},'metadata'=>{'type'=>'object'}})
    file=File.join(schemas,"#{d['spec']['group']}-#{d['spec']['names']['kind'].downcase}-#{v['name']}.json")
    File.write(file,JSON.generate(schema))
   end
  end
  manifest=[]
  %w[dev prod].each do |env|
   manifest+=YAML.load_stream(run('kubectl','kustomize',"argocd/bootstrap/#{env}")).compact
   manifest+=YAML.load_stream(run('kubectl','kustomize',"platform/security/sigstore/overlays/#{env}")).compact
   if Dir.exist?("platform/istio/overlays/#{env}")
    manifest+=YAML.load_stream(run('kubectl','kustomize',"platform/istio/overlays/#{env}")).compact
   end
   args=['helm','template','mini-commerce','charts/mini-commerce','-f',"envs/#{env}/values.yaml",'-f',"envs/#{env}/pre-cutover-ownership-values.yaml",
    '--set-string','image.repository=example.invalid/mini-commerce','--set-string',"image.digest=sha256:#{'a'*64}",
    '--set-string','database.migrationImage.repository=example.invalid/mini-commerce','--set-string',"database.migrationImage.digest=sha256:#{'a'*64}"]
   manifest+=YAML.load_stream(run(*args)).compact
  end
  manifest=YAML.load_stream(File.read(ARGV[ARGV.index('--file')+1])).compact if ARGV.include?('--file')
  remote=[]
  manifest.select{|d|d['kind']=='Application' && d.dig('spec','source','chart')}.each do |d|
   source=d['spec']['source']; chart=charts.fetch([source['chart'],source['targetRevision']])
   values=File.join(tmp,'application-values.yaml');File.write(values,YAML.dump(source.dig('helm','valuesObject')||{}))
   remote+=YAML.load_stream(run('helm','template',source.dig('helm','releaseName')||d['metadata']['name'],chart,'--namespace',d['spec']['destination']['namespace'],'-f',values)).compact
  end
  manifest+=remote
  # Pinned upstream CRDs provide validation schemas. Their schema documents are not
  # workload instances; kubeconform has no builtin CRD meta-schema for this version.
  crd_count=manifest.count{|d|d['kind']=='CustomResourceDefinition'}
  manifest.reject!{|d|d['kind']=='CustomResourceDefinition'}
  puts "Pinned upstream CRD definitions used separately: #{crd_count}"
  path=File.join(tmp,'rendered.yaml');File.write(path,manifest.map{|d|YAML.dump(d)}.join)
  schema_uri=File.join(schemas,'{{.Group}}-{{.ResourceKind}}-{{.ResourceAPIVersion}}.json')
  puts run('kubeconform','-strict','-summary','-kubernetes-version','1.36.0','-schema-location',schema_uri,'-schema-location','default',path)
  if ARGV.include?('--negative')
   rollout=manifest.find{|d|d['kind']=='Rollout'};raise 'Rollout fixture missing' unless rollout
   rollout['spec']['unknownInvalidField']=true
   File.write(path,YAML.dump(rollout))
   out,status=Open3.capture2e('kubeconform','-strict','-summary','-schema-location',schema_uri,path)
   raise 'invalid Rollout schema accepted' if status.success? || !out.include?('unknownInvalidField')
   puts 'PASS: real CRD rejects unknown Rollout field'
  end
 end
 puts 'STATIC_VERIFIED: rendered schema checks; no controller/admission/traffic execution'
rescue StandardError => e
 warn "FAIL: #{e.message}";exit 1
end
