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

      assert_equal ['%s', '%.1f', '%.1f', '%.1f', '%.1f', '%.3f', '%s'], format

      assert_equal 'fib', table[1][0]
      assert_in_delta 100.0, table[1][1], 1.0
      assert_in_delta 50.0, table[1][3], 1.0
      assert_in_delta 2.0, table[1][5], 0.1
      assert_match(/^2\.0\d+/, table[1][6])
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

      expected_format = ['%s', '%.1f', '%.1f', '%.1f', '%.1f', '%.1f', '%.1f', '%.3f', '%.3f', '%s', '%s']
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

    it 'shows small p-value in scientific notation for clearly different distributions' do
      executable_names = ['ruby', 'ruby-yjit']
      bench_data = {
        'ruby' => {
          'fib' => {
            'warmup' => [0.1],
            'bench' => [0.100, 0.101, 0.099, 0.1005, 0.0995, 0.1002, 0.0998, 0.1001, 0.0999, 0.1003],
            'rss' => 1024 * 1024 * 10
          }
        },
        'ruby-yjit' => {
          'fib' => {
            'warmup' => [0.05],
            'bench' => [0.050, 0.051, 0.049, 0.0505, 0.0495, 0.0502, 0.0498, 0.0501, 0.0499, 0.0503],
            'rss' => 1024 * 1024 * 12
          }
        }
      }

      builder = ResultsTableBuilder.new(
        executable_names: executable_names,
        bench_data: bench_data,
        include_pvalue: true
      )

      table, _format = builder.build
      p_value_str = table[1][-2]
      sig_str = table[1].last
      assert_match(/e-/, p_value_str, "Expected scientific notation for very small p-value, got #{p_value_str}")
      assert_equal "p < 0.001", sig_str
    end

    it 'shows N/A p-value when samples have fewer than 2 elements' do
      executable_names = ['ruby', 'ruby-yjit']
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
        }
      }

      builder = ResultsTableBuilder.new(
        executable_names: executable_names,
        bench_data: bench_data,
        include_pvalue: true
      )

      table, _format = builder.build
      assert_equal 'N/A', table[1][-2]
      assert_equal '', table[1].last
    end

    it 'always shows significance symbol but omits verbose columns without --pvalue' do
      executable_names = ['ruby', 'ruby-yjit']
      bench_data = {
        'ruby' => {
          'fib' => {
            'warmup' => [0.1],
            'bench' => [0.100, 0.101, 0.099],
            'rss' => 1024 * 1024 * 10
          }
        },
        'ruby-yjit' => {
          'fib' => {
            'warmup' => [0.05],
            'bench' => [0.050, 0.051, 0.049],
            'rss' => 1024 * 1024 * 12
          }
        }
      }

      builder = ResultsTableBuilder.new(
        executable_names: executable_names,
        bench_data: bench_data
      )

      table, _format = builder.build
      refute_includes table[0], 'p-value'
      refute_includes table[0], 'sig'
      assert_match(/\(\*{1,3}\)$/, table[1].last)
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
