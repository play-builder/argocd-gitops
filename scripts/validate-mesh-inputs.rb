#!/usr/bin/env ruby
require 'yaml'
begin
 docs=YAML.load_stream(File.read(ARGV.fetch(0))).compact
 waf=docs.find{|d|d['kind']=='LoadBalancerConfiguration'} or raise 'WAF attachment required'
 raise 'unsupported WAF field' if waf['spec'].key?('wafv2ACLArn')
 raise 'inject exact regional WAF output before sync' unless waf.dig('spec','wafV2','webACL').to_s.match?(/\Aarn:aws:wafv2:[a-z0-9-]+:\d{12}:regional\/webacl\/[A-Za-z0-9_-]+\/[a-f0-9-]{36}\z/)
 cert=waf.dig('spec','listenerConfigurations',0,'defaultCertificate').to_s
 raise 'approved ACM certificate required' unless cert.match?(/\Aarn:aws:acm:[a-z0-9-]+:\d{12}:certificate\/[a-f0-9-]{36}\z/)
 gateways=docs.select{|d|d['kind']=='Gateway' && d['apiVersion'].start_with?('gateway.networking')}
 raise 'HTTPS edge required' if gateways.empty?
 gateways.each do |g|
  raise 'public edge requires explicit host and HTTPS:443' unless g['spec']['listeners'].all?{|l|l['protocol']=='HTTPS' && l['port']==443 && l['hostname'].to_s.match?(/\A[a-z0-9][a-z0-9.-]+\z/) && !l['hostname'].include?('*')}
 end
 docs.select{|d|d['kind']=='HTTPRoute'}.each do |r|
  raise 'management port or wrong backend exposed' unless r['spec']['rules'].flat_map{|x|x['backendRefs']}.all?{|x|x['name']=='istio-ingress-stable' && x['port']==80}
 end
 raise 'NetworkPolicy required' unless docs.any?{|d|d['kind']=='NetworkPolicy'}
 raise 'final STRICT mTLS required' unless docs.any?{|d|d['kind']=='PeerAuthentication' && d.dig('spec','mtls','mode')=='STRICT'}
 raise 'default deny required' unless docs.any?{|d|d['kind']=='AuthorizationPolicy' && d['spec']=={}}
 docs.select{|d|d['kind']=='AuthorizationPolicy'}.each do |d|
  (d.dig('spec','rules')||[]).each do |r|
   (r['from']||[]).each do |f|
    principals=f.dig('source','principals')
    raise 'exact mesh principal required' unless principals && principals.all?{|p|p.start_with?('cluster.local/ns/') && !p.include?('*')}
   end
  end
 end
 puts 'PASS: explicit mesh release inputs; runtime readiness still required'
rescue StandardError=>e
 warn "FAIL: #{e.message}";exit 1
end
