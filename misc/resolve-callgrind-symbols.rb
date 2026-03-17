#!/usr/bin/env ruby
# frozen_string_literal: true

# Resolve JIT code addresses in a callgrind output file using a perf map file.
#
# Perf map files (typically /tmp/perf-<pid>.map) contain lines of the form:
#     <start_hex> <size_hex> <symbol_name>
#
# This script replaces hex addresses in fn= and cfn= lines in the callgrind
# output with the corresponding symbol names from the perf map.
#
# Usage:
#     ruby resolve-callgrind-symbols.rb <perf-map-file> <callgrind-file> [-o <output-file>] [--with-offset]
#
# If no output file is specified, the result is written to <callgrind-file>.resolved.

require "optparse"
require_relative "../harness-callgrind/callgrind-symbol-resolver"

options = {}
parser = OptionParser.new do |opts|
  opts.banner = "Usage: #{$PROGRAM_NAME} <perf-map-file> <callgrind-file> [options]"

  opts.on("-o", "--output PATH", "Output file path (default: <callgrind_file>.resolved)") do |v|
    options[:output] = v
  end

  opts.on("--with-offset", "Include offset within JIT region (e.g., \"name+0x1a\")") do
    options[:with_offset] = true
  end
end

parser.parse!

if ARGV.length < 2
  puts parser.help
  exit 1
end

perf_map_path = ARGV[0]
callgrind_path = ARGV[1]
output_path = options[:output] || "#{callgrind_path}.resolved"

puts "Parsing perf map: #{perf_map_path}"
entries = parse_perf_map(perf_map_path)
starts = entries.map { |e| e[0] }
puts "  Loaded #{entries.length} symbol entries"

puts "Processing callgrind file: #{callgrind_path}"

# If writing to a separate output file, copy first then resolve in place.
# If writing in place (user explicitly passed -o with the same path), resolve directly.
if output_path != callgrind_path
  require "fileutils"
  FileUtils.cp(callgrind_path, output_path)
end

resolved, unresolved = resolve_callgrind_file(
  output_path, entries, starts, with_offset: options[:with_offset]
)

puts "  Resolved:   #{resolved} function references"
puts "  Unresolved: #{unresolved} function references (no match in perf map)"
puts "  Output:     #{output_path}"
