# frozen_string_literal: true

require 'csv'
require 'json'
require 'rbconfig'
require_relative 'table_formatter'

# Extracted helper methods from run_benchmarks.rb for testing
module BenchmarkRunner
  class << self
    # Determine output path - either use the override or find a free file number
    def output_path(out_path_dir, out_override: nil)
      if out_override
        out_override
      else
        # If no out path is specified, find a free file index for the output files
        file_no = free_file_no(out_path_dir)
        File.join(out_path_dir, "output_%03d" % file_no)
      end
    end

    # Write benchmark data to JSON file
    def write_json(output_path, ruby_descriptions, bench_data)
      out_json_path = "#{output_path}.json"
      out_data = {
        metadata: ruby_descriptions,
        raw_data: bench_data,
      }
      File.write(out_json_path, JSON.generate(out_data))
      out_json_path
    end

    # Write benchmark results to CSV file
    def write_csv(output_path, ruby_descriptions, table)
      out_csv_path = "#{output_path}.csv"

      CSV.open(out_csv_path, "wb") do |csv|
        ruby_descriptions.each do |key, value|
          csv << [key, value]
        end
        csv << []
        table.each do |row|
          csv << row
        end
      end

      out_csv_path
    end

    # Build output text string with metadata, table, and legend
    def build_output_text(ruby_descriptions, table, format, bench_failures, include_rss: false, include_gc: false, include_pvalue: false, gc_table: nil, gc_format: nil, sections: nil)
      base_name, *other_names = ruby_descriptions.keys

      output_str = +""

      ruby_descriptions.each do |key, value|
        output_str << "#{key}: #{value}\n"
      end

      output_str << "\n"
      sections ||= [{ table: table, format: format, failures: bench_failures, include_gc: include_gc, gc_table: gc_table, gc_format: gc_format }]
      has_gc_summary = sections.any? { |section| section[:include_gc] && section[:gc_table] }
      sections.each do |section|
        title = section[:title]
        output_str << "#{title}:\n" if title
        output_str << TableFormatter.new(section[:table], section[:format], section.fetch(:failures, {})).to_s + "\n"

        if section[:include_gc] && section[:gc_table] && section[:gc_format]
          output_str << (title ? "GC summary (#{title}):\n" : "GC summary:\n")
          output_str << TableFormatter.new(section[:gc_table], section[:gc_format], {}).to_s + "\n"
        end
      end

      unless other_names.empty?
        output_str << "Legend:\n"
        other_names.each do |name|
          output_str << "- #{name} 1st itr: ratio of #{base_name}/#{name} time for the first benchmarking iteration.\n"
          output_str << "- #{base_name}/#{name}: ratio of #{base_name}/#{name} time. Higher is better for #{name}. Above 1 represents a speedup.\n"
          if include_rss
            output_str << "- RSS #{base_name}/#{name}: ratio of #{base_name}/#{name} RSS. Higher is better for #{name}. Above 1 means lower memory usage.\n"
          end
        end
        if has_gc_summary
          output_str << "- GC summary compares #{base_name} → comparison. Ratio columns are #{base_name}/comparison; above 1 means the comparison spent less GC time.\n"
          output_str << "- mark/iter ratio and sweep/iter ratio compare total GC phase time per benchmark iteration, so they include both per-GC cost and GC frequency changes.\n"
          output_str << "- mark/GC ratio and sweep/GC ratio compare average phase time per GC, isolating whether each GC became cheaper or more expensive.\n"
          output_str << "- major/iter, minor/iter, and minor GC % show #{base_name} → comparison values, not ratios. Rows with no GC activity are omitted.\n"
        end
        if include_pvalue
          output_str << "- ***: p < 0.001, **: p < 0.01, *: p < 0.05 (Welch's t-test)\n"
        end
      end

      output_str
    end

    # Render a graph from JSON benchmark data
    def render_graph(json_path)
      png_path = json_path.sub(/\.json$/, '.png')
      require_relative 'graph_renderer'
      GraphRenderer.render(json_path, png_path)
    end

    # Checked system - error or return info if the command fails
    def check_call(command, env: {}, raise_error: true, quiet: ENV['BENCHMARK_QUIET'] == '1')
      puts("+ #{command}") unless quiet

      result = {}

      if quiet
        result[:success] = system(env, command, out: File::NULL, err: File::NULL)
      else
        result[:success] = system(env, command)
      end
      result[:status] = $?

      unless result[:success]
        puts "Command #{command.inspect} failed with exit code #{result[:status].exitstatus} in directory #{Dir.pwd}" unless quiet
        raise RuntimeError.new if raise_error
      end

      result
    end

    private

    def free_file_no(directory)
      (1..).each do |file_no|
        out_path = File.join(directory, "output_%03d.csv" % file_no)
        return file_no unless File.exist?(out_path)
      end
    end
  end
end
