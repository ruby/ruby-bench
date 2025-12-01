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
  RACTOR_BENCHMARKS_DIR = "benchmarks-ractor"
  RACTOR_ONLY_CATEGORY = ["ractor-only"].freeze
  RACTOR_CATEGORY = ["ractor"].freeze
  RACTOR_HARNESS = "ractor"
  HARNESS_DIR = File.expand_path("../harness", __dir__)

  attr_reader :categories, :name_filters, :excludes, :out_path, :harness, :pre_init, :no_pinning, :bench_dir, :ractor_bench_dir

  def initialize(categories:, name_filters:, excludes: [], out_path:, harness:, pre_init: nil, no_pinning: false)
    @categories = categories
    @name_filters = name_filters
    @excludes = excludes
    @out_path = out_path
    @harness = harness
    @pre_init = pre_init ? expand_pre_init(pre_init) : nil
    @no_pinning = no_pinning
    @ractor_only = (categories == RACTOR_ONLY_CATEGORY)

    setup_benchmark_directories
    @harness_args = build_harness_args
  end

  # Run all the benchmarks and record execution times
  # Returns [bench_data, bench_failures]
  def run(ruby:, ruby_description:)
    bench_data = {}
    bench_failures = {}

    benchmark_entries = discover_benchmarks
    cmd_prefix = base_cmd(ruby_description)
    env = benchmark_env(ruby)

    benchmark_entries.each_with_index do |entry, idx|
      puts("Running benchmark \"#{entry.name}\" (#{idx+1}/#{benchmark_entries.length})")

      result_json_path = File.join(out_path, "temp#{Process.pid}.json")
      result = run_single_benchmark(entry.script_path, result_json_path, ruby, cmd_prefix, env)

      if result[:success]
        bench_data[entry.name] = process_benchmark_result(result_json_path, result[:command])
      else
        bench_failures[entry.name] = result[:status].exitstatus
      end
    end

    [bench_data, bench_failures]
  end

  private

  attr_reader :harness_args

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

  def process_benchmark_result(result_json_path, command)
    JSON.parse(File.read(result_json_path)).tap do |json|
      json["command_line"] = command
      File.unlink(result_json_path)
    end
  end

  def discover_benchmarks
    all_entries = discover_all_benchmark_entries
    directory_map = build_directory_map(all_entries)
    filter_benchmarks(all_entries, directory_map)
  end

  def discover_all_benchmark_entries
    main_discovery = BenchmarkDiscovery.new(bench_dir)
    main_entries = main_discovery.discover

    ractor_entries = if benchmark_ractor_directory?
      ractor_discovery = BenchmarkDiscovery.new(ractor_bench_dir)
      ractor_discovery.discover
    else
      []
    end

    { main: main_entries, ractor: ractor_entries }
  end

  def build_directory_map(all_entries)
    combined_entries = all_entries[:main] + all_entries[:ractor]
    combined_entries.each_with_object({}) do |entry, map|
      map[entry.name] = entry.directory
    end
  end

  def filter_benchmarks(all_entries, directory_map)
    main_benchmarks = filter_entries(
      all_entries[:main],
      categories: categories,
      name_filters: name_filters,
      excludes: excludes,
      directory_map: directory_map
    )

    if benchmark_ractor_directory?
      ractor_benchmarks = filter_entries(
        all_entries[:ractor],
        categories: [],
        name_filters: name_filters,
        excludes: excludes,
        directory_map: directory_map
      )
      main_benchmarks + ractor_benchmarks
    else
      main_benchmarks
    end
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

  def run_single_benchmark(script_path, result_json_path, ruby, cmd_prefix, env)
    # Fix for jruby/jruby#7394 in JRuby 9.4.2.0
    script_path = File.expand_path(script_path)

    # Set up the environment for the benchmarking command
    ENV["RESULT_JSON_PATH"] = result_json_path

    # Set up the benchmarking command
    cmd = cmd_prefix + [
      *ruby,
      *harness_args,
      *pre_init,
      script_path,
    ].compact

    # Do the benchmarking
    result = BenchmarkRunner.check_call(cmd.shelljoin, env: env, raise_error: false)
    result[:command] = cmd.shelljoin
    result
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

  def benchmark_ractor_directory?
    categories == RACTOR_CATEGORY
  end

  # Check if running on Linux
  def linux?
    @linux ||= RbConfig::CONFIG['host_os'] =~ /linux/
  end

  # Set up the base command with CPU pinning if needed
  def base_cmd(ruby_description)
    if linux?
      cmd = setarch_prefix

      # Pin the process to one given core to improve caching and reduce variance on CRuby
      # Other Rubies need to use multiple cores, e.g., for JIT threads
      if ruby_description.start_with?('ruby ') && !no_pinning
        # The last few cores of Intel CPU may be slow E-Cores, so avoid using the last one.
        cpu = [(Etc.nprocessors / 2) - 1, 0].max
        cmd.concat(["taskset", "-c", "#{cpu}"])
      end

      cmd
    else
      []
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

  # If harness is 'default', use default (no -r needed)
  # Otherwise use -r to load the specific harness file with full path
  def build_harness_args
    if harness == "default"
      []
    else
      harness_path = File.join(HARNESS_DIR, harness)
      ["-r", harness_path]
    end
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
