# frozen_string_literal: true

require 'csv'
require 'json'
require 'rbconfig'

# Extracted helper methods from run_benchmarks.rb for testing
module BenchmarkRunner
  module_function

  # Format benchmark data as a string table
  def table_to_str(table_data, format, failures)
    # Trim numbers to one decimal for console display
    # Keep two decimals for the speedup ratios

    failure_rows = failures.map { |_exe, data| data.keys }.flatten.uniq
                           .map { |name| [name] + (['N/A'] * (table_data.first.size - 1)) }

    table_data = table_data.first(1) + failure_rows + table_data.drop(1).map { |row|
      format.zip(row).map { |fmt, data| fmt % data }
    }

    num_rows = table_data.length
    num_cols = table_data[0].length

    # Pad each column to the maximum width in the column
    (0...num_cols).each do |c|
      cell_lens = (0...num_rows).map { |r| table_data[r][c].length }
      max_width = cell_lens.max
      (0...num_rows).each { |r| table_data[r][c] = table_data[r][c].ljust(max_width) }
    end

    # Row of separator dashes
    sep_row = (0...num_cols).map { |i| '-' * table_data[0][i].length }.join('  ').rstrip

    out = sep_row + "\n"

    table_data.each do |row|
      out += row.join('  ').rstrip + "\n"
    end

    out += sep_row + "\n"

    out
  end

  # Find the first available file number for output files
  def free_file_no(prefix)
    (1..).each do |file_no|
      out_path = File.join(prefix, "output_%03d.csv" % file_no)
      return file_no unless File.exist?(out_path)
    end
  end

  # Get benchmark categories from metadata
  def benchmark_categories(name, metadata)
    benchmark_metadata = metadata.find { |benchmark, _metadata| benchmark == name }&.last || {}
    categories = [benchmark_metadata.fetch('category', 'other')]
    categories << 'ractor' if benchmark_metadata['ractor']
    categories
  end

  # Check if the name matches any of the names in a list of filters
  def match_filter(entry, categories:, name_filters:, metadata:)
    name_filters = process_name_filters(name_filters)
    name = entry.sub(/\.rb\z/, '')
    (categories.empty? || benchmark_categories(name, metadata).any? { |cat| categories.include?(cat) }) &&
      (name_filters.empty? || name_filters.any? { |filter| filter === name })
  end

  # Process "/my_benchmark/i" into /my_benchmark/i
  def process_name_filters(name_filters)
    name_filters.map do |name_filter|
      if name_filter[0] == "/"
        regexp_str = name_filter[1..-1].reverse.sub(/\A(\w*)\//, "")
        regexp_opts = ::Regexp.last_match(1).to_s
        regexp_str.reverse!
        r = /#{regexp_str}/
        if !regexp_opts.empty?
          # Convert option string to Regexp option flags
          flags = 0
          flags |= Regexp::IGNORECASE if regexp_opts.include?('i')
          flags |= Regexp::MULTILINE if regexp_opts.include?('m')
          flags |= Regexp::EXTENDED if regexp_opts.include?('x')
          r = Regexp.new(regexp_str, flags)
        end
        r
      else
        name_filter
      end
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
