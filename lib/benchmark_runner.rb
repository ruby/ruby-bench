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
end
