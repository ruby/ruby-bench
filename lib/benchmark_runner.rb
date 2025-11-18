# frozen_string_literal: true

require 'csv'
require 'json'
require 'rbconfig'

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

    # Render a graph from JSON benchmark data
    def render_graph(json_path)
      png_path = json_path.sub(/\.json$/, '.png')
      require_relative 'graph_renderer'
      GraphRenderer.render(json_path, png_path)
    end

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

    private

    def free_file_no(directory)
      (1..).each do |file_no|
        out_path = File.join(directory, "output_%03d.csv" % file_no)
        return file_no unless File.exist?(out_path)
      end
    end
  end
end
