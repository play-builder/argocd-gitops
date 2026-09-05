require 'yaml'
require 'open3'
def check(x,m);abort("FAIL: #{m}") unless x;end
def valid(project,app,env)
 p=project.dig('metadata','annotations')||{}; a=app.dig('spec','template','metadata','annotations')||{}
 combined=p.merge(a); return false unless (p.keys & a.keys).grep(/notifications/).empty?
 paging=%w[on-sync-failed on-health-degraded on-sync-status-unknown].to_h{|t|["notifications.argoproj.io/subscribe.#{t}.pagerdutyv2","platform-prod"]}
 deployment={'notifications.argoproj.io/subscribe.on-deployed.slack'=>'platform-deployments'}
 dev=%w[on-sync-failed on-health-degraded].to_h{|t|["notifications.argoproj.io/subscribe.#{t}.slack","platform-deployments"]}
 combined.select{|k,v|k.start_with?('notifications.')}==(env=='prod' ? paging.merge(deployment) : dev.merge(deployment))
end
%w[dev prod].each do |env|
 out,s=Open3.capture2e('kubectl','kustomize',"argocd/bootstrap/#{env}");check(s.success?,'render failed')
 docs=YAML.load_stream(out);p=docs.find{|d|d['kind']=='AppProject' && d['metadata']['name']=="platform-#{env}"}
 a=docs.find{|d|d['kind']=='ApplicationSet'&&d['metadata']['name']=="mini-commerce-#{env}"}
 check(valid(p,a,env),'subscription routes missing or wrong')
 x=Marshal.load(Marshal.dump(a));x['spec']['template']['metadata']['annotations']['notifications.argoproj.io/subscribe.on-deployed.pagerdutyv2']='platform-prod'
 check(!valid(p,x,env),'completion paging accepted')
 x=Marshal.load(Marshal.dump(a));x['spec']['template']['metadata']['annotations'].merge!(p['metadata']['annotations'].select{|k,v|k.start_with?('notifications.')})
 check(!valid(p,x,env),'duplicate project/application subscriptions accepted') if env=='prod'
end
puts 'PASS: subscription routing and completion non-paging boundaries'

