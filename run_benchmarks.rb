#!/usr/bin/env ruby

require 'optparse'
require 'ostruct'
require 'pathname'
require 'fileutils'
require 'shellwords'
require 'csv'
require 'json'
require 'rbconfig'
require 'etc'
require 'yaml'
require_relative 'misc/stats'
require_relative 'lib/benchmark_runner'
require_relative 'lib/table_formatter'
require_relative 'lib/benchmark_filter'

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

def check_output(*command)
  IO.popen(*command, &:read)
end

def have_yjit?(ruby)
  ruby_version = check_output("#{ruby} -v --yjit", err: File::NULL).strip
  ruby_version.downcase.include?("yjit")
end

# Disable Turbo Boost while running benchmarks. Maximize the CPU frequency.
def set_bench_config(turbo:)
  # sudo requires the flag '-S' in order to take input from stdin
  if File.exist?('/sys/devices/system/cpu/intel_pstate') # Intel
    unless intel_no_turbo? || turbo
      check_call("sudo -S sh -c 'echo 1 > /sys/devices/system/cpu/intel_pstate/no_turbo'")
      at_exit { check_call("sudo -S sh -c 'echo 0 > /sys/devices/system/cpu/intel_pstate/no_turbo'", quiet: true) }
    end
    # Disabling Turbo Boost reduces the CPU frequency, so this should be run after that.
    check_call("sudo -S sh -c 'echo 100 > /sys/devices/system/cpu/intel_pstate/min_perf_pct'") unless intel_perf_100pct?
  elsif File.exist?('/sys/devices/system/cpu/cpufreq/boost') # AMD
    unless amd_no_boost? || turbo
      check_call("sudo -S sh -c 'echo 0 > /sys/devices/system/cpu/cpufreq/boost'")
      at_exit { check_call("sudo -S sh -c 'echo 1 > /sys/devices/system/cpu/cpufreq/boost'", quiet: true) }
    end
    check_call("sudo -S cpupower frequency-set -g performance") unless performance_governor?
  end
end

def check_pstate(turbo:)
  if File.exist?('/sys/devices/system/cpu/intel_pstate') # Intel
    unless turbo || intel_no_turbo?
      puts("You forgot to disable turbo:")
      puts("  sudo sh -c 'echo 1 > /sys/devices/system/cpu/intel_pstate/no_turbo'")
      exit(-1)
    end

    unless intel_perf_100pct?
      puts("You forgot to set the min perf percentage to 100:")
      puts("  sudo sh -c 'echo 100 > /sys/devices/system/cpu/intel_pstate/min_perf_pct'")
      exit(-1)
    end
  elsif File.exist?('/sys/devices/system/cpu/cpufreq/boost') # AMD
    unless turbo || amd_no_boost?
      puts("You forgot to disable boost:")
      puts("  sudo sh -c 'echo 0 > /sys/devices/system/cpu/cpufreq/boost'")
      exit(-1)
    end

    unless performance_governor?
      puts("You forgot to set the performance governor:")
      puts("  sudo cpupower frequency-set -g performance")
      exit(-1)
    end
  end
end

def intel_no_turbo?
  File.read('/sys/devices/system/cpu/intel_pstate/no_turbo').strip == '1'
end

def intel_perf_100pct?
  File.read('/sys/devices/system/cpu/intel_pstate/min_perf_pct').strip == '100'
end

def amd_no_boost?
  File.read('/sys/devices/system/cpu/cpufreq/boost').strip == '0'
end

def performance_governor?
  Dir.glob('/sys/devices/system/cpu/cpu*/cpufreq/scaling_governor').all? do |governor|
    File.read(governor).strip == 'performance'
  end
end

def mean(values)
  Stats.new(values).mean
end

def stddev(values)
  Stats.new(values).stddev
end

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

def sort_benchmarks(bench_names)
  BenchmarkRunner.sort_benchmarks(bench_names, benchmarks_metadata)
end

def setarch_prefix
  BenchmarkRunner.setarch_prefix
end

# Run all the benchmarks and record execution times
def run_benchmarks(ruby:, ruby_description:, categories:, name_filters:, out_path:, harness:, pre_init:, no_pinning:)
  bench_data = {}
  bench_failures = {}

  bench_dir = "benchmarks"
  ractor_bench_dir = "benchmarks-ractor"

  if categories == ["ractor-only"]
    bench_dir = ractor_bench_dir
    harness = "harness-ractor"
    categories = []
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

  if pre_init
    pre_init = BenchmarkRunner.expand_pre_init(pre_init)
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
      if BenchmarkRunner.os == :linux
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
      result = check_call(cmd.shelljoin, env: env, raise_error: false)

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

# Default values for command-line arguments
args = OpenStruct.new({
  executables: {},
  out_path: File.expand_path("./data"),
  out_override: nil,
  harness: "harness",
  yjit_opts: "",
  categories: [],
  name_filters: [],
  rss: false,
  graph: false,
  no_pinning: false,
  turbo: false,
  skip_yjit: false,
})

OptionParser.new do |opts|
  opts.on("-e=NAME::RUBY_PATH OPTIONS", "ruby executable and options to be benchmarked (default: interp, yjit)") do |v|
    v.split(";").each do |name_executable|
      name, executable = name_executable.split("::", 2)
      if executable.nil?
        executable = name # allow skipping `NAME::`
      end
      args.executables[name] = executable.shellsplit
    end
  end

  opts.on("--chruby=NAME::VERSION OPTIONS", "ruby version under chruby and options to be benchmarked") do |v|
    v.split(";").each do |name_version|
      name, version = name_version.split("::", 2)
      # Convert `ruby --yjit` to `ruby::ruby --yjit`
      if version.nil?
        version = name
        name = name.shellsplit.first
      end
      version, *options = version.shellsplit
      rubies_dir = ENV["RUBIES_DIR"] || "#{ENV["HOME"]}/.rubies"
      unless executable = ["/opt/rubies/#{version}/bin/ruby", "#{rubies_dir}/#{version}/bin/ruby"].find { |path| File.executable?(path) }
        abort "Cannot find '#{version}' in /opt/rubies or #{rubies_dir}"
      end
      args.executables[name] = [executable, *options]
    end
  end

  opts.on("--out_path=OUT_PATH", "directory where to store output data files") do |v|
    args.out_path = v
  end

  opts.on("--out-name=OUT_FILE", "write exactly this output file plus file extension, ignoring directories, overwriting if necessary") do |v|
    args.out_override = v
  end

  opts.on("--category=headline,other,micro,ractor", "when given, only benchmarks with specified categories will run") do |v|
    args.categories += v.split(",")
    if args.categories == ["ractor"]
      args.harness = "harness-ractor"
    end
  end

  opts.on("--headline", "when given, headline benchmarks will be run") do
    args.categories += ["headline"]
  end

  opts.on("--name_filters=x,y,z", Array, "when given, only benchmarks with names that contain one of these strings will run") do |list|
    args.name_filters = list
  end

  opts.on("--skip-yjit", "Don't run with yjit after interpreter") do
    args.skip_yjit = true
  end

  opts.on("--harness=HARNESS_DIR", "which harness to use") do |v|
    v = "harness-#{v}" unless v.start_with?('harness')
    args.harness = v
  end

  opts.on("--warmup=N", "the number of warmup iterations for the default harness (default: 15)") do |n|
    ENV["WARMUP_ITRS"] = n
  end

  opts.on("--bench=N", "the number of benchmark iterations for the default harness (default: 10). Also defaults MIN_BENCH_TIME to 0.") do |n|
    ENV["MIN_BENCH_ITRS"] = n
    ENV["MIN_BENCH_TIME"] ||= "0"
  end

  opts.on("--once", "benchmarks only 1 iteration with no warmup for the default harness") do
    ENV["WARMUP_ITRS"] = "0"
    ENV["MIN_BENCH_ITRS"] = "1"
    ENV["MIN_BENCH_TIME"] = "0"
  end

  opts.on("--yjit-stats=STATS", "print YJIT stats at each iteration for the default harness") do |str|
    ENV["YJIT_BENCH_STATS"] = str
  end

  opts.on("--zjit-stats=STATS", "print ZJIT stats at each iteration for the default harness") do |str|
    ENV["ZJIT_BENCH_STATS"] = str
  end

  opts.on("--yjit_opts=OPT_STRING", "string of command-line options to run YJIT with (ignored if you use -e)") do |str|
    args.yjit_opts=str
  end

  opts.on("--with_pre-init=PRE_INIT_FILE",
          "a file to require before each benchmark run, so settings can be tuned (eg. enable/disable GC compaction)") do |str|
    args.with_pre_init = str
  end

  opts.on("--rss", "show RSS in the output (measured after benchmark iterations)") do
    args.rss = true
  end

  opts.on("--graph", "generate a graph image of benchmark results") do
    args.graph = true
  end

  opts.on("--no-pinning", "don't pin ruby to a specific CPU core") do
    args.no_pinning = true
  end

  opts.on("--turbo", "don't disable CPU turbo boost") do
    args.turbo = true
  end
end.parse!

# Remaining arguments are treated as benchmark name filters
if ARGV.length > 0
  args.name_filters += ARGV
end

# If -e is not specified, benchmark the current Ruby. Compare it with YJIT if available.
if args.executables.empty?
  if have_yjit?(RbConfig.ruby) && !args.skip_yjit
    args.executables["interp"] = [RbConfig.ruby]
    args.executables["yjit"] = [RbConfig.ruby, "--yjit", *args.yjit_opts.shellsplit]
  else
    args.executables["ruby"] = [RbConfig.ruby]
  end
end

# Disable CPU frequency scaling
set_bench_config(turbo: args.turbo)

# Check pstate status
check_pstate(turbo: args.turbo)

# Create the output directory
FileUtils.mkdir_p(args.out_path)

ruby_descriptions = {}
args.executables.each do |name, executable|
  ruby_descriptions[name] = check_output([*executable, "-v"]).chomp
end

# Benchmark with and without YJIT
bench_start_time = Time.now.to_f
bench_data = {}
bench_failures = {}
args.executables.each do |name, executable|
  bench_data[name], failures = run_benchmarks(
    ruby: executable,
    ruby_description: ruby_descriptions[name],
    categories: args.categories,
    name_filters: args.name_filters,
    out_path: args.out_path,
    harness: args.harness,
    pre_init: args.with_pre_init,
    no_pinning: args.no_pinning
  )
  # Make it easier to query later.
  bench_failures[name] = failures unless failures.empty?
end

bench_end_time = Time.now.to_f
# Get keys from all rows in case a benchmark failed for only some executables.
bench_names = sort_benchmarks(bench_data.map { |k, v| v.keys }.flatten.uniq)

bench_total_time = (bench_end_time - bench_start_time).to_i
puts("Total time spent benchmarking: #{bench_total_time}s")

if !bench_failures.empty?
  puts("Failed benchmarks: #{bench_failures.map { |k, v| v.size }.sum}")
end

puts

# Table for the data we've gathered
all_names = args.executables.keys
base_name, *other_names = all_names
table  = [["bench"]]
format = ["%s"]
all_names.each do |name|
  table[0] += ["#{name} (ms)", "stddev (%)"]
  format   += ["%.1f",         "%.1f"]
  if args.rss
    table[0] += ["RSS (MiB)"]
    format   += ["%.1f"]
  end
end
other_names.each do |name|
  table[0] += ["#{name} 1st itr"]
  format   += ["%.3f"]
end
other_names.each do |name|
  table[0] += ["#{base_name}/#{name}"]
  format   += ["%.3f"]
end

# Format the results table
bench_names.each do |bench_name|
  # Skip this bench_name if we failed to get data for any of the executables.
  next unless bench_data.all? { |(_k, v)| v[bench_name] }

  t0s = all_names.map { |name| (bench_data[name][bench_name]['warmup'][0] || bench_data[name][bench_name]['bench'][0]) * 1000.0 }
  times_no_warmup = all_names.map { |name| bench_data[name][bench_name]['bench'].map { |v| v * 1000.0 } }
  rsss = all_names.map { |name| bench_data[name][bench_name]['rss'] / 1024.0 / 1024.0 }

  base_t0, *other_t0s = t0s
  base_t, *other_ts = times_no_warmup
  base_rss, *other_rsss = rsss

  ratio_1sts = other_t0s.map { |other_t0| base_t0 / other_t0 }
  ratios = other_ts.map { |other_t| mean(base_t) / mean(other_t) }

  row = [bench_name, mean(base_t), 100 * stddev(base_t) / mean(base_t)]
  row << base_rss if args.rss
  other_ts.zip(other_rsss).each do |other_t, other_rss|
    row += [mean(other_t), 100 * stddev(other_t) / mean(other_t)]
    row << other_rss if args.rss
  end

  row += ratio_1sts + ratios

  table << row
end

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
