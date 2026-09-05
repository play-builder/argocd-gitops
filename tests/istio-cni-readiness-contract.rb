require 'json'
require 'open3'
require 'tmpdir'
require 'time'
Dir.chdir(File.expand_path('..', __dir__))
def check(value, message); abort "FAIL: #{message}" unless value; end
def fixture
  node = {'metadata' => {'name' => 'node-a', 'labels' => {'kubernetes.io/os' => 'linux', 'kubernetes.io/arch' => 'amd64'}}, 'status' => {'conditions' => [{'type' => 'Ready', 'status' => 'True'}]}}
  image = 'docker.io/istio/install-cni@sha256:8cef43ba08ae1af846d0e474591f625cd2dd6b2c0df0efcb17faef0d978ef246'
  result = {'schemaVersion' => 'platform.istio-cni-readiness/v1', 'source' => 'fixture', 'observedAt' => Time.now.utc.iso8601, 'context' => 'test-cluster', 'nodes' => {'items' => [node]}}
  [['cni', 'istio-cni-node', 'istio-cni', image], ['vpc', 'aws-node', 'kube-system', 'example.invalid/aws-node@sha256:' + 'b' * 64]].each do |key, name, namespace, ref|
    result[key + 'DaemonSet'] = {'metadata' => {'name' => name, 'namespace' => namespace, 'uid' => key + '-uid', 'generation' => 2}, 'status' => {'observedGeneration' => 2, 'desiredNumberScheduled' => 1, 'updatedNumberScheduled' => 1, 'numberReady' => 1, 'numberAvailable' => 1}}
    result[key + 'Pods'] = {'items' => [{'metadata' => {'name' => name + '-pod', 'ownerReferences' => [{'kind' => 'DaemonSet', 'uid' => key + '-uid', 'controller' => true}]}, 'spec' => {'nodeName' => 'node-a', 'containers' => [{'name' => key == 'cni' ? 'install-cni' : 'aws-node', 'image' => ref}]}, 'status' => {'phase' => 'Running', 'conditions' => [{'type' => 'Ready', 'status' => 'True'}], 'containerStatuses' => [{'name' => key == 'cni' ? 'install-cni' : 'aws-node', 'ready' => true}]}}]}
  end
  result
end
def evaluate(record)
  Dir.mktmpdir('cni-readiness-') do |directory|
    input = "#{directory}/record.json"; File.write(input, JSON.generate(record))
    Open3.capture2e('ruby', 'scripts/istio-cni-readiness.rb', 'validate', '--input', input)
  end
end
output, status = evaluate(fixture)
check(status.success?, "valid captured CNI readiness rejected: #{output}")
check(JSON.parse(output)['evidenceGrade'] == 'LOCAL_VERIFIED', 'fixture readiness promoted to live')
cases = {
  'missing-node' => ->(r) { r['nodes']['items'] << Marshal.load(Marshal.dump(r['nodes']['items'][0])).tap { |n| n['metadata']['name'] = 'node-b' } },
  'stale-daemonset' => ->(r) { r['cniDaemonSet']['status']['observedGeneration'] = 1 },
  'cni-unavailable' => ->(r) { r['cniDaemonSet']['status']['numberAvailable'] = 0 },
  'aws-vpc-cni-unavailable' => ->(r) { r['vpcPods']['items'][0]['status']['conditions'][0]['status'] = 'False' },
  'wrong-cni-owner' => ->(r) { r['cniPods']['items'][0]['metadata']['ownerReferences'][0]['uid'] = 'foreign' },
  'wrong-cni-image' => ->(r) { r['cniPods']['items'][0]['spec']['containers'][0]['image'] = 'docker.io/istio/install-cni:latest' },
  'stale-snapshot' => ->(r) { r['observedAt'] = (Time.now.utc - 3600).iso8601 },
  'empty-nodes' => ->(r) { r['nodes']['items'] = [] }
}
cases.each do |name, mutation|
  record = fixture; mutation.call(record)
  output, status = evaluate(record)
  check(!status.success?, "#{name} accepted: #{output}")
end
puts 'PASS: CNI/VPC readiness captured fixture and 8 failure modes; no Kubernetes calls'
