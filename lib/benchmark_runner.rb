# frozen_string_literal: true

require 'csv'
require 'json'
require 'rbconfig'

# Extracted helper methods from run_benchmarks.rb for testing
module BenchmarkRunner
  module_function

  # Find the first available file number for output files
  def free_file_no(directory)
    (1..).each do |file_no|
      out_path = File.join(directory, "output_%03d.csv" % file_no)
      return file_no unless File.exist?(out_path)
    end
  end

  # Sort benchmarks with headlines first, then others, then micro
  def sort_benchmarks(bench_names, metadata)
    headline_benchmarks = metadata.select { |_, meta| meta['category'] == 'headline' }.keys
    micro_benchmarks = metadata.select { |_, meta| meta['category'] == 'micro' }.keys

    headline_names, bench_names = bench_names.partition { |name| headline_benchmarks.include?(name) }
    micro_names, other_names = bench_names.partition { |name| micro_benchmarks.include?(name) }
    headline_names.sort + other_names.sort + micro_names.sort
  end

  # Checked system - error or return info if the command fails
  def check_call(command, env: {}, raise_error: true, quiet: false)
    puts("+ #{command}") unless quiet

    result = {}

    result[:success] = system(env, command)
    result[:status] = $?

    unless result[:success]
      puts "Command #{command.inspect} failed with exit code #{result[:status].exitstatus} in directory #{Dir.pwd}"
      raise RuntimeError.new if raise_error
    end

    result
  end
end
