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
    def build_output_text(ruby_descriptions, table, format, bench_failures)
      base_name, *other_names = ruby_descriptions.keys

      output_str = +""

      ruby_descriptions.each do |key, value|
        output_str << "#{key}: #{value}\n"
      end

      output_str << "\n"
      output_str << TableFormatter.new(table, format, bench_failures).to_s + "\n"

      unless other_names.empty?
        output_str << "Legend:\n"
        other_names.each do |name|
          output_str << "- #{name} 1st itr: ratio of #{base_name}/#{name} time for the first benchmarking iteration.\n"
          output_str << "- #{base_name}/#{name}: ratio of #{base_name}/#{name} time. Higher is better for #{name}. Above 1 represents a speedup.\n"
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
