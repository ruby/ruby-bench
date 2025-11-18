# frozen_string_literal: true

require 'json'
require 'pathname'
require 'fileutils'
require 'shellwords'
require 'etc'
require 'yaml'
require 'rbconfig'
require_relative 'benchmark_filter'

# BenchmarkSuite runs a collection of benchmarks and collects their results
class BenchmarkSuite
  attr_reader :ruby, :ruby_description, :categories, :name_filters, :out_path, :harness, :pre_init, :no_pinning

  def initialize(ruby:, ruby_description:, categories:, name_filters:, out_path:, harness:, pre_init: nil, no_pinning: false)
    @ruby = ruby
    @ruby_description = ruby_description
    @categories = categories
    @name_filters = name_filters
    @out_path = out_path
    @harness = harness
    @pre_init = pre_init ? expand_pre_init(pre_init) : nil
    @no_pinning = no_pinning
  end

  # Run all the benchmarks and record execution times
  # Returns [bench_data, bench_failures]
  def run
    bench_data = {}
    bench_failures = {}

    bench_dir = "benchmarks"
    ractor_bench_dir = "benchmarks-ractor"

    if categories == ["ractor-only"]
      bench_dir = ractor_bench_dir
      @harness = "harness-ractor"
      @categories = []
    end

    bench_file_grouping = {}

    # Get the list of benchmark files/directories matching name filters
    filter = benchmark_filter(categories: categories, name_filters: name_filters)
    bench_file_grouping[bench_dir] = Dir.children(bench_dir).sort.filter do |entry|
      filter.match?(entry)
    end

    if categories == ["ractor"]
      # We ignore the category filter here because everything in the
      # benchmarks-ractor directory should be included when we're benchmarking the
      # Ractor category
      ractor_filter = benchmark_filter(categories: [], name_filters: name_filters)
      bench_file_grouping[ractor_bench_dir] = Dir.children(ractor_bench_dir).sort.filter do |entry|
        ractor_filter.match?(entry)
      end
    end

    bench_file_grouping.each do |bench_dir, bench_files|
      bench_files.each_with_index do |entry, idx|
        bench_name = entry.gsub('.rb', '')

        puts("Running benchmark \"#{bench_name}\" (#{idx+1}/#{bench_files.length})")

        # Path to the benchmark runner script
        script_path = File.join(bench_dir, entry)

        if !script_path.end_with?('.rb')
          script_path = File.join(script_path, 'benchmark.rb')
        end

        # Set up the environment for the benchmarking command
        result_json_path = File.join(out_path, "temp#{Process.pid}.json")
        ENV["RESULT_JSON_PATH"] = result_json_path

        # Set up the benchmarking command
        cmd = []
        if linux?
          cmd += setarch_prefix

          # Pin the process to one given core to improve caching and reduce variance on CRuby
          # Other Rubies need to use multiple cores, e.g., for JIT threads
          if ruby_description.start_with?('ruby ') && !no_pinning
            # The last few cores of Intel CPU may be slow E-Cores, so avoid using the last one.
            cpu = [(Etc.nprocessors / 2) - 1, 0].max
            cmd += ["taskset", "-c", "#{cpu}"]
          end
        end

        # Fix for jruby/jruby#7394 in JRuby 9.4.2.0
        script_path = File.expand_path(script_path)

        cmd += [
          *ruby,
          "-I", harness,
          *pre_init,
          script_path,
        ].compact

        # When the Ruby running this script is not the first Ruby in PATH, shell commands
        # like `bundle install` in a child process will not use the Ruby being benchmarked.
        # It overrides PATH to guarantee the commands of the benchmarked Ruby will be used.
        env = {}
        ruby_path = `#{ruby.shelljoin} -e 'print RbConfig.ruby' 2> #{File::NULL}`
        if ruby_path != RbConfig.ruby
          env["PATH"] = "#{File.dirname(ruby_path)}:#{ENV["PATH"]}"

          # chruby sets GEM_HOME and GEM_PATH in your shell. We have to unset it in the child
          # process to avoid installing gems to the version that is running run_benchmarks.rb.
          ["GEM_HOME", "GEM_PATH"].each do |var|
            env[var] = nil if ENV.key?(var)
          end
        end

        # Do the benchmarking
        result = BenchmarkRunner.check_call(cmd.shelljoin, env: env, raise_error: false)

        if result[:success]
          bench_data[bench_name] = JSON.parse(File.read(result_json_path)).tap do |json|
            json["command_line"] = cmd.shelljoin
            File.unlink(result_json_path)
          end
        else
          bench_failures[bench_name] = result[:status].exitstatus
        end

      end
    end

    [bench_data, bench_failures]
  end

  private

  def benchmark_filter(categories:, name_filters:)
    @benchmark_filter ||= {}
    key = [categories, name_filters]
    @benchmark_filter[key] ||= BenchmarkFilter.new(
      categories: categories,
      name_filters: name_filters,
      metadata: benchmarks_metadata
    )
  end

  def benchmarks_metadata
    @benchmarks_metadata ||= YAML.load_file('benchmarks.yml')
  end

  # Check if running on Linux
  def linux?
    RbConfig::CONFIG['host_os'] =~ /linux/
  end

  # Generate setarch prefix for Linux
  def setarch_prefix
    # Disable address space randomization (for determinism)
    prefix = ["setarch", `uname -m`.strip, "-R"]

    # Abort if we don't have permission (perhaps in a docker container).
    return [] unless system(*prefix, "true", out: File::NULL, err: File::NULL)

    prefix
  end

  # Resolve the pre_init file path into a form that can be required
  def expand_pre_init(path)
    path = Pathname.new(path)

    unless path.exist?
      puts "--with-pre-init called with non-existent file!"
      exit(-1)
    end

    if path.directory?
      puts "--with-pre-init called with a directory, please pass a .rb file"
      exit(-1)
    end

    library_name = path.basename(path.extname)
    load_path = path.parent.expand_path

    [
      "-I", load_path,
      "-r", library_name
    ]
  end
end
