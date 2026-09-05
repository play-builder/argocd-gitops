require 'yaml'
require 'json'
require 'open3'
require 'tempfile'
def check(ok, message)
  abort("FAIL: #{message}") unless ok
end
contract = YAML.load_file('contracts/platform-requirements.yaml')
check(contract['schemaVersion'] == 'platform.requirements/v2', 'typed v2 handoff contract is missing')
fixture = JSON.parse(File.read('tests/fixtures/platform-handoff/valid.json'))
def validate(value)
  Tempfile.create(['handoff', '.json']) do |f|
    f.write(JSON.generate(value)); f.flush
    _, status = Open3.capture2e('ruby', 'scripts/render-platform-credentials.rb', f.path, 'prod')
    status.success?
  end
end
check(validate(fixture), 'valid producer handoff rejected')
[
  ->(v) { v['argocd'].delete('secretStore') },
  ->(v) { v['argocd']['secretStore']['namespace']='default' },
  ->(v) { v['argocd']['haEnabled']=false },
  ->(v) { v['argocd']['controllerVersion']='v2.0.0' },
  ->(v) { v['argocd']['oidc'].delete('sourceArn') },
  ->(v) { v['argocd']['oidc']['properties']['clientSecret']='wrong' },
  ->(v) { v['argocd']['oidc']['targetName']='argocd-secret' },
  ->(v) { v['argocd']['notifications']['token']='literal-secret' },
  ->(v) { v['sigstoreController']['namespace']='default' }
].each_with_index do |mutate, i|
  v=Marshal.load(Marshal.dump(fixture)); mutate.call(v)
  check(!validate(v), "invalid producer mutation #{i} accepted")
end
out,status=Open3.capture2e('ruby','scripts/render-platform-credentials.rb','tests/fixtures/platform-handoff/valid.json','prod')
check(status.success?, 'render failed')
docs=YAML.load_stream(out)
check(docs.size==3 && docs.all?{|d|d['kind']=='ExternalSecret' && d['metadata']['namespace']=='argocd'}, 'credential owner or namespace incorrect')
docs.each do |d|
 check(d.dig('spec','secretStoreRef')=={'kind'=>'SecretStore','name'=>'argocd-secrets'}, 'store mismatch')
 check(d.dig('metadata','annotations','argocd.argoproj.io/sync-wave')=='-40','credential prerequisite ordering missing')
 check(!d['spec'].key?('dataFrom'),'unbounded secret extraction')
end
check(docs[0].dig('spec','target','template','metadata','labels','app.kubernetes.io/part-of')=='argocd','OIDC label absent')
check(docs[2].dig('spec','target','template','metadata','labels','argocd.argoproj.io/secret-type')=='repo-creds','repository label absent')
puts 'PASS: typed platform handoff rejects missing/malformed prerequisites and renders bounded credentials'

