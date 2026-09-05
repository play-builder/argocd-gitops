module NamespaceEnforcement
  REQUIRED_POLICIES = %w[mini-commerce-slsa mini-commerce-spdx platform-istio-mirror].freeze
  def self.check(ok, message); raise message unless ok; end
  def self.ready!(deployment, slices, webhooks, desired, actual)
    spec=deployment.fetch('spec'); status=deployment.fetch('status')
    replicas=spec.fetch('replicas')
    check(replicas>0 && status['observedGeneration']==deployment.dig('metadata','generation') &&
      %w[updatedReplicas readyReplicas availableReplicas].all?{|k|status[k]==replicas},
      'Policy Controller Deployment is not fully reconciled/available')
    check(slices.fetch('items').any?{|s|s.fetch('endpoints',[]).any?{|e|e.dig('conditions','ready')==true && !e.fetch('addresses',[]).empty?}},
      'Policy Controller webhook has no ready endpoint')
    check(webhooks.length==4,'all four pinned chart webhooks required')
    webhooks.each do |configuration|
      hooks=configuration.fetch('webhooks',[])
      check(!hooks.empty?,'empty webhook configuration')
      hooks.each do |hook|
        service=hook.dig('clientConfig','service')
        check(hook['failurePolicy']=='Fail' && service && service['name']=='webhook' && service['namespace']=='cosign-system' &&
          !hook.dig('clientConfig','caBundle').to_s.empty? && !hook.fetch('rules',[]).empty?,
          'webhook fail-closed service, CA or reconciled rules missing')
        if hook['name']=='policy.sigstore.dev'
          check(hook.dig('namespaceSelector','matchExpressions').to_a.include?({'key'=>'policy.sigstore.dev/include','operator'=>'In','values'=>['true']}),
            'application policy namespace selector changed')
        end
      end
    end
    check(desired.map{|r|r.dig('metadata','name')}.sort==REQUIRED_POLICIES.sort,'reviewed policy set incomplete')
    desired.each do |want|
      name=want.dig('metadata','name'); found=actual.find{|r|r.dig('metadata','name')==name}
      check(found && found['spec']==want['spec'],"ClusterImagePolicy #{name} differs from reviewed Git desired state")
      check(found.dig('status','observedGeneration')==found.dig('metadata','generation') &&
        found.dig('status','conditions').to_a.any?{|c|c['type']=='Ready' && c['status']=='True'},
        "ClusterImagePolicy #{name} is not ready at its current generation")
    end
    true
  end
end
