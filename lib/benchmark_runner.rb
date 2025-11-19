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

  # Resolve the pre_init file path into a form that can be required
  def expand_pre_init(path)
    require 'pathname'

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

  # Sort benchmarks with headlines first, then others, then micro
  def sort_benchmarks(bench_names, metadata)
    headline_benchmarks = metadata.select { |_, meta| meta['category'] == 'headline' }.keys
    micro_benchmarks = metadata.select { |_, meta| meta['category'] == 'micro' }.keys

    headline_names, bench_names = bench_names.partition { |name| headline_benchmarks.include?(name) }
    micro_names, other_names = bench_names.partition { |name| micro_benchmarks.include?(name) }
    headline_names.sort + other_names.sort + micro_names.sort
  end

  # Check which OS we are running
  def os
    @os ||= (
      host_os = RbConfig::CONFIG['host_os']
      case host_os
      when /mswin|msys|mingw|cygwin|bccwin|wince|emc/
        :windows
      when /darwin|mac os/
        :macosx
      when /linux/
        :linux
      when /solaris|bsd/
        :unix
      else
        raise "unknown os: #{host_os.inspect}"
      end
    )
  end

  # Generate setarch prefix for Linux
  def setarch_prefix
    # Disable address space randomization (for determinism)
    prefix = ["setarch", `uname -m`.strip, "-R"]

    # Abort if we don't have permission (perhaps in a docker container).
    return [] unless system(*prefix, "true", out: File::NULL, err: File::NULL)

    prefix
  end
end
