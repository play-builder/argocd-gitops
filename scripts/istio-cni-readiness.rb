#!/usr/bin/env ruby
require 'json'
require 'yaml'
require 'open3'
require 'optparse'
require 'time'

def check(value, message)
  raise message unless value
end
def ready(object)
  object.dig('status', 'conditions').to_a.any? { |c| c['type'] == 'Ready' && c['status'] == 'True' }
end
def validate(record, max_age)
  check(record['schemaVersion'] == 'platform.istio-cni-readiness/v1', 'unsupported readiness schema')
  check(%w[fixture captured].include?(record['source']), 'invalid captured source')
  check(record['context'].is_a?(String) && !record['context'].empty?, 'cluster context required')
  age = Time.now.utc - Time.iso8601(record.fetch('observedAt'))
  check(age >= 0 && age <= max_age, 'stale/future readiness snapshot')
  nodes = record.fetch('nodes').fetch('items').select { |n| n.dig('metadata', 'labels', 'kubernetes.io/os') == 'linux' }
  check(!nodes.empty? && nodes.all? { |n| ready(n) }, 'all Linux nodes must be present and Ready')
  names = nodes.map { |n| n['metadata']['name'] }.sort
  check(names.uniq == names, 'duplicate nodes in snapshot')
  lock = YAML.load_file(File.expand_path('../versions.lock.yaml', __dir__))
  image = lock.fetch('delivery').fetch('platformImages').fetch('istioCni').fetch('upstreamReference')
  [['cni', 'istio-cni-node', 'istio-cni', 'install-cni'], ['vpc', 'aws-node', 'kube-system', 'aws-node']].each do |key, name, namespace, container_name|
    ds = record.fetch(key + 'DaemonSet')
    check(ds.dig('metadata', 'name') == name && ds.dig('metadata', 'namespace') == namespace, "#{key} DaemonSet identity mismatch")
    uid = ds.fetch('metadata').fetch('uid')
    check(ds.fetch('status').fetch('observedGeneration') >= ds.fetch('metadata').fetch('generation'), "#{key} generation not observed")
    %w[desiredNumberScheduled updatedNumberScheduled numberReady numberAvailable].each do |field|
      check(ds['status'][field] == names.size, "#{key} #{field} does not cover every Linux node")
    end
    check(ds['status'].fetch('numberMisscheduled', 0) == 0, "#{key} pods scheduled on unintended nodes")
    pods = record.fetch(key + 'Pods').fetch('items').reject { |p| p.dig('metadata', 'deletionTimestamp') }
    check(pods.map { |p| p.dig('spec', 'nodeName') }.sort == names, "#{key} requires one active pod per node")
    pods.each do |pod|
      check(pod.dig('metadata', 'ownerReferences').to_a.any? { |o| o['kind'] == 'DaemonSet' && o['uid'] == uid && o['controller'] == true }, "#{key} pod owner mismatch")
      check(pod.dig('status', 'phase') == 'Running' && ready(pod), "#{key} pod is not Running/Ready")
      check(pod.dig('status', 'containerStatuses').to_a.any? { |c| c['name'] == container_name && c['ready'] == true }, "#{key} agent container not ready")
      if key == 'cni'
        check(pod.dig('spec', 'containers').find { |c| c['name'] == container_name }&.fetch('image') == image, 'CNI pod image does not match locked index')
      end
    end
  end
  {'schemaVersion' => record['schemaVersion'], 'status' => 'CAPTURED_READY',
   'evidenceGrade' => record['source'] == 'fixture' ? 'LOCAL_VERIFIED' : 'LIVE_NOT_VERIFIED',
   'context' => record['context'], 'nodes' => names,
   'verificationLimit' => 'Snapshot consistency only; verify collection identity, real post-injection admission, traffic and new-node repair separately.'}
end

begin
  mode = ARGV.shift
  options = {max_age: 300}
  OptionParser.new do |parser|
    parser.on('--input PATH') { |v| options[:input] = v }
    parser.on('--output PATH') { |v| options[:output] = v }
    parser.on('--context NAME') { |v| options[:context] = v }
    parser.on('--max-age-seconds N', Integer) { |v| options[:max_age] = v }
  end.parse!
  check(options[:max_age] > 0, 'positive snapshot age required')
  if mode == 'collect'
    check(options[:context] && options[:output], 'collect requires explicit --context and new --output')
    record = {'schemaVersion' => 'platform.istio-cni-readiness/v1', 'source' => 'captured', 'observedAt' => Time.now.utc.iso8601, 'context' => options[:context]}
    {
      'nodes' => ['nodes'],
      'cniDaemonSet' => ['daemonset', 'istio-cni-node', '-n', 'istio-cni'],
      'cniPods' => ['pods', '-n', 'istio-cni', '-l', 'k8s-app=istio-cni-node'],
      'vpcDaemonSet' => ['daemonset', 'aws-node', '-n', 'kube-system'],
      'vpcPods' => ['pods', '-n', 'kube-system', '-l', 'k8s-app=aws-node']
    }.each do |key, resource|
      output, status = Open3.capture2e('kubectl', '--context', options[:context], '--request-timeout=30s', 'get', *resource, '-o', 'json')
      check(status.success?, "read-only kubectl collection failed for #{key}")
      record[key] = JSON.parse(output)
    end
    File.open(options[:output], File::WRONLY | File::CREAT | File::EXCL, 0600) { |file| file.write(JSON.pretty_generate(record)) }
  elsif mode == 'validate'
    check(options[:input], 'validate requires --input')
    record = JSON.parse(File.read(options[:input]))
  else
    raise 'usage: istio-cni-readiness.rb collect --context NAME --output PATH | validate --input PATH'
  end
  puts JSON.generate(validate(record, options[:max_age]))
rescue StandardError => error
  warn "CNI_NOT_READY: #{error.message}"
  exit 1
end
