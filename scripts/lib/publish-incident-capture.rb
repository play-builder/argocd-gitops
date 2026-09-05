require 'json'
require 'digest'
require 'tempfile'
require 'open3'

module IncidentCapture
  class Rejected < StandardError; end
  def self.publish(candidate, output, incident, dr, linker: File.method(:link))
    [candidate, incident, dr].each do |path|
      raise Rejected, 'regular physical input required' unless File.file?(path) && !File.symlink?(path) && File.realpath(path) == File.expand_path(path)
    end
    output = File.expand_path(output)
    parent = File.dirname(output)
    raise Rejected, 'physical output directory required' unless File.realpath(parent) == parent
    companion = "#{output}.platform.json"
    validator = File.expand_path('../verify-incident-binding.rb', __dir__)
    _, status = Open3.capture2e('ruby', validator, incident, dr, candidate)
    raise Rejected, 'incident binding rejected' unless status.success?
    bytes = File.binread(candidate)
    record = {'schemaVersion'=>'platform.runtime-capture/v1','evidenceGrade'=>'CLOUD_RUNTIME',
      'sourceSha256'=>"sha256:#{Digest::SHA256.hexdigest(bytes)}",
      'incident'=>JSON.parse(File.read(incident)),'drMetadata'=>File.read(dr)}
    companion_bytes = JSON.pretty_generate(record) + "\n"
    lock = "#{output}.publish-lock"
    locked = false
    written = []
    begin
      Dir.mkdir(lock, 0700)
      locked = true
      if [output, companion].any? { |p| File.exist?(p) || File.symlink?(p) }
        raise Rejected, 'existing pair is incomplete or not regular' unless [output, companion].all? { |p| File.file?(p) && !File.symlink?(p) }
        raise Rejected, 'write-once capture differs; preserve and archive the original pair before a new capture' unless File.binread(output) == bytes && File.binread(companion) == companion_bytes
        return :unchanged
      end
      Tempfile.create(['.capture-', '.json'], parent) do |source_file|
        Tempfile.create(['.companion-', '.json'], parent) do |companion_file|
          [[source_file,bytes],[companion_file,companion_bytes]].each do |file, content|
            file.chmod(0600); file.binmode; file.write(content); file.flush; file.fsync
          end
          # Hard links are same-filesystem, atomic and never overwrite a raced target.
          # Readers require both files; companion-first cannot expose an unbound source.
          linker.call(companion_file.path, companion); written << companion
          linker.call(source_file.path, output); written << output
        end
      end
      :created
    rescue StandardError
      written.reverse_each { |p| File.unlink(p) }
      raise
    ensure
      Dir.rmdir(lock) if locked
    end
  end
end
