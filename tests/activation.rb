require 'open3'
require 'tmpdir'
require 'fileutils'
require 'yaml'

root = File.expand_path('..', __dir__)
Dir.mktmpdir('activation-inputs-') do |tmp|
  %w[argocd platform charts envs scripts .github].each { |name| FileUtils.cp_r(File.join(root, name), tmp) }
  run = lambda { Open3.capture2e('ruby', File.join(tmp, 'scripts/validate-activation.rb'), 'prod') }
  output, status = run.call
  raise 'unconfigured activation was accepted' if status.success? || !output.include?('unresolved deployment input')
  # Synthetic deployment inputs, never uploaded: test the positive gate as well
  # as unknown infrastructure identifiers and hostname/image regressions.
  Dir.glob(File.join(tmp, '{argocd,platform,envs}/**/*.{yaml,yml}')).each do |path|
    text = File.read(path)
    text.gsub!('REPLACE_FROM_EKS_MINI_COMMERCE_WAF_WEB_ACL_ARN', 'arn:aws:wafv2:ap-northeast-2:123456789012:regional/webacl/commerce/11111111-1111-1111-1111-111111111111')
    text.gsub!('REPLACE_WITH_TRUSTED_CALLER_CIDR', '10.10.1.0/24')
    text.gsub!('REPLACE_WITH_APPROVED_ACM_CERTIFICATE_ARN', 'arn:aws:acm:ap-northeast-2:123456789012:certificate/11111111-1111-1111-1111-111111111111')
    text.gsub!('REPLACE_ME_ACCOUNT_ID', '123456789012')
    text.gsub!('REPLACE_ME_REGION', 'ap-northeast-2')
    text.gsub!(/REPLACE_[A-Za-z0-9_]+/, 'configured')
    text.gsub!('mini-commerce.prod.example.com', 'commerce.company.test')
    text.gsub!("sha256:#{'0' * 64}", "sha256:#{'a' * 64}")
    File.write(path, text)
  end
  path = File.join(tmp, 'envs/prod/stateful-values.yaml')
  File.write(path, YAML.dump({'database' => {'enabled' => true}}))
  path = File.join(tmp, 'envs/prod/values.yaml')
  values = YAML.load_file(path)
  values['database']['allowedCidrs'] = ['10.10.0.0/24']
  File.write(path, YAML.dump(values))
  File.write(File.join(tmp, '.github/CODEOWNERS'), '/ @test-owner\n')
  output, status = run.call
  raise "configured activation rejected: #{output}" unless status.success? && output.include?('STATIC_VERIFIED')
  values['routing']['hostname'] = 'wrong.company.test'
  File.write(path, YAML.dump(values))
  output, status = run.call
  raise 'mismatched route hostname accepted' if status.success? || !output.include?('hostname differs')
  values['routing']['hostname'] = 'commerce.company.test'
  values['image']['repository'] = 'docker.io/library/untrusted'
  File.write(path, YAML.dump(values))
  output, status = run.call
  raise 'untrusted app repository accepted' if status.success? || !output.include?('Network ECR identity')
end
puts 'STATIC_VERIFIED: activation refuses unresolved inputs, untrusted images and hostname drift; synthetic inputs only'
