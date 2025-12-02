require 'optparse'
require 'shellwords'
require 'rbconfig'

class ArgumentParser
  Args = Struct.new(
    :executables,
    :out_path,
    :out_override,
    :harness,
    :yjit_opts,
    :categories,
    :name_filters,
    :excludes,
    :rss,
    :graph,
    :no_pinning,
    :force_pinning,
    :turbo,
    :skip_yjit,
    :with_pre_init,
    keyword_init: true
  )

  def self.parse(argv = ARGV, ruby_executable: RbConfig.ruby)
    new(ruby_executable: ruby_executable).parse(argv)
  end

  def initialize(ruby_executable: RbConfig.ruby)
    @ruby_executable = ruby_executable
  end

  def parse(argv)
    args = default_args

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

      opts.on("--excludes=x,y,z", Array, "excludes the listed benchmarks") do |list|
        args.excludes = list
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
        args.yjit_opts = str
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

      opts.on("--force-pinning", "force pinning even for benchmarks marked no_pinning") do
        args.force_pinning = true
      end

      opts.on("--turbo", "don't disable CPU turbo boost") do
        args.turbo = true
      end
    end.parse!(argv)

    # Remaining arguments are treated as benchmark name filters
    if argv.length > 0
      args.name_filters += argv
    end

    # If -e is not specified, benchmark the current Ruby. Compare it with YJIT if available.
    if args.executables.empty?
      if have_yjit?(@ruby_executable) && !args.skip_yjit
        args.executables["interp"] = [@ruby_executable]
        args.executables["yjit"] = [@ruby_executable, "--yjit", *args.yjit_opts.shellsplit]
      else
        args.executables["ruby"] = [@ruby_executable]
      end
    end

    args
  end

  private

  def have_yjit?(ruby)
    ruby_version = `#{ruby} -v --yjit 2> #{File::NULL}`.strip
    ruby_version.downcase.include?("yjit")
  end

  def default_args
    Args.new(
      executables: {},
      out_path: File.expand_path("./data"),
      out_override: nil,
      harness: "harness",
      yjit_opts: "",
      categories: [],
      name_filters: [],
      excludes: [],
      rss: false,
      graph: false,
      no_pinning: false,
      force_pinning: false,
      turbo: false,
      skip_yjit: false,
      with_pre_init: nil,
    )
  end
end
