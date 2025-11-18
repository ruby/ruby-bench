require_relative 'test_helper'
require_relative '../lib/results_table_builder'
require 'yaml'
require 'tmpdir'

describe ResultsTableBuilder do
  before do
    @original_dir = Dir.pwd
    @temp_dir = Dir.mktmpdir
    Dir.chdir(@temp_dir)

    benchmarks_metadata = {
      'fib' => { 'category' => 'micro' },
      'loop' => { 'category' => 'micro' },
      'railsbench' => { 'category' => 'headline' },
      'optcarrot' => { 'category' => 'headline' },
      'zebra' => { 'category' => 'other' },
      'apple' => { 'category' => 'other' },
      'mango' => { 'category' => 'other' },
      'some_bench' => { 'category' => 'other' },
      'another_bench' => { 'category' => 'other' }
    }
    File.write('benchmarks.yml', YAML.dump(benchmarks_metadata))
  end

  after do
    Dir.chdir(@original_dir)
    FileUtils.rm_rf(@temp_dir)
  end

  describe '#build' do
    it 'builds a table with header and data rows' do
      executable_names = ['ruby', 'ruby-yjit']
      bench_data = {
        'ruby' => {
          'fib' => {
            'warmup' => [0.1],
            'bench' => [0.1, 0.11, 0.09],
            'rss' => 1024 * 1024 * 10
          }
        },
        'ruby-yjit' => {
          'fib' => {
            'warmup' => [0.05],
            'bench' => [0.05, 0.06, 0.04],
            'rss' => 1024 * 1024 * 12
          }
        }
      }

      builder = ResultsTableBuilder.new(
        executable_names: executable_names,
        bench_data: bench_data,
        include_rss: false
      )

      table, format = builder.build

      assert_equal ['bench', 'ruby (ms)', 'stddev (%)', 'ruby-yjit (ms)', 'stddev (%)', 'ruby-yjit 1st itr', 'ruby/ruby-yjit'], table[0]

      assert_equal ['%s', '%.1f', '%.1f', '%.1f', '%.1f', '%.3f', '%.3f'], format

      assert_equal 'fib', table[1][0]
      assert_in_delta 100.0, table[1][1], 1.0
      assert_in_delta 50.0, table[1][3], 1.0
      assert_in_delta 2.0, table[1][5], 0.1
      assert_in_delta 2.0, table[1][6], 0.1
    end

    it 'includes RSS columns when include_rss is true' do
      executable_names = ['ruby']
      bench_data = {
        'ruby' => {
          'fib' => {
            'warmup' => [0.1],
            'bench' => [0.1],
            'rss' => 1024 * 1024 * 10
          }
        }
      }

      builder = ResultsTableBuilder.new(
        executable_names: executable_names,
        bench_data: bench_data,
        include_rss: true
      )

      table, format = builder.build

      assert_equal ['bench', 'ruby (ms)', 'stddev (%)', 'RSS (MiB)'], table[0]

      assert_equal ['%s', '%.1f', '%.1f', '%.1f'], format

      assert_in_delta 10.0, table[1][3], 0.1
    end

    it 'skips benchmarks with missing data' do
      executable_names = ['ruby', 'ruby-yjit']
      bench_data = {
        'ruby' => {
          'fib' => {
            'warmup' => [0.1],
            'bench' => [0.1],
            'rss' => 1024 * 1024 * 10
          },
          'loop' => {
            'warmup' => [0.2],
            'bench' => [0.2],
            'rss' => 1024 * 1024 * 10
          }
        },
        'ruby-yjit' => {
          'fib' => {
            'warmup' => [0.05],
            'bench' => [0.05],
            'rss' => 1024 * 1024 * 12
          }
        }
      }

      builder = ResultsTableBuilder.new(
        executable_names: executable_names,
        bench_data: bench_data,
        include_rss: false
      )

      table, _format = builder.build

      assert_equal 2, table.length
      assert_equal 'fib', table[1][0]
    end

    it 'handles multiple executables correctly' do
      executable_names = ['ruby', 'ruby-yjit', 'ruby-rjit']
      bench_data = {
        'ruby' => {
          'fib' => {
            'warmup' => [0.1],
            'bench' => [0.1],
            'rss' => 1024 * 1024 * 10
          }
        },
        'ruby-yjit' => {
          'fib' => {
            'warmup' => [0.05],
            'bench' => [0.05],
            'rss' => 1024 * 1024 * 12
          }
        },
        'ruby-rjit' => {
          'fib' => {
            'warmup' => [0.07],
            'bench' => [0.07],
            'rss' => 1024 * 1024 * 11
          }
        }
      }

      builder = ResultsTableBuilder.new(
        executable_names: executable_names,
        bench_data: bench_data,
        include_rss: false
      )

      table, format = builder.build

      expected_header = [
        'bench',
        'ruby (ms)', 'stddev (%)',
        'ruby-yjit (ms)', 'stddev (%)',
        'ruby-rjit (ms)', 'stddev (%)',
        'ruby-yjit 1st itr',
        'ruby-rjit 1st itr',
        'ruby/ruby-yjit',
        'ruby/ruby-rjit'
      ]
      assert_equal expected_header, table[0]

      expected_format = ['%s', '%.1f', '%.1f', '%.1f', '%.1f', '%.1f', '%.1f', '%.3f', '%.3f', '%.3f', '%.3f']
      assert_equal expected_format, format
    end

    it 'uses bench data when warmup is missing' do
      executable_names = ['ruby']
      bench_data = {
        'ruby' => {
          'fib' => {
            'warmup' => [],
            'bench' => [0.1, 0.11],
            'rss' => 1024 * 1024 * 10
          }
        }
      }

      builder = ResultsTableBuilder.new(
        executable_names: executable_names,
        bench_data: bench_data,
        include_rss: false
      )

      table, _format = builder.build

      assert_equal 2, table.length
      assert_equal 'fib', table[1][0]
      assert_in_delta 100.0, table[1][1], 5.0
    end

    it 'sorts benchmarks with headlines first, then others, then micro' do
      executable_names = ['ruby']
      bench_data = {
        'ruby' => {
          'fib' => {
            'warmup' => [0.1],
            'bench' => [0.1],
            'rss' => 1024 * 1024 * 10
          },
          'loop' => {
            'warmup' => [0.1],
            'bench' => [0.1],
            'rss' => 1024 * 1024 * 10
          },
          'railsbench' => {
            'warmup' => [0.1],
            'bench' => [0.1],
            'rss' => 1024 * 1024 * 10
          },
          'optcarrot' => {
            'warmup' => [0.1],
            'bench' => [0.1],
            'rss' => 1024 * 1024 * 10
          }
        }
      }

      builder = ResultsTableBuilder.new(
        executable_names: executable_names,
        bench_data: bench_data,
        include_rss: false
      )

      table, _format = builder.build

      bench_names = table[1..].map { |row| row[0] }

      assert_equal 'optcarrot', bench_names[0]
      assert_equal 'railsbench', bench_names[1]

      assert_equal 'fib', bench_names[2]
      assert_equal 'loop', bench_names[3]
    end

    it 'sorts benchmarks alphabetically within other category' do
      executable_names = ['ruby']
      bench_data = {
        'ruby' => {
          'zebra' => {
            'warmup' => [0.1],
            'bench' => [0.1],
            'rss' => 1024 * 1024 * 10
          },
          'apple' => {
            'warmup' => [0.1],
            'bench' => [0.1],
            'rss' => 1024 * 1024 * 10
          },
          'mango' => {
            'warmup' => [0.1],
            'bench' => [0.1],
            'rss' => 1024 * 1024 * 10
          }
        }
      }

      builder = ResultsTableBuilder.new(
        executable_names: executable_names,
        bench_data: bench_data,
        include_rss: false
      )

      table, _format = builder.build

      bench_names = table[1..].map { |row| row[0] }

      assert_equal ['apple', 'mango', 'zebra'], bench_names
    end

    it 'handles single benchmark' do
      executable_names = ['ruby']
      bench_data = {
        'ruby' => {
          'fib' => {
            'warmup' => [0.1],
            'bench' => [0.1],
            'rss' => 1024 * 1024 * 10
          }
        }
      }

      builder = ResultsTableBuilder.new(
        executable_names: executable_names,
        bench_data: bench_data,
        include_rss: false
      )

      table, _format = builder.build

      assert_equal 2, table.length
      assert_equal 'fib', table[1][0]
    end

    it 'handles only headline benchmarks' do
      executable_names = ['ruby']
      bench_data = {
        'ruby' => {
          'railsbench' => {
            'warmup' => [0.1],
            'bench' => [0.1],
            'rss' => 1024 * 1024 * 10
          },
          'optcarrot' => {
            'warmup' => [0.1],
            'bench' => [0.1],
            'rss' => 1024 * 1024 * 10
          }
        }
      }

      builder = ResultsTableBuilder.new(
        executable_names: executable_names,
        bench_data: bench_data,
        include_rss: false
      )

      table, _format = builder.build

      bench_names = table[1..].map { |row| row[0] }

      assert_equal ['optcarrot', 'railsbench'], bench_names
    end

    it 'sorts mixed categories correctly with multiple benchmarks' do
      executable_names = ['ruby']
      bench_data = {
        'ruby' => {
          'fib' => { 'warmup' => [0.1], 'bench' => [0.1], 'rss' => 1024 * 1024 * 10 },
          'some_bench' => { 'warmup' => [0.1], 'bench' => [0.1], 'rss' => 1024 * 1024 * 10 },
          'railsbench' => { 'warmup' => [0.1], 'bench' => [0.1], 'rss' => 1024 * 1024 * 10 },
          'another_bench' => { 'warmup' => [0.1], 'bench' => [0.1], 'rss' => 1024 * 1024 * 10 },
          'optcarrot' => { 'warmup' => [0.1], 'bench' => [0.1], 'rss' => 1024 * 1024 * 10 }
        }
      }

      builder = ResultsTableBuilder.new(
        executable_names: executable_names,
        bench_data: bench_data,
        include_rss: false
      )

      table, _format = builder.build
      bench_names = table[1..].map { |row| row[0] }

      assert_equal 'optcarrot', bench_names[0]
      assert_equal 'railsbench', bench_names[1]

      assert_equal 'another_bench', bench_names[2]
      assert_equal 'some_bench', bench_names[3]

      assert_equal 'fib', bench_names[4]
    end
  end
end
