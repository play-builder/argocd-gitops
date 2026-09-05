require 'yaml'
require 'open3'
def check(ok,msg); abort("FAIL: #{msg}") unless ok; end
def valid(project,app,env)
  s=project.fetch('spec'); a=app.fetch('spec').fetch('template').fetch('spec')
  return false if s['destinations'].any?{|d|d['namespace']=='argocd'}
  return false unless s['clusterResourceWhitelist']==[]
  return false if s['namespaceResourceWhitelist'].any?{|r|%w[SecretStore Secret AppProject Application ApplicationSet ConfigMap].include?(r['kind'])}
  return false unless s['orphanedResources']=={'warn'=>true}
  s.fetch('roles').each do |role|
    role['policies'].each do |line|
      fields=line.split(',').map(&:strip)
      return false unless fields[0]=='p' && fields[1]=="proj:platform-#{env}:#{role['name']}" && fields[2]=='applications' && %w[get sync action/argoproj.io/Rollout/promote].include?(fields[3]) && fields[4]=="platform-#{env}/*" && fields[5]=='allow'
    end
  end
  sync=a.fetch('syncPolicy')
  return false if env=='prod' && sync.key?('automated')
  return false if env=='dev' && sync['automated']!={'prune'=>true,'selfHeal'=>true}
  return false if (sync['syncOptions']||[]).include?('Replace=true')
  return false if (sync['automated']||{})['allowEmpty']
  a.fetch('ignoreDifferences').each do |d|
    return false if d.key?('managedFieldsManagers') || !d['name']
    return false if d.fetch('jsonPointers',[]).any?{|p|!['/spec/replicas','/spec/template/metadata/annotations/reloader.stakater.com~1last-reloaded-from'].include?(p)}
    # Temporary Task9 exception is one named active plugin route, never all HTTPRoutes.
    return false if d['kind']=='HTTPRoute' && d['name']!='mini-commerce'
  end
  true
end
%w[dev prod].each do |env|
 out,status=Open3.capture2e('kubectl','kustomize',"argocd/bootstrap/#{env}")
 check(status.success?,'Kustomize failed')
 docs=YAML.load_stream(out)
 p=docs.find{|d|d['kind']=='AppProject' && d['metadata']['name']=="platform-#{env}"}
 a=docs.find{|d|d['kind']=='ApplicationSet' && d['metadata']['name']=="mini-commerce-#{env}"}
 check(p && a,'platform tenancy project missing')
 check(valid(p,a,env),'tenant privileges or drift boundary invalid')
 [->(p,a){p['spec']['destinations']<<{'namespace'=>'argocd'}},
  ->(p,a){p['spec']['clusterResourceWhitelist']<<{'group'=>'','kind'=>'Namespace'}},
  ->(p,a){p['spec']['roles'][0]['policies']<<'p, role:admin, applications, delete, */*, allow'},
  ->(p,a){a['spec']['template']['spec']['ignoreDifferences'][0].delete('name')},
  ->(p,a){a['spec']['template']['spec']['syncPolicy']['syncOptions']<<'Replace=true'}
 ].each{|fn|pp,aa=Marshal.load(Marshal.dump([p,a]));fn.call(pp,aa);check(!valid(pp,aa,env),'unsafe tenancy mutation accepted')}
end
c=YAML.load_file('contracts/platform-requirements.yaml')['argocd']
check(c.values_at('oidcGroupsClaim','defaultRole','anonymousAccess','breakGlassRole')==['groups','role:authenticated',false,'platform-break-glass'],'global RBAC consumer invalid')
puts 'PASS: rendered tenancy, role tuples and named drift scopes'
