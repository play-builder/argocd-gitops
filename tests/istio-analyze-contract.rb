require 'yaml'
require 'open3'
require 'tempfile'
def run(*cmd)
 out,s=Open3.capture2e(*cmd);abort out unless s.success?;out
end
cache=ENV.fetch('CHART_CACHE_DIR')
%w[dev prod].each do |env|
 docs=YAML.load_stream(run('kubectl','kustomize',"argocd/bootstrap/#{env}"))
 apps=docs.select{|d|d['kind']=='Application' && d.dig('spec','source','repoURL')=='https://blob.istio.io/istio-release/charts'}
 resources=YAML.load_stream(run('kubectl','kustomize',"platform/istio/overlays/#{env}"))
 resources+=YAML.load_stream(run('kubectl','kustomize','platform/istio/base'))
 apps.each do |a|
  source=a['spec']['source']
  Tempfile.create(['values','.yaml']) do |v|
   v.write(YAML.dump(source['helm']['valuesObject']));v.flush
   path=File.join(cache,"#{source['chart']}-#{source['targetRevision']}.tgz")
   resources+=YAML.load_stream(run('helm','template',source['helm']['releaseName'],path,'--namespace','istio-system','-f',v.path)).compact
  end
 end
 # AWS CRs and generated CRD definitions are validated by kubeconform separately.
 supported=resources.select{|d|d && (d['apiVersion'].match?(/istio.io/) || %w[Namespace Service ConfigMap Deployment].include?(d['kind']))}
 Tempfile.create(['mesh-analysis','.yaml']) do |f|
  f.write(supported.map{|d|YAML.dump(d)}.join);f.flush
  puts run('istioctl','analyze','--use-kube=false','--all-namespaces',f.path)
 end
end

