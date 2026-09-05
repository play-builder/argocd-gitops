#!/usr/bin/env ruby
require_relative 'lib/publish-incident-capture'
begin
  abort 'candidate, output, incident and DR paths required' unless ARGV.length == 4
  result = IncidentCapture.publish(*ARGV)
  puts "Source/companion publication: #{result}; evidence grade is inherited, not generated here"
rescue StandardError => error
  warn "FAIL: #{error.message}"
  exit 1
end
