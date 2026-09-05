#!/usr/bin/env ruby
require 'json'
require 'yaml'
require 'open3'
require_relative 'lib/namespace-enforcement'
begin
  environment, expected_context = ARGV
  abort 'Usage: namespace-enforcement-preflight.rb dev|prod EXPECTED_KUBE_CONTEXT' unless ARGV.length==2 && %w[dev prod].include?(environment) && !expected_context.to_s.empty?
  run=->(*cmd){out,status=Open3.capture2e(*cmd);raise "read-only prerequisite command failed: #{cmd.first}" unless status.success?;out}
  raise 'unexpected Kubernetes context' unless run.call('kubectl','config','current-context').strip==expected_context
  get=->(*args){JSON.parse(run.call('kubectl',*args,'-o','json'))}
  root=File.expand_path('..',__dir__)
  rendered=run.call('kubectl','kustomize',"#{root}/platform/security/sigstore/overlays/#{environment}")
  raise 'inject and review policy identities before prerequisite validation' if rendered.include?('REPLACE_')
  desired=YAML.load_stream(rendered).compact.select{|r|r['kind']=='ClusterImagePolicy'}
  deployment=get.call('-n','cosign-system','get','deployment','policy-controller-webhook')
  slices=get.call('-n','cosign-system','get','endpointslices','-l','kubernetes.io/service-name=webhook')
  hooks=[['mutatingwebhookconfiguration','defaulting.clusterimagepolicy.sigstore.dev'],
    ['mutatingwebhookconfiguration','policy.sigstore.dev'],
    ['validatingwebhookconfiguration','validating.clusterimagepolicy.sigstore.dev'],
    ['validatingwebhookconfiguration','policy.sigstore.dev']].map{|kind,name|get.call('get',kind,name)}
  actual=NamespaceEnforcement::REQUIRED_POLICIES.map{|name|get.call('get','clusterimagepolicy',name)}
  NamespaceEnforcement.ready!(deployment,slices,hooks,desired,actual)
  puts 'READY: current controller/webhook/policy prerequisites observed; no root sync or workload admission performed'
rescue StandardError => error
  warn "FAIL: #{error.message}";exit 1
end
