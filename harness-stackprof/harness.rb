# frozen_string_literal: true

# Profile the benchmark (ignoring initialization code) with stackprof.
# Customize stackprof options with an env var of STACKPROF_OPTS='key:value,...'.
# Usage:
# STACKPROF_OPTS='mode:object' MIN_BENCH_TIME=0 MIN_BENCH_ITRS=1 ruby -v -I harness-stackprof benchmarks/.../benchmark.rb
# STACKPROF_OPTS='mode:cpu,interval:10' MIN_BENCH_TIME=1 MIN_BENCH_ITRS=10 ruby -v -I harness-stackprof benchmarks/.../benchmark.rb

require_relative "../harness/harness-common"
require_relative "../harness/harness-extra"

ensure_global_gem("stackprof")

# Default to collecting more information so that more post-processing options are
# available (like generating a flamegraph).
DEFAULTS = {
  aggregate: true,
  raw: true,
}.freeze

# Convert strings of "true" or "false" to their actual boolean values (or raise).
BOOLS = {"true" => true, "false" => false}
def bool!(val)
  case val
  when TrueClass, FalseClass
    # Respect values that are already booleans so that we can specify defaults intuitively.
    val
  else
    BOOLS.fetch(val) { raise ArgumentError, "must be 'true' or 'false'" }
  end
end

# Parse the string of "key:value,..." into a hash that we can pass to stackprof.
def parse_opts_string(str)
  return {} unless str

  str.split(/,/).map { |x| x.strip.split(/[=:]/, 2) }.to_h.transform_keys(&:to_sym)
end

# Get options for stackprof from env var and convert strings to the types stackprof expects.
def stackprof_opts
  opts = DEFAULTS.merge(parse_opts_string(ENV['STACKPROF_OPTS']))

  bool = method(:bool!)

  # Use {key: conversion_proc_or_sym} to convert present options to their necessary types.
  {
    aggregate: bool,
    raw: bool,
    mode: :to_sym,
    interval: :to_i,
  }.each do |key, method|
    next unless opts.key?(key)

    method = proc(&method) if method.is_a?(Symbol)
    opts[key] = method.call(opts[key])
  rescue => error
    raise ArgumentError, "Option '#{key}' failed to convert: #{error}"
  end

  opts
end

def run_benchmark(n, **, &block)
  require "stackprof"

  opts = stackprof_opts
  prefix = "stackprof"
  prefix = "#{prefix}-#{opts[:mode]}" if opts[:mode]

  out = output_file_path(prefix: prefix, ext: "dump")
  StackProf.run(out: out, **opts) do
    run_enough_to_profile(n, &block)
  end

  # Show the basic textual report.
  gem_exe("stackprof", "--text", out)
  # Print the file path at the end to make it easy to copy the file name
  # and use it for further analysis.
  puts "Stackprof dump file:\n#{out}"

  # Dummy results to satisfy ./run_benchmarks.rb
  return_results([0], [1.0]) if ENV['RESULT_JSON_PATH']
end
