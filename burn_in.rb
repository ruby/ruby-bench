#!/usr/bin/env ruby

require 'etc'
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
require 'open3'

# Default values for command-line arguments
args = OpenStruct.new({
  logs_path: "./logs_burn_in",
  delete_old_logs: false,
  num_procs: Etc.nprocessors,
  num_long_runs: 4,
  categories: ['headline', 'other'],
  no_yjit: false,
})

# Parse the command-line options
OptionParser.new do |opts|
  opts.on("--logs_path=OUT_PATH", "directory where to store output data files") do |v|
    args.logs_path = v
  end

  opts.on("--delete_old_logs") do
    args.delete_old_logs = true
  end

  opts.on("--num_procs=N", "number of processes to use in total") do |v|
    args.num_procs = v.to_i
  end

  opts.on("--num_long_runs=N", "number of processes to use for long runs") do |v|
    args.num_long_runs = v.to_i
  end

  opts.on("--category=headline,other,micro,ractor,ractor-only", "when given, only benchmarks with specified categories will run") do |v|
    args.categories = v.split(",")
  end

  opts.on("--no_yjit", "when given, test with the CRuby interpreter, without enabling YJIT") do
    args.no_yjit = true
  end
end.parse!

def free_file_path(parent_dir, name_prefix)
  (1..).each do |file_no|
    out_path = File.join(parent_dir, "#{name_prefix}_%03d.txt" % file_no)
    if !File.exist?(out_path)
      return out_path
    end
  end
end

def run_benchmark(bench_id, no_yjit, logs_path, run_time, ruby_version)
  # Determine the path to the benchmark script
  bench_name = bench_id.sub('ractor/', '')
  bench_dir, harness = if bench_name == bench_id
    ['benchmarks', 'default']
  else
    ['benchmarks-ractor', 'ractor']
  end

  script_path = File.join(bench_dir, bench_name, 'benchmark.rb')
  if not File.exist?(script_path)
    script_path = File.join(bench_dir, bench_name + '.rb')
  end

  # Assemble random environment variable options to test
  test_env_vars = {}
  if rand < 0.5
    test_env_vars["RUBY_GC_AUTO_COMPACT"] = "1"
  end

  env = {
    "WARMUP_ITRS"=> "0",
    "MIN_BENCH_TIME"=> run_time.to_s,
    "RUST_BACKTRACE"=> "1",
  }
  env.merge!(test_env_vars)

  # Assemble random command-line options to test
  if no_yjit
    test_options = []
  else
    test_options = [
      "--yjit-call-threshold=#{[1, 2, 10, 30].sample()}",
      "--yjit-cold-threshold=#{[1, 2, 5, 10, 500, 50_000].sample()}",
      [
        "--yjit-mem-size=#{[1, 2, 3, 4, 5, 10, 64, 128].sample()}",
        "--yjit-exec-mem-size=#{[1, 2, 3, 4, 5, 10, 64, 128].sample()}",
      ].sample(),
      ['--yjit-code-gc', nil].sample(),
      ['--yjit-perf', nil].sample(),
      ['--yjit-stats', nil].sample(),
      ['--yjit-log=/dev/null', nil].sample(),
    ].compact
  end

  # Assemble the command string
  cmd = [
    'ruby',
    *test_options,
    "-Iharness",
    "-r#{harness}",
    script_path,
  ].compact
  cmd_str = cmd.shelljoin

  # Prepend the tested environment variables to the command string
  # that we show to the user. We produce this separate command string
  # because capture2e doesn't support this syntax.
  user_cmd_str = cmd_str.dup
  test_env_vars.each do |name, value|
    user_cmd_str = "export #{name}=#{value} && " + user_cmd_str
  end

  puts "pid #{Process.pid} running benchmark #{bench_name}:"
  puts user_cmd_str
  output, status = Open3.capture2e(env, cmd_str)

  # If we got an error
  if !status.success?
    # Lobsters can run into connection errors with multiprocessing (port already taken, etc.), ignore that
    if bench_name == "lobsters" && output.include?("HTTP status is")
      return false
    end

    # Hexapdf can run into errors due to multiprocessing due to filesystem side-effects, ignore that
    if bench_name == "hexapdf" && output.include?("Incorrect size")
      return false
    end

    puts "ERROR"

    # Write command executed and output
    out_path = free_file_path(logs_path, "error_#{bench_name.gsub('/', '_')}")
    puts "writing output file #{out_path}"
    contents = ruby_version + "\n\n" + "pid #{status.pid}\n" + user_cmd_str + "\n\n" + output
    File.write(out_path, contents)

    # Error
    return true
  end

  # No error
  return false
end

def test_loop(bench_names, no_yjit, logs_path, run_time, ruby_version)
  error_found = false

  while true
    bench_name = bench_names.sample()
    error = run_benchmark(bench_name, no_yjit, logs_path, run_time, ruby_version)
    error_found ||= error

    if error_found
      puts "ERROR ENCOUNTERED"
    end
  end
end

# Create the output directory
if Dir.exist?(args.logs_path)
  if args.delete_old_logs
    FileUtils.rm_r(args.logs_path)
  else
    puts("Logs directory already exists. Move or delete #{args.logs_path} before running.")
    exit(-1)
  end
end
FileUtils.mkdir_p(args.logs_path)

# Get Ruby version string
ruby_version = IO.popen("ruby -v --yjit", &:read).strip
puts ruby_version

# Check that YJIT is available
if !ruby_version.include?("+YJIT")
  puts("Ruby version string doesn't include +YJIT. You may want to run `chruby ruby-yjit`.")
  exit(-1)
end

# Check if debug info is included in Ruby binary (this only works on Linux, not macOS)
output = IO.popen("file `which ruby`", &:read).strip
if !output.include?("debug_info")
  puts("WARNING: could not detect debug info in ruby binary! You may want to rebuild in dev mode so you can produce useful core dumps!")
  puts()
  sleep(10)
end

# Extract the names of benchmarks in the categories we want
metadata = YAML.load_file('benchmarks.yml')
bench_names = []

if args.categories.include?('ractor-only')
  # Only include benchmarks with ractor/ prefix (from benchmarks-ractor directory)
  bench_names = metadata.keys.select { |name| name.start_with?('ractor/') }
elsif args.categories.include?('ractor')
  # Include both ractor/ prefixed benchmarks and those with ractor: true
  metadata.each do |name, entry|
    if name.start_with?('ractor/') || entry['ractor']
      bench_names << name
    end
  end

  # Also include regular category benchmarks if other categories are specified
  if args.categories.any? { |cat| ['headline', 'other', 'micro'].include?(cat) }
    metadata.each do |name, entry|
      category = entry.fetch('category', 'other')
      if args.categories.include?(category) && !bench_names.include?(name)
        bench_names << name
      end
    end
  end
else
  # Regular category filtering
  metadata.each do |name, entry|
    category = entry.fetch('category', 'other')
    if args.categories.include?(category)
      bench_names << name
    end
  end
end

bench_names.sort!

# Fork the test processes
puts "num processes: #{args.num_procs}"
args.num_procs.times do |i|
  pid = Process.fork do
    run_time = (i < args.num_long_runs)? (3600 * 2):10
    test_loop(bench_names, args.no_yjit, args.logs_path, run_time, ruby_version)
  end
end

# We need some kind of busy loop to not exit?
# Loop and sleep, report if forked processes crashed?
while true
  sleep(50 * 0.001)
end
