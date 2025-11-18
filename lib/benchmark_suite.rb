# frozen_string_literal: true

require 'json'
require 'pathname'
require 'fileutils'
require 'shellwords'
require 'etc'
require 'yaml'
require 'rbconfig'
require_relative 'benchmark_filter'
require_relative 'benchmark_runner'

# BenchmarkSuite runs a collection of benchmarks and collects their results
class BenchmarkSuite
  BENCHMARKS_DIR = "benchmarks"
  RACTOR_BENCHMARKS_DIR = "benchmarks-ractor"
  RACTOR_ONLY_CATEGORY = ["ractor-only"].freeze
  RACTOR_CATEGORY = ["ractor"].freeze
  RACTOR_HARNESS = "harness-ractor"

  attr_reader :ruby, :ruby_description, :categories, :name_filters, :out_path, :harness, :pre_init, :no_pinning, :bench_dir, :ractor_bench_dir

  def initialize(ruby:, ruby_description:, categories:, name_filters:, out_path:, harness:, pre_init: nil, no_pinning: false)
    @ruby = ruby
    @ruby_description = ruby_description
    @categories = categories
    @name_filters = name_filters
    @out_path = out_path
    @harness = harness
    @pre_init = pre_init ? expand_pre_init(pre_init) : nil
    @no_pinning = no_pinning
    @ractor_only = (categories == RACTOR_ONLY_CATEGORY)

    @bench_dir = BENCHMARKS_DIR
    @ractor_bench_dir = RACTOR_BENCHMARKS_DIR

    if @ractor_only
      @bench_dir = @ractor_bench_dir
      @harness = RACTOR_HARNESS
      @categories = []
    end
  end

  # Run all the benchmarks and record execution times
  # Returns [bench_data, bench_failures]
  def run
    bench_data = {}
    bench_failures = {}

    bench_file_grouping.each do |bench_dir, bench_files|
      bench_files.each_with_index do |entry, idx|
        bench_name = entry.delete_suffix('.rb')

        puts("Running benchmark \"#{bench_name}\" (#{idx+1}/#{bench_files.length})")

        result_json_path = File.join(out_path, "temp#{Process.pid}.json")
        result = run_single_benchmark(bench_dir, entry, result_json_path)

        if result[:success]
          bench_data[bench_name] = process_benchmark_result(result_json_path, result[:command])
        else
          bench_failures[bench_name] = result[:status].exitstatus
        end
      end
    end

    [bench_data, bench_failures]
  end

  private

  def process_benchmark_result(result_json_path, command)
    JSON.parse(File.read(result_json_path)).tap do |json|
      json["command_line"] = command
      File.unlink(result_json_path)
    end
  end

  def run_single_benchmark(bench_dir, entry, result_json_path)
    # Path to the benchmark runner script
    script_path = File.join(bench_dir, entry)

    unless script_path.end_with?('.rb')
      script_path = File.join(script_path, 'benchmark.rb')
    end

    # Fix for jruby/jruby#7394 in JRuby 9.4.2.0
    script_path = File.expand_path(script_path)

    # Set up the environment for the benchmarking command
    ENV["RESULT_JSON_PATH"] = result_json_path

    # Set up the benchmarking command
    cmd = base_cmd + [
      *ruby,
      "-I", harness,
      *pre_init,
      script_path,
    ].compact

    # Do the benchmarking
    result = BenchmarkRunner.check_call(cmd.shelljoin, env: benchmark_env, raise_error: false)
    result[:command] = cmd.shelljoin
    result
  end

  def benchmark_env
    @benchmark_env ||= begin
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

      env
    end
  end

  def bench_file_grouping
    grouping = {}

    # Get the list of benchmark files/directories matching name filters
    grouping[bench_dir] = filtered_bench_entries(bench_dir, main_benchmark_filter)

    if benchmark_ractor_directory?
      # We ignore the category filter here because everything in the
      # benchmarks-ractor directory should be included when we're benchmarking the
      # Ractor category
      grouping[ractor_bench_dir] = filtered_bench_entries(ractor_bench_dir, ractor_benchmark_filter)
    end

    grouping
  end

  def main_benchmark_filter
    @main_benchmark_filter ||= BenchmarkFilter.new(
      categories: categories,
      name_filters: name_filters,
      metadata: benchmarks_metadata
    )
  end

  def ractor_benchmark_filter
    @ractor_benchmark_filter ||= BenchmarkFilter.new(
      categories: [],
      name_filters: name_filters,
      metadata: benchmarks_metadata
    )
  end

  def benchmarks_metadata
    @benchmarks_metadata ||= YAML.load_file('benchmarks.yml')
  end

  def filtered_bench_entries(dir, filter)
    Dir.children(dir).sort.filter do |entry|
      filter.match?(entry)
    end
  end

  def benchmark_ractor_directory?
    categories == RACTOR_CATEGORY
  end

  # Check if running on Linux
  def linux?
    @linux ||= RbConfig::CONFIG['host_os'] =~ /linux/
  end

  # Set up the base command with CPU pinning if needed
  def base_cmd
    @base_cmd ||= begin
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

      cmd
    end
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
