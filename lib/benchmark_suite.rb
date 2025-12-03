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
require_relative 'benchmark_discovery'

# BenchmarkSuite runs a collection of benchmarks and collects their results
class BenchmarkSuite
  BENCHMARKS_DIR = "benchmarks"
  RACTOR_CATEGORY = ["ractor"].freeze
  RACTOR_ONLY_CATEGORY = ["ractor-only"].freeze
  RACTOR_HARNESS = "harness-ractor"

  attr_reader :categories, :name_filters, :excludes, :out_path, :harness, :harness_explicit, :pre_init, :no_pinning, :force_pinning, :bench_dir

  def initialize(categories:, name_filters:, excludes: [], out_path:, harness:, harness_explicit: false, pre_init: nil, no_pinning: false, force_pinning: false)
    @categories = categories
    @name_filters = name_filters
    @excludes = excludes
    @out_path = out_path
    @harness = harness
    @harness_explicit = harness_explicit
    @pre_init = pre_init ? expand_pre_init(pre_init) : nil
    @no_pinning = no_pinning
    @force_pinning = force_pinning
    @bench_dir = BENCHMARKS_DIR
  end

  # Run all the benchmarks and record execution times
  # Returns [bench_data, bench_failures]
  def run(ruby:, ruby_description:)
    bench_data = {}
    bench_failures = {}

    benchmark_entries = discover_benchmarks
    env = benchmark_env(ruby)
    caller_json_path = ENV["RESULT_JSON_PATH"]

    benchmark_entries.each_with_index do |entry, idx|
      puts("Running benchmark \"#{entry.name}\" (#{idx+1}/#{benchmark_entries.length})")

      result_json_path = caller_json_path || File.join(out_path, "temp#{Process.pid}.json")
      cmd_prefix = base_cmd(ruby_description, entry.name)
      result = run_single_benchmark(entry.script_path, result_json_path, ruby, cmd_prefix, env, entry.name)

      if result[:success]
        bench_data[entry.name] = process_benchmark_result(result_json_path, result[:command], delete_file: !caller_json_path)
      else
        bench_failures[entry.name] = result[:status].exitstatus
        FileUtils.rm_f(result_json_path) unless caller_json_path
      end
    end

    [bench_data, bench_failures]
  end

  private

  def setup_benchmark_directories
    if @ractor_only
      @bench_dir = RACTOR_BENCHMARKS_DIR
      @ractor_bench_dir = RACTOR_BENCHMARKS_DIR
      @harness = RACTOR_HARNESS
      @categories = []
    else
      @bench_dir = BENCHMARKS_DIR
      @ractor_bench_dir = RACTOR_BENCHMARKS_DIR
    end
  end

  def process_benchmark_result(result_json_path, command, delete_file: true)
    JSON.parse(File.read(result_json_path)).tap do |json|
      json["command_line"] = command
      File.unlink(result_json_path) if delete_file
    end
  end

  def discover_benchmarks
    all_entries = discover_all_benchmark_entries
    directory_map = build_directory_map(all_entries)
    filter_benchmarks(all_entries, directory_map)
  end

  def discover_all_benchmark_entries
    discovery = BenchmarkDiscovery.new(bench_dir)
    { main: discovery.discover }
  end

  def build_directory_map(all_entries)
    all_entries[:main].each_with_object({}) do |entry, map|
      map[entry.name] = entry.directory
    end
  end

  def filter_benchmarks(all_entries, directory_map)
    filter_entries(
      all_entries[:main],
      categories: categories,
      name_filters: name_filters,
      excludes: excludes,
      directory_map: directory_map
    )
  end

  def filter_entries(entries, categories:, name_filters:, excludes:, directory_map:)
    filter = BenchmarkFilter.new(
      categories: categories,
      name_filters: name_filters,
      excludes: excludes,
      metadata: benchmarks_metadata,
      directory_map: directory_map
    )
    entries.select { |entry| filter.match?(entry.name) }
  end

  def run_single_benchmark(script_path, result_json_path, ruby, cmd_prefix, env, benchmark_name)
    # Fix for jruby/jruby#7394 in JRuby 9.4.2.0
    script_path = File.expand_path(script_path)

    # Save and restore ENV["RESULT_JSON_PATH"] to avoid polluting the environment
    # for subsequent runs (e.g., when running multiple executables)
    original_result_json_path = ENV["RESULT_JSON_PATH"]
    ENV["RESULT_JSON_PATH"] = result_json_path

    # Use per-benchmark default_harness if set, otherwise use global harness
    benchmark_harness = benchmark_harness_for(benchmark_name)

    # Set up the benchmarking command
    cmd = cmd_prefix + [
      *ruby,
      "-I", benchmark_harness,
      *pre_init,
      script_path,
    ].compact

    # Do the benchmarking
    result = BenchmarkRunner.check_call(cmd.shelljoin, env: env, raise_error: false)
    result[:command] = cmd.shelljoin
    result
  ensure
    if original_result_json_path
      ENV["RESULT_JSON_PATH"] = original_result_json_path
    else
      ENV.delete("RESULT_JSON_PATH")
    end
  end

  def benchmark_harness_for(benchmark_name)
    return harness if harness_explicit

    benchmark_meta = benchmarks_metadata[benchmark_name] || {}
    default = ractor_category_run? ? RACTOR_HARNESS : harness
    benchmark_meta.fetch('default_harness', default)
  end

  def benchmark_env(ruby)
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

  def benchmarks_metadata
    @benchmarks_metadata ||= YAML.load_file('benchmarks.yml')
  end

  # Check if running on Linux
  def linux?
    @linux ||= RbConfig::CONFIG['host_os'] =~ /linux/
  end

  # Set up the base command with CPU pinning if needed
  def base_cmd(ruby_description, benchmark_name)
    if linux?
      cmd = setarch_prefix

      # Pin the process to one given core to improve caching and reduce variance on CRuby
      # Other Rubies need to use multiple cores, e.g., for JIT threads
      if ruby_description.start_with?('ruby ') && should_pin?(benchmark_name)
        # The last few cores of Intel CPU may be slow E-Cores, so avoid using the last one.
        cpu = [(Etc.nprocessors / 2) - 1, 0].max
        cmd.concat(["taskset", "-c", "#{cpu}"])
      end

      cmd
    else
      []
    end
  end

  def should_pin?(benchmark_name)
    return false if no_pinning
    return true if force_pinning
    return false if ractor_category_run?

    benchmark_meta = benchmarks_metadata[benchmark_name] || {}
    !benchmark_meta["no_pinning"]
  end

  def ractor_category_run?
    categories == RACTOR_CATEGORY || categories == RACTOR_ONLY_CATEGORY
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
