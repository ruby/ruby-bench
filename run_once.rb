#!/usr/bin/env ruby
# frozen_string_literal: true

# Script to run a single benchmark once
# Provides a clean interface for running benchmarks with different harnesses.
# Examples:
#   ./run_once.rb benchmarks/railsbench/benchmark.rb
#   ./run_once.rb --harness=once benchmarks/fib.rb
#   ./run_once.rb --harness=stackprof benchmarks/fib.rb
#   ./run_once.rb -- --yjit-stats benchmarks/railsbench/benchmark.rb
#   ./run_once.rb --harness=default -- --yjit benchmarks/fib.rb

require 'optparse'
require 'shellwords'

# Parse options
harness = nil
ruby_args = []
benchmark_file = nil

parser = OptionParser.new do |opts|
  opts.banner = "Usage: #{$0} [options] [--] [ruby-options] BENCHMARK_FILE"

  opts.on("--harness=HARNESS", "Harness to use (default: default, options: once, bips, perf, ractor, stackprof, vernier, warmup, stats, continuous, chain, mplr)") do |h|
    harness = h
  end

  opts.on("-h", "--help", "Show this help message") do
    puts opts
    exit
  end
end

# Parse our options - this will stop at '--' or first non-option argument
begin
  parser.parse!
rescue OptionParser::InvalidOption => e
  puts "Error: #{e.message}"
  puts parser
  exit 1
end

# After parsing, ARGV contains remaining args (Ruby options + benchmark file)
ARGV.each do |arg|
  if arg.end_with?('.rb') && !benchmark_file
    benchmark_file = arg
  else
    ruby_args << arg
  end
end

if !benchmark_file
  puts "Error: No benchmark file specified"
  puts parser
  exit 1
end

unless File.exist?(benchmark_file)
  puts "Error: Benchmark file not found: #{benchmark_file}"
  exit 1
end

# Automatically detect ractor benchmarks
if !harness && benchmark_file.include?('benchmarks-ractor/')
  harness = 'ractor'
end

# Build the command
harness_dir = File.expand_path('harness', __dir__)
harness_args = if harness && harness != 'default'
  harness_path = File.join(harness_dir, harness)
  unless File.exist?("#{harness_path}.rb")
    puts "Error: Harness not found: #{harness}"
    puts "Available harnesses: #{Dir.glob("#{harness_dir}/*.rb").map { |f| File.basename(f, '.rb') }.join(', ')}"
    exit 1
  end
  ['-r', harness_path]
else
  []
end

# Set environment for running once
ENV['WARMUP_ITRS'] = '0'
ENV['MIN_BENCH_ITRS'] = '1'
ENV['MIN_BENCH_TIME'] = '0'

# Build and execute the command
cmd = ['ruby', *ruby_args, *harness_args, benchmark_file]

exec(*cmd)
