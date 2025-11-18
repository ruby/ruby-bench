#!/usr/bin/env ruby

require 'pathname'
require 'fileutils'
require 'csv'
require 'json'
require 'shellwords'
require 'rbconfig'
require 'etc'
require 'yaml'
require_relative 'lib/cpu_config'
require_relative 'lib/benchmark_runner'
require_relative 'lib/benchmark_suite'
require_relative 'lib/table_formatter'
require_relative 'lib/argument_parser'
require_relative 'lib/results_table_builder'

args = ArgumentParser.parse(ARGV)

CPUConfig.configure_for_benchmarking(turbo: args.turbo)

# Create the output directory
FileUtils.mkdir_p(args.out_path)

ruby_descriptions = {}

# Benchmark with and without YJIT
bench_start_time = Time.now.to_f
bench_data = {}
bench_failures = {}
args.executables.each do |name, executable|
  ruby_descriptions[name] = `#{executable.shelljoin} -v`.chomp

  suite = BenchmarkSuite.new(
    ruby: executable,
    ruby_description: ruby_descriptions[name],
    categories: args.categories,
    name_filters: args.name_filters,
    out_path: args.out_path,
    harness: args.harness,
    pre_init: args.with_pre_init,
    no_pinning: args.no_pinning
  )
  bench_data[name], failures = suite.run
  # Make it easier to query later.
  bench_failures[name] = failures unless failures.empty?
end

bench_end_time = Time.now.to_f
bench_total_time = (bench_end_time - bench_start_time).to_i
puts("Total time spent benchmarking: #{bench_total_time}s")

if !bench_failures.empty?
  puts("Failed benchmarks: #{bench_failures.map { |k, v| v.size }.sum}")
end

puts

# Build results table
all_names = args.executables.keys
base_name, *other_names = all_names
builder = ResultsTableBuilder.new(
  executable_names: all_names,
  bench_data: bench_data,
  include_rss: args.rss
)
table, format = builder.build

output_path = nil
if args.out_override
  output_path = args.out_override
else
  # If no out path is specified, find a free file index for the output files
  file_no = BenchmarkRunner.free_file_no(args.out_path)
  output_path = File.join(args.out_path, "output_%03d" % file_no)
end

# Save the raw data as JSON
out_json_path = output_path + ".json"
File.open(out_json_path, "w") do |file|
  out_data = {
    metadata: ruby_descriptions,
    raw_data: bench_data,
  }
  json_str = JSON.generate(out_data)
  file.write json_str
end

# Save data as CSV so we can produce tables/graphs in a spreasheet program
# NOTE: we don't do any number formatting for the output file because
#       we don't want to lose any precision
output_rows = []
ruby_descriptions.each do |key, value|
  output_rows.append([key, value])
end
output_rows.append([])
output_rows.concat(table)
out_tbl_path = output_path + ".csv"
CSV.open(out_tbl_path, "wb") do |csv|
  output_rows.each do |row|
    csv << row
  end
end

# Save the output in a text file that we can easily refer to
output_str = ""
ruby_descriptions.each do |key, value|
  output_str << "#{key}: #{value}\n"
end
output_str += "\n"
output_str += TableFormatter.new(table, format, bench_failures).to_s + "\n"
unless other_names.empty?
  output_str << "Legend:\n"
  other_names.each do |name|
    output_str << "- #{name} 1st itr: ratio of #{base_name}/#{name} time for the first benchmarking iteration.\n"
    output_str << "- #{base_name}/#{name}: ratio of #{base_name}/#{name} time. Higher is better for #{name}. Above 1 represents a speedup.\n"
  end
end
out_txt_path = output_path + ".txt"
File.open(out_txt_path, "w") { |f| f.write output_str }

# Print the table to the console, with numbers truncated
puts(output_str)

# Print JSON and PNG file names
puts
puts "Output:"
puts out_json_path
if args.graph
  require_relative 'misc/graph'
  out_graph_path = output_path + ".png"
  render_graph(out_json_path, out_graph_path)
  puts out_graph_path
end

if !bench_failures.empty?
  puts "\nFailed benchmarks:"
  bench_failures.each do |name, data|
    puts "  #{name}: #{data.keys.join(", ")}"
  end
  exit(1)
end
