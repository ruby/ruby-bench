# frozen_string_literal: true

require 'fileutils'
require_relative '../argument_parser'
require_relative '../cpu_config'
require_relative '../benchmark_runner'
require_relative '../benchmark_suite'
require_relative '../results_table_builder'

module BenchmarkRunner
  class CLI
    attr_reader :args

    def self.run(argv = ARGV)
      args = ArgumentParser.parse(argv)
      new(args).run
    end

    def initialize(args)
      @args = args
    end

    def run
      CPUConfig.configure_for_benchmarking(turbo: args.turbo)

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

      # Benchmark with and without YJIT
      bench_start_time = Time.now.to_f
      bench_data = {}
      bench_failures = {}
      args.executables.each do |name, executable|
        ruby_descriptions[name] = `#{executable.shelljoin} -v`.chomp

        bench_data[name], failures = suite.run(
          ruby: executable,
          ruby_description: ruby_descriptions[name]
        )
        # Make it easier to query later.
        bench_failures[name] = failures unless failures.empty?
      end

      bench_end_time = Time.now.to_f
      bench_total_time = (bench_end_time - bench_start_time).to_i
      puts("Total time spent benchmarking: #{bench_total_time}s")

      if !bench_failures.empty?
        puts("Failed benchmarks: #{bench_failures.map { |k, v| v.size }.sum}")
      end

      puts

      # Build results table
      builder = ResultsTableBuilder.new(
        executable_names: ruby_descriptions.keys,
        bench_data: bench_data,
        include_rss: args.rss
      )
      table, format = builder.build

      output_path = BenchmarkRunner.output_path(args.out_path, out_override: args.out_override)

      # Save the raw data as JSON
      out_json_path = BenchmarkRunner.write_json(output_path, ruby_descriptions, bench_data)

      # Save data as CSV so we can produce tables/graphs in a spreasheet program
      # NOTE: we don't do any number formatting for the output file because
      #       we don't want to lose any precision
      BenchmarkRunner.write_csv(output_path, ruby_descriptions, table)

      # Save the output in a text file that we can easily refer to
      output_str = BenchmarkRunner.build_output_text(ruby_descriptions, table, format, bench_failures)
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
  end
end
