# frozen_string_literal: true

require 'fileutils'
require_relative '../argument_parser'
require_relative '../cpu_config'
require_relative '../benchmark_runner'
require_relative '../benchmark_suite'
require_relative '../results_table_builder'
require_relative '../ractor_breakdown'
require_relative '../row_layout'

module BenchmarkRunner
  class CLI
    BOLD = "\e[1m"
    RESET = "\e[0m"

    attr_reader :args

    def self.run(argv = ARGV)
      args = ArgumentParser.parse(argv)
      new(args).run
    end

    def initialize(args)
      @args = args
    end

    def run
      CPUConfig.configure_for_benchmarking(turbo: args.turbo) unless args.no_sudo

      # Create the output directory
      FileUtils.mkdir_p(args.out_path)

      ruby_descriptions = {}

      suite = BenchmarkSuite.new(
        categories: args.categories,
        name_filters: args.name_filters,
        excludes: args.excludes,
        out_path: args.out_path,
        harness: args.harness,
        harness_explicit: args.harness_explicit,
        pre_init: args.with_pre_init,
        no_pinning: args.no_pinning,
        force_pinning: args.force_pinning
      )

      # Collect ruby version descriptions for all executables upfront
      args.executables.each do |name, executable|
        ruby_descriptions[name] = `#{executable.shelljoin} -v`.chomp
      end

      # Warn if two executables look identical (same ruby -v output and same flags)
      names = ruby_descriptions.keys
      names.each_with_index do |name_a, i|
        names[(i + 1)..].each do |name_b|
          flags_a = args.executables[name_a][1..] || []
          flags_b = args.executables[name_b][1..] || []
          if ruby_descriptions[name_a] == ruby_descriptions[name_b] && flags_a == flags_b
            warn "#{BOLD}WARNING: '#{name_a}' and '#{name_b}' appear identical (same revision, same flags). This is likely a mistake.#{RESET}"
          end
        end
      end

      bench_start_time = Time.now.to_f
      bench_data = {}
      bench_failures = {}
      bench_harnesses = suite.benchmarks.each_with_object({}) do |entry, h|
        h[entry.name] = suite.harness_for(entry.name)
      end

      if args.interleave
        args.executables.each_key { |name| bench_data[name] = {} }
        entries = suite.benchmarks

        entries.each_with_index do |entry, idx|
          # Alternate executable order to cancel cache-warming bias
          exes = ruby_descriptions.keys
          exes = exes.reverse if idx.odd?

          exes.each do |name|
            puts("Running benchmark \"#{entry.name}\" [#{name}] (#{idx+1}/#{entries.length})")
            result = suite.run_benchmark(entry, ruby: args.executables[name], ruby_description: ruby_descriptions[name])
            if result[:data]
              bench_data[name][entry.name] = result[:data]
            else
              bench_failures[name] ||= {}
              bench_failures[name][entry.name] = result[:failure]
            end
          end
        end
      else
        args.executables.each do |name, executable|
          bench_data[name], failures = suite.run(
            ruby: executable,
            ruby_description: ruby_descriptions[name]
          )
          bench_failures[name] = failures unless failures.empty?
        end
      end

      bench_end_time = Time.now.to_f
      bench_total_time = (bench_end_time - bench_start_time).to_i
      puts("Total time spent benchmarking: #{bench_total_time}s")

      if !bench_failures.empty?
        puts("Failed benchmarks: #{bench_failures.map { |k, v| v.size }.sum}")
      end

      puts

      # Build the results table
      builder = ResultsTableBuilder.new(
        executable_names: ruby_descriptions.keys,
        bench_data: bench_data,
        include_rss: args.rss,
        include_pvalue: args.pvalue,
        zjit_stats: args.zjit_stats
      )
      table, format, gc_table, gc_format = builder.build

      output_path = BenchmarkRunner.output_path(args.out_path, out_override: args.out_override)

      # Save the raw data as JSON
      out_json_path = BenchmarkRunner.write_json(output_path, ruby_descriptions, bench_data)

      # Save data as CSV so we can produce tables/graphs in a spreasheet program
      # NOTE: we don't do any number formatting for the output file because
      #       we don't want to lose any precision
      BenchmarkRunner.write_csv(output_path, ruby_descriptions, table)

      # Save the output in a text file that we can easily refer to
      output_sections = build_output_sections(ruby_descriptions.keys, bench_data, bench_harnesses, bench_failures)
      output_str = BenchmarkRunner.build_output_text(ruby_descriptions, table, format, bench_failures, include_rss: args.rss, include_gc: builder.include_gc?, include_pvalue: args.pvalue, gc_table: gc_table, gc_format: gc_format, sections: output_sections)
      out_txt_path = output_path + ".txt"
      File.open(out_txt_path, "w") { |f| f.write output_str }

      # Print the table to the console, with numbers truncated
      puts(output_str)

      # Print JSON and PNG file names
      puts
      puts "Output:"
      puts out_json_path

      if args.graph
        puts BenchmarkRunner.render_graph(out_json_path)
      end

      if !bench_failures.empty?
        puts "\nFailed benchmarks:"
        bench_failures.each do |name, data|
          puts "  #{name}: #{data.keys.join(", ")}"
        end
        exit(1)
      end
    end

    private

    def build_output_sections(executable_names, bench_data, bench_harnesses, bench_failures)
      ordered_names = sorted_benchmark_names(executable_names, bench_data)
      failed_names = bench_failures.values.flat_map(&:keys).uniq
      ordered_names.concat(failed_names.reject { |name| ordered_names.include?(name) })

      names_by_harness = {}
      ordered_names.each do |bench_name|
        harness = bench_harnesses.fetch(bench_name, args.harness)
        names_by_harness[harness] ||= []
        names_by_harness[harness] << bench_name
      end

      show_titles = names_by_harness.size > 1
      names_by_harness.map do |harness, names|
        section = build_output_section(executable_names, bench_data, bench_failures, harness, names)
        section[:title] = nil unless show_titles
        section
      end
    end

    def build_output_section(executable_names, bench_data, bench_failures, harness, bench_names)
      section_data = slice_bench_data(bench_data, bench_names)
      breakdown = RactorBreakdown.expand(section_data)
      use_ractor_layout = harness == BenchmarkSuite::RACTOR_HARNESS && !breakdown.groups.empty?
      layout = use_ractor_layout ? RactorRowLayout.new(groups: breakdown.groups) : FlatRowLayout.new
      display_data = use_ractor_layout ? breakdown.bench_data : section_data

      builder = ResultsTableBuilder.new(
        executable_names: executable_names,
        bench_data: display_data,
        include_rss: args.rss,
        include_pvalue: args.pvalue,
        zjit_stats: args.zjit_stats,
        row_layout: layout
      )
      table, format, gc_table, gc_format = builder.build

      {
        title: harness,
        table: table,
        format: format,
        failures: slice_failures(bench_failures, bench_names),
        include_gc: builder.include_gc?,
        gc_table: gc_table,
        gc_format: gc_format,
      }
    end

    def sorted_benchmark_names(executable_names, bench_data)
      builder = ResultsTableBuilder.new(
        executable_names: executable_names,
        bench_data: bench_data,
        include_rss: args.rss,
        include_pvalue: args.pvalue,
        zjit_stats: args.zjit_stats
      )
      builder.bench_names
    end

    def slice_bench_data(bench_data, bench_names)
      wanted = bench_names.each_with_object({}) { |name, h| h[name] = true }
      bench_data.each_with_object({}) do |(executable, benchmarks), sliced|
        sliced[executable] = benchmarks.select { |name, _data| wanted[name] }
      end
    end

    def slice_failures(bench_failures, bench_names)
      wanted = bench_names.each_with_object({}) { |name, h| h[name] = true }
      bench_failures.each_with_object({}) do |(executable, failures), sliced|
        selected = failures.select { |name, _failure| wanted[name] }
        sliced[executable] = selected unless selected.empty?
      end
    end
  end
end
