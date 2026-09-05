require 'json'
require 'open3'
require 'tempfile'
Dir.chdir(File.expand_path('..',__dir__))
input={'namespace'=>'app-prod','consumerStatus'=>'PENDING_GITOPS_CUTOVER','sources'=>{},'readers'=>{}}
%w[runtime database migration].each do |k|
 keys=k=='runtime' ? ['API_KEY'] : %w[DB_HOST DB_PORT DB_NAME DB_USER DB_PASSWORD]
 input['sources'][k]={'sourceName'=>"prod-commerce/mini-commerce/#{k}",'sourceArn'=>"arn:aws:secretsmanager:us-east-1:111122223333:secret:prod-commerce/mini-commerce/#{k}-ABCdef",'targetName'=>"mini-commerce-#{k}",'properties'=>Hash[keys.map{|x|[x,x]}]}
end
%w[runtime migration].each do |k|
 sa=k=='runtime' ? 'mini-commerce-secrets-reader' : 'mini-commerce-migration-secrets-reader'
 store=k=='runtime' ? 'mini-commerce-secrets' : 'mini-commerce-migration-secrets'
 input['readers'][k]={'serviceAccountName'=>sa,'roleArn'=>"arn:aws:iam::111122223333:role/prod-commerce-#{sa}",'secretStore'=>{'name'=>store,'kind'=>'SecretStore','namespace'=>'app-prod','region'=>'us-east-1'}}
end
def invoke(doc)
 Tempfile.create(['secrets-handoff','.json']) do |f|
  f.write(JSON.generate(doc));f.flush
  Open3.capture2e('ruby','scripts/render-application-secrets.rb',f.path,'prod')
 end
end
out,s=invoke(input)
raise "typed secrets renderer unavailable: #{out}" unless s.success?
rendered=JSON.parse(out)
raise 'DML reader mismatch' unless rendered.dig('helmValues','externalSecrets','database','targetSecretName')=='mini-commerce-database'
raise 'stores absent' unless rendered['resources'].map{|d|d['kind']}.sort==%w[SecretStore SecretStore ServiceAccount ServiceAccount]
[->(d){d['sources']['migration']=d['sources']['database']},
 ->(d){d['namespace']='app-dev'},
 ->(d){d['readers']['migration']['roleArn']='arn:aws:iam::444455556666:role/wrong'},
 ->(d){d['sources']['runtime']['properties']['PASSWORD']='plaintext'},
 ->(d){d['sources']['database']['value']='secret'}].each do |mutate|
 d=Marshal.load(Marshal.dump(input));mutate.call(d)
 _,status=invoke(d);raise 'unsafe secret handoff accepted' if status.success?
end
puts 'STATIC_VERIFIED: typed secrets produce scoped stores and split values; no values disclosed'
