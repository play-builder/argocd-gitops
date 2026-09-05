require 'yaml'
require 'json'
require 'open3'
Dir.chdir(File.expand_path('..', __dir__))
%w[dev prod].each do |env|
  app=YAML.load_file("argocd/bootstrap/#{env}/mini-commerce.yaml")
  ignores=app.dig('spec','template','spec','ignoreDifferences')
  allowed={
    ['apps','Deployment','mini-commerce']=>['/spec/replicas','/spec/template/metadata/annotations/reloader.stakater.com~1last-reloaded-from'],
    ['argoproj.io','Rollout','mini-commerce']=>['/spec/replicas','/spec/template/metadata/annotations/reloader.stakater.com~1last-reloaded-from'],
    ['','Service','mini-commerce-stable']=>['.spec.selector["rollouts-pod-template-hash"]'],
    ['','Service','mini-commerce-canary']=>['.spec.selector["rollouts-pod-template-hash"]'],
    ['networking.istio.io','VirtualService','mini-commerce']=>['.spec.http[] | select(.name == "primary") | .route[].weight']}
  ignores.each do |d|
    paths=d.fetch('jsonPointers',d.fetch('jqPathExpressions',[]))
    raise 'overbroad controller ownership' unless paths==allowed[[d['group'],d['kind'],d['name']]] && !d.key?('managedFieldsManagers')
  end
  route=ignores.find{|d|d['kind']=='VirtualService'}
  raise 'native route weight ownership missing' unless route
  input={'spec'=>{'hosts'=>['example.com'],'http'=>[
    {'name'=>'primary','match'=>[{'uri'=>{'prefix'=>'/'}}],'timeout'=>'10s','route'=>[{'destination'=>{'host'=>'stable'},'weight'=>100},{'destination'=>{'host'=>'canary'},'weight'=>0}]},
    {'name'=>'other','route'=>[{'weight'=>37}]}]}}
  output,status=Open3.capture2e('jq',"del(#{route['jqPathExpressions'][0]})",stdin_data:JSON.generate(input))
  raise output unless status.success?
  actual=JSON.parse(output)
  expected=Marshal.load(Marshal.dump(input))
  expected['spec']['http'][0]['route'].each{|r|r.delete('weight')}
  raise 'routing security drift hidden' unless actual==expected
end
puts 'STATIC_VERIFIED: exact named controller diff ownership; routing security preserved'
