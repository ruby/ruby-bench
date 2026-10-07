# frozen_string_literal: true

require 'csv'
require 'json'
require 'rbconfig'
require 'shellwords'
require_relative 'table_formatter'

# Extracted helper methods from run_benchmarks.rb for testing
module BenchmarkRunner
  class << self
    def ruby_bench_revision(dir = File.expand_path('..', __dir__))
      revision = IO.popen(['git', '-C', dir, 'rev-parse', 'HEAD'], err: File::NULL, &:read).strip
      return 'unknown' unless $?.success? && !revision.empty?

      clean = system('git', '-C', dir, 'diff', '--quiet', 'HEAD', out: File::NULL, err: File::NULL)
      clean ? revision : "#{revision}-dirty"
    rescue SystemCallError
      'unknown'
    end

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
    def build_output_text(ruby_descriptions, table, format, bench_failures, include_rss: false, include_gc: false, include_pvalue: false, gc_table: nil, gc_format: nil, sections: nil, ruby_bench_revision: nil)
      base_name, *other_names = ruby_descriptions.keys

      output_str = +""

      ruby_descriptions.each do |key, value|
        output_str << "#{key}: #{value}\n"
      end
      output_str << "ruby-bench: #{ruby_bench_revision}\n" if ruby_bench_revision

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
          output_str << "- #{name} 1st itr: ratio of #{base_name}/#{name} time for the first iteration.\n"
          output_str << "- #{base_name}/#{name}: ratio of #{base_name}/#{name} time. Higher is better for #{name}. Above 1 represents a speedup.\n"
          if include_rss
            output_str << "- RSS #{base_name}/#{name}: ratio of #{base_name}/#{name} RSS. Higher is better for #{name}. Above 1 means lower memory usage.\n"
          end
        end
        if has_gc_summary
          output_str << "- GC summary compares #{base_name} → comparison. Ratio columns are #{base_name}/comparison; above 1 means the comparison spent less GC time.\n"
          output_str << "- gc/iter, mark/iter, and sweep/iter ratio compare total GC (or phase) time per benchmark iteration, so they include both per-GC cost and GC frequency changes.\n"
          output_str << "- gc/GC, mark/GC, and sweep/GC ratio divide average GC (or phase) time by the same run's GCs/iter count; they are not complete per-cycle attribution of process-wide GC.\n"
          output_str << "- GCs/iter, major/iter, minor/iter, controller compacts/iter*, and minor GC % show #{base_name} → comparison values, not ratios. Rows with no GC activity are omitted.\n"
        end
        if include_pvalue
          output_str << "- ***: p < 0.001, **: p < 0.01, *: p < 0.05 (Welch's t-test)\n"
        end
      end
      gc_headers = sections.filter_map { |section| section[:gc_table]&.first }.flatten
      if gc_headers.include?('controller compacts/iter*')
        output_str << "GC metric notes:\n"
        output_str << "- controller compacts/iter*: the main Ractor's GC.stat(:compact_count) delta per iteration. Every global compacting cycle increments compact_count in every object space. Do not sum it across workers.#{other_names.empty? ? '' : " Comparison tables show #{base_name} → comparison values."}\n"
      end

      ractor_gc_sections = sections.select { |section| section[:gc_scope] == 'ractor-local-workload' && section[:gc_table] }
      unless ractor_gc_sections.empty?
        modes = ractor_gc_sections.flat_map { |section| section.fetch(:ractor_gc_modes, []) }
        worker_mode = modes.include?(:worker)
        output_str << "Ractor GC scope note:\n"
        scope_columns = +"- (worker sum) columns add Ractor-local counters across the sampled workers of each iteration"
        scope_columns << (worker_mode ? "; the main Ractor performs the count-0 workload of per-worker benchmarks." : ".")
        scope_columns << " GC ms/worker divides each iteration's worker-sum GC time by its sampled worker count, then averages." if other_names.empty?
        output_str << "#{scope_columns} Controller snapshots and per-worker heap detail are in the JSON output, not this table.\n"
        output_str << "- Ruby's Ractor-retirement GC (after a worker's stack is torn down) is not sampled."
        output_str << " Ractors created by the workload of a per-worker benchmark are not sampled." if worker_mode
        output_str << "\n"
        if modes.include?(:scenario)
          output_str << "- Scenario benchmarks sample only the worker Ractors whose bodies the scenario wraps in measure_worker_gc; other Ractors that a scenario spawns are not sampled. Main-Ractor allocation during the scenario and the retention-measurement GCs are not in the worker sums; gc_controller_samples in the JSON output cover the main Ractor during the scenario.\n"
        end
        output_str << "- GC time is CPU-time accounting, not elapsed pause time; summed across Ractors it can exceed wall time.\n"
        output_str << "- Per-GC ratios divide by recorded GC counts, not complete process-wide GC cycles. Phase times are integer milliseconds; total GC time is kept at nanosecond resolution in the raw worker samples.\n"
      end

      output_str
    end

    # Render a graph from JSON benchmark data
    def render_graph(json_path)
      png_path = json_path.sub(/\.json$/, '.png')
      require_relative 'graph_renderer'
      GraphRenderer.render(json_path, png_path)
    end

    # Checked system - error or return info if the command fails.
    # An Array command with arguments runs without a shell, so Shellwords escapes never reach the program.
    def check_call(command, env: {}, raise_error: true, quiet: ENV['BENCHMARK_QUIET'] == '1')
      command_str = command.is_a?(Array) ? command.shelljoin : command
      puts("+ #{command_str}") unless quiet

      result = {}

      if quiet
        result[:success] = system(env, *command, out: File::NULL, err: File::NULL)
      else
        result[:success] = system(env, *command)
      end
      result[:status] = $?

      unless result[:success]
        puts "Command #{command_str.inspect} failed with exit code #{result[:status].exitstatus} in directory #{Dir.pwd}" unless quiet
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
