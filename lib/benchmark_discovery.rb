# frozen_string_literal: true

# BenchmarkDiscovery handles discovering benchmarks in different organization patterns:
# 1. Standalone .rb files in benchmarks/ directory
# 2. Single benchmark.rb in a subdirectory
# 3. Multiple .rb files in a subdirectory (named as directory-suffix, excluding benchmark.rb)
class BenchmarkDiscovery
  # Represents a discovered benchmark
  BenchmarkEntry = Struct.new(:name, :script_path, :directory, keyword_init: true)

  attr_reader :base_dir

  def initialize(base_dir)
    @base_dir = base_dir
  end

  # Returns an array of BenchmarkEntry objects
  def discover
    return [] unless Dir.exist?(base_dir)

    entries = []

    Dir.children(base_dir).sort.each do |entry|
      entry_path = File.join(base_dir, entry)

      if File.file?(entry_path) && entry.end_with?('.rb')
        # Pattern 1: Standalone .rb file
        entries << BenchmarkEntry.new(
          name: entry.delete_suffix('.rb'),
          script_path: entry_path,
          directory: nil
        )
      elsif File.directory?(entry_path)
        # Check for patterns 2 and 3
        entries.concat(discover_directory_benchmarks(entry, entry_path))
      end
    end

    entries
  end

  private

  def discover_directory_benchmarks(dir_name, dir_path)
    benchmark_files = find_benchmark_files(dir_path)
    return [] if benchmark_files.empty?

    entries = benchmark_files.map do |file|
      create_benchmark_entry_in_directory(dir_name, dir_path, file)
    end

    entries.sort_by(&:name)
  end

  def find_benchmark_files(dir_path)
    all_rb_files = Dir.children(dir_path).select { |file| file.end_with?('.rb') }

    # If benchmark.rb exists, only use that (Pattern 2)
    if all_rb_files.include?('benchmark.rb')
      ['benchmark.rb']
    else
      # Otherwise, use all .rb files (Pattern 3)
      all_rb_files
    end
  end

  def create_benchmark_entry_in_directory(dir_name, dir_path, file)
    if file == 'benchmark.rb'
      # Pattern 2: Single benchmark.rb in directory
      BenchmarkEntry.new(
        name: dir_name,
        script_path: File.join(dir_path, file),
        directory: dir_name
      )
    else
      # Pattern 3: Multiple .rb files (derive suffix from filename without .rb extension)
      suffix = file.delete_suffix('.rb')
      BenchmarkEntry.new(
        name: "#{dir_name}-#{suffix}",
        script_path: File.join(dir_path, file),
        directory: dir_name
      )
    end
  end
end
