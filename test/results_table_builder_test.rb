require_relative 'test_helper'
require_relative '../lib/results_table_builder'
require_relative '../lib/ractor_breakdown'
require_relative '../lib/row_layout'
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

      assert_equal ['bench', 'ruby (ms)', 'ruby-yjit (ms)', 'ruby-yjit 1st itr', 'ruby/ruby-yjit'], table[0]

      assert_equal ['%s', '%s', '%s', '%.3f', '%s'], format

      assert_equal 'fib', table[1][0]

      m = table[1][1].match(/\A(\d+\.\d) ± (\d+\.\d)%\z/)
      assert m
      assert_in_delta 100.0, m[1].to_f, 1.0

      m = table[1][2].match(/\A(\d+\.\d) ± (\d+\.\d)%\z/)
      assert m
      assert_in_delta 50.0, m[1].to_f, 1.0

      assert_in_delta 2.0, table[1][3], 0.1

      m = table[1][4].match(/\A(\d+\.\d+)/)
      assert m
      assert_in_delta 2.0, m[1].to_f, 0.1
    end

    it 'builds a per-ractor-count table when a RactorRowLayout is injected' do
      File.write('benchmarks.yml', YAML.dump('symbol-name-ractor' => { 'category' => 'micro' }))

      raw = {
        'master' => {
          'symbol-name-ractor' => {
            'warmup' => [],
            'bench' => [1.0, 2.0],
            'bench_by_ractors' => { '0' => [1.0, 1.0], '2' => [2.0, 2.0] },
            'rss' => 10 * 1024 * 1024
          }
        },
        'exp' => {
          'symbol-name-ractor' => {
            'warmup' => [],
            'bench' => [0.5, 1.0],
            'bench_by_ractors' => { '0' => [0.5, 0.5], '2' => [1.0, 1.0] },
            'rss' => 10 * 1024 * 1024
          }
        }
      }

      expanded = RactorBreakdown.expand(raw)
      builder = ResultsTableBuilder.new(
        executable_names: ['master', 'exp'],
        bench_data: expanded.bench_data,
        row_layout: RactorRowLayout.new(groups: expanded.groups)
      )

      table, format = builder.build

      assert_equal ['bench', 'ractors', 'master (ms)', 'exp (ms)', 'exp 1st itr', 'master/exp'], table[0]
      assert_equal ['%s', '%s', '%s', '%s', '%.3f', '%s'], format

      # name shown once, blank on continuation; ractor count in column 1
      assert_equal 'symbol-name-ractor', table[1][0]
      assert_equal '0', table[1][1]
      assert_equal '', table[2][0]
      assert_equal '2', table[2][1]

      # count=0 row: master 1000ms vs exp 500ms => ratio 2.0
      assert_in_delta 2.0, table[1][5].to_f, 0.01
      # count=2 row: master 2000ms vs exp 1000ms => ratio 2.0
      assert_in_delta 2.0, table[2][5].to_f, 0.01
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

      # No RSS ratio column with a single executable
      assert_equal ['bench', 'ruby (ms)', 'RSS (MiB)'], table[0]
      assert_equal ['%s', '%s', '%.1f'], format
      assert_in_delta 10.0, table[1][2], 0.1
    end

    it 'includes RSS ratio columns when include_rss is true with multiple executables' do
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
            'rss' => 1024 * 1024 * 20
          }
        }
      }

      builder = ResultsTableBuilder.new(
        executable_names: executable_names,
        bench_data: bench_data,
        include_rss: true
      )

      table, format = builder.build

      expected_header = [
        'bench',
        'ruby (ms)', 'RSS (MiB)',
        'ruby-yjit (ms)', 'RSS (MiB)',
        'ruby-yjit 1st itr',
        'ruby/ruby-yjit',
        'RSS ruby/ruby-yjit'
      ]
      assert_equal expected_header, table[0]

      expected_format = ['%s', '%s', '%.1f', '%s', '%.1f', '%.3f', '%s', '%.3f']
      assert_equal expected_format, format

      # RSS ratio: 10 MiB / 20 MiB = 0.5
      assert_in_delta 0.5, table[1].last, 0.01
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
        'ruby (ms)',
        'ruby-yjit (ms)',
        'ruby-rjit (ms)',
        'ruby-yjit 1st itr',
        'ruby-rjit 1st itr',
        'ruby/ruby-yjit',
        'ruby/ruby-rjit'
      ]
      assert_equal expected_header, table[0]

      expected_format = ['%s', '%s', '%s', '%s', '%.3f', '%.3f', '%s', '%s']
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
      m = table[1][1].match(/\A(\d+\.\d) ± (\d+\.\d)%\z/)
      assert m
      assert_in_delta 100.0, m[1].to_f, 5.0
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

    it 'omits significance symbols and p-value columns without --pvalue' do
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
      ratio_cell = table[1].last
      refute_match(/\*/, ratio_cell)
      assert_match(/\A\d+\.\d+\s*\z/, ratio_cell)
    end

    it 'shows significance symbols and p-value columns with --pvalue' do
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
        bench_data: bench_data,
        include_pvalue: true
      )

      table, _format = builder.build
      assert_includes table[0], 'p-value'
      assert_includes table[0], 'sig'
      ratio_col_idx = table[0].index('ruby/ruby-yjit')
      assert_match(/\(\*{1,3}\)/, table[1][ratio_col_idx])
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

  describe 'GC summary data' do
    it 'keeps GC columns out of the main table and builds a compact GC comparison table' do
      bench_data = {
        'ruby-base' => {
          'fib' => {
            'warmup' => [0.1],
            'bench' => [0.1, 0.1],
            'rss' => 10 * 1024 * 1024,
            'gc_marking_time_bench' => [20.0, 20.0],
            'gc_sweeping_time_bench' => [10.0, 10.0],
            'gc_major_count_bench' => [2, 2],
            'gc_minor_count_bench' => [8, 8]
          }
        },
        'ruby-exp' => {
          'fib' => {
            'warmup' => [0.05],
            'bench' => [0.05, 0.05],
            'rss' => 12 * 1024 * 1024,
            'gc_marking_time_bench' => [15.0, 15.0],
            'gc_sweeping_time_bench' => [10.0, 10.0],
            'gc_major_count_bench' => [1, 1],
            'gc_minor_count_bench' => [4, 4]
          }
        }
      }

      builder = ResultsTableBuilder.new(
        executable_names: ['ruby-base', 'ruby-exp'],
        bench_data: bench_data
      )

      table, format, gc_table, gc_format = builder.build

      assert_equal ['bench', 'ruby-base (ms)', 'ruby-exp (ms)', 'ruby-exp 1st itr', 'ruby-base/ruby-exp'], table[0]
      assert_equal ['%s', '%s', '%s', '%.3f', '%s'], format

      assert_equal [
        'bench', 'mark/iter ratio', 'sweep/iter ratio', 'mark/GC ratio', 'sweep/GC ratio', 'major/iter', 'minor/iter', 'minor GC %'
      ], gc_table[0]
      assert_equal ['%s', '%s', '%s', '%s', '%s', '%s', '%s', '%s'], gc_format
      assert_equal [
        'fib', '1.333', '1.000', '0.667', '0.500', ' 2.0  →   1.0', ' 8.0  →   4.0', ' 80%  →   80%'
      ], gc_table[1]
    end

    it 'omits benchmarks with no GC activity from the GC summary' do
      bench_data = {
        'ruby-base' => {
          'fib' => {
            'warmup' => [0.1],
            'bench' => [0.1],
            'rss' => 10,
            'gc_marking_time_bench' => [0.0],
            'gc_sweeping_time_bench' => [0.0],
            'gc_major_count_bench' => [0],
            'gc_minor_count_bench' => [0]
          }
        },
        'ruby-exp' => {
          'fib' => {
            'warmup' => [0.1],
            'bench' => [0.1],
            'rss' => 10,
            'gc_marking_time_bench' => [0.0],
            'gc_sweeping_time_bench' => [0.0],
            'gc_major_count_bench' => [0],
            'gc_minor_count_bench' => [0]
          }
        }
      }

      builder = ResultsTableBuilder.new(
        executable_names: ['ruby-base', 'ruby-exp'],
        bench_data: bench_data
      )

      _table, _format, gc_table, gc_format = builder.build

      assert_nil gc_table
      assert_nil gc_format
    end
  end

  describe 'RSS sampling (rss_samples)' do
    MIB = 1024 * 1024

    it 'shows mean ± stddev% and uses %s format when samples are present' do
      bench_data = {
        'ruby' => {
          'fib' => {
            'warmup' => [0.1],
            'bench' => [0.1, 0.1, 0.1],
            'rss' => 10 * MIB,
            'rss_samples' => [9 * MIB, 10 * MIB, 11 * MIB]
          }
        }
      }

      builder = ResultsTableBuilder.new(
        executable_names: ['ruby'],
        bench_data: bench_data,
        include_rss: true
      )

      table, format = builder.build

      assert_equal ['bench', 'ruby (ms)', 'RSS (MiB)'], table[0]
      assert_equal ['%s', '%s', '%s'], format

      m = table[1][2].match(/\A(\d+\.\d) ± (\d+\.\d)%\z/)
      assert m, "expected mean ± stddev%, got #{table[1][2].inspect}"
      assert_in_delta 10.0, m[1].to_f, 0.1
      assert_operator m[2].to_f, :>, 0.0
    end

    it 'computes the RSS ratio from the mean of samples' do
      bench_data = {
        'ruby' => {
          'fib' => {
            'warmup' => [0.1],
            'bench' => [0.1, 0.1, 0.1],
            'rss' => 99 * MIB, # should be ignored in favour of samples
            'rss_samples' => [10 * MIB, 10 * MIB, 10 * MIB]
          }
        },
        'ruby-yjit' => {
          'fib' => {
            'warmup' => [0.05],
            'bench' => [0.05, 0.05, 0.05],
            'rss' => 1 * MIB,
            'rss_samples' => [18 * MIB, 20 * MIB, 22 * MIB]
          }
        }
      }

      builder = ResultsTableBuilder.new(
        executable_names: ['ruby', 'ruby-yjit'],
        bench_data: bench_data,
        include_rss: true
      )

      table, _format = builder.build

      # ratio = mean(ruby samples) / mean(yjit samples) = 10 / 20 = 0.5
      assert_in_delta 0.5, table[1].last, 0.001
    end

    it 'falls back to a plain MiB value for runs without samples in a mixed suite' do
      bench_data = {
        'ruby' => {
          'fib' => {
            'warmup' => [0.1],
            'bench' => [0.1, 0.1],
            'rss' => 10 * MIB,
            'rss_samples' => [10 * MIB, 10 * MIB]
          },
          'loop' => {
            'warmup' => [0.2],
            'bench' => [0.2, 0.2],
            'rss' => 15 * MIB
            # no rss_samples for this benchmark
          }
        }
      }

      builder = ResultsTableBuilder.new(
        executable_names: ['ruby'],
        bench_data: bench_data,
        include_rss: true
      )

      table, format = builder.build

      # Suite has samples somewhere, so the RSS column is string-formatted.
      assert_equal ['%s', '%s', '%s'], format

      rows = table[1..].each_with_object({}) { |row, h| h[row[0]] = row }
      assert_match(/\A\d+\.\d ± \d+\.\d%\z/, rows['fib'][2])
      # The sample-less benchmark still renders as a bare MiB value.
      assert_equal '15.0', rows['loop'][2]
    end

    it 'keeps %.1f formatting when no run in the suite has samples' do
      bench_data = {
        'ruby' => {
          'fib' => {
            'warmup' => [0.1],
            'bench' => [0.1],
            'rss' => 10 * MIB
          }
        }
      }

      builder = ResultsTableBuilder.new(
        executable_names: ['ruby'],
        bench_data: bench_data,
        include_rss: true
      )

      _table, format = builder.build
      assert_equal ['%s', '%s', '%.1f'], format
    end
  end

  describe 'Ractor GC data' do
    def gc_group(total:, major:, minor:, mark: nil, sweep: nil)
      group = {
        'gc_count_bench' => major.zip(minor).map { |a, b| a + b },
        'gc_major_count_bench' => major,
        'gc_minor_count_bench' => minor,
        'gc_worker_samples' => major.each_index.map { |i| [{ 'gc_count' => major[i] + minor[i], 'worker_index' => 0 }] }
      }
      group['gc_total_time_bench'] = total if total
      group['gc_marking_time_bench'] = mark if mark
      group['gc_sweeping_time_bench'] = sweep if sweep
      group
    end

    def ractor_gc_blob(groups)
      {
        'warmup' => [],
        'bench' => groups.values.flat_map { |g| g[:bench] },
        'rss' => 10 * 1024 * 1024,
        'gc_scope' => 'ractor-local-workload',
        'bench_by_ractors' => groups.transform_values { |g| g[:bench] },
        'gc_by_ractors' => groups.transform_values { |g| g[:gc] }
      }
    end

    def build_ractor_gc(bench_data)
      expanded = RactorBreakdown.expand(bench_data)
      ResultsTableBuilder.new(
        executable_names: bench_data.keys,
        bench_data: expanded.bench_data,
        row_layout: RactorRowLayout.new(groups: expanded.groups)
      ).build
    end

    it 'renders per-count comparison rows using only each count\'s own series' do
      bench_data = {
        'base' => {
          'object-new' => ractor_gc_blob(
            '0' => { bench: [1.0, 1.0], gc: gc_group(total: [4.0, 4.0], major: [1, 1], minor: [3, 3], mark: [1.0, 1.0], sweep: [1.0, 1.0]) },
            '2' => { bench: [1.0, 1.0], gc: gc_group(total: [12.0, 12.0], major: [2, 2], minor: [6, 6], mark: [2.0, 2.0], sweep: [2.0, 2.0]) }
          )
        },
        'candidate' => {
          'object-new' => ractor_gc_blob(
            '0' => { bench: [1.0, 1.0], gc: gc_group(total: [2.0, 2.0], major: [1, 1], minor: [1, 1], mark: [1.0, 1.0], sweep: [1.0, 1.0]) },
            '2' => { bench: [1.0, 1.0], gc: gc_group(total: [3.0, 3.0], major: [1, 1], minor: [3, 3], mark: [1.0, 1.0], sweep: [1.0, 1.0]) }
          )
        }
      }

      table, _format, gc_table, gc_format = build_ractor_gc(bench_data)

      assert_equal ['bench', 'ractors', 'base (ms)', 'candidate (ms)', 'candidate 1st itr', 'base/candidate'], table[0]
      assert_equal [
        'bench', 'ractors', 'gc/iter ratio', 'gc/GC ratio', 'mark/iter ratio', 'sweep/iter ratio',
        'mark/GC ratio', 'sweep/GC ratio', 'major/iter', 'minor/iter', 'minor GC %'
      ], gc_table[0]
      assert_equal ['%s'] * gc_table[0].size, gc_format

      rows = gc_table[1..].to_h { |row| [row[1], row] }
      assert_equal %w[0 2], gc_table[1..].map { |row| row[1] }

      # Every row repeats the benchmark name; no blank group-continuation cells.
      assert_equal ['object-new', 'object-new'], gc_table[1..].map(&:first)

      # Count 0: gc/iter 4/2, gc/GC (4/4)/(2/2), mark/GC (1/4)/(1/2).
      assert_equal ['object-new', '0', '2.000', '1.000', '1.000', '1.000', '0.500', '0.500', ' 1.0  →   1.0', ' 3.0  →   1.0', ' 75%  →   50%'], rows['0']
      # Count 2: gc/iter 12/3, gc/GC (12/8)/(3/4) — the distinct values rule out cross-count leakage.
      assert_equal ['object-new', '2', '4.000', '2.000', '2.000', '2.000', '1.000', '1.000', ' 2.0  →   1.0', ' 6.0  →   3.0', ' 75%  →   75%'], rows['2']

      gc_table.flatten.each { |cell| refute_includes cell.to_s, "\x00" }
    end

    it 'renders N/A for a count missing optional GC data instead of reusing another count' do
      bench_data = {
        'base' => {
          'object-new' => ractor_gc_blob(
            '0' => { bench: [1.0], gc: gc_group(total: [4.0], major: [1], minor: [3], mark: [1.0], sweep: [1.0]) },
            '2' => { bench: [1.0], gc: gc_group(total: [12.0], major: [2], minor: [6], mark: [2.0], sweep: [2.0]) }
          )
        },
        'candidate' => {
          'object-new' => ractor_gc_blob(
            '0' => { bench: [1.0], gc: gc_group(total: [2.0], major: [1], minor: [1], mark: [1.0], sweep: [1.0]) },
            # count 2 lacks the total-time and marking series entirely
            '2' => { bench: [1.0], gc: gc_group(total: nil, major: [1], minor: [3], mark: nil, sweep: [1.0]) }
          )
        }
      }

      _table, _format, gc_table, _gc_format = build_ractor_gc(bench_data)

      rows = gc_table[1..].to_h { |row| [row[1], row] }
      assert_equal '2.000', rows['0'][2], 'count 0 keeps its own gc/iter ratio'
      assert_equal '1.000', rows['0'][4]
      assert_equal 'N/A', rows['2'][2], 'missing total-time series must not reuse count 0 data or zero'
      assert_equal 'N/A', rows['2'][3]
      assert_equal 'N/A', rows['2'][4], 'missing marking series must not be fabricated'
      assert_equal '2.000', rows['2'][5], 'present sweeping series still renders'
    end

    it 'builds an absolute GC table for one executable, keeping supported all-zero rows' do
      bench_data = {
        'reference' => {
          'object-new' => ractor_gc_blob(
            # count 0: supported but no recorded activity; sweeping unsupported
            '0' => { bench: [1.0, 1.0], gc: gc_group(total: [0.0, 0.0], major: [0, 0], minor: [0, 0], mark: [0.0, 0.0]) },
            '2' => { bench: [1.0, 1.0], gc: gc_group(total: [3.0, 5.0], major: [1, 1], minor: [3, 5], mark: [1.0, 3.0], sweep: [0.5, 1.5]) }
          )
        }
      }

      _table, _format, gc_table, gc_format = build_ractor_gc(bench_data)

      assert_equal ['bench', 'ractors', 'GC ms/iter', 'mark ms/iter', 'sweep ms/iter', 'GCs/iter', 'major/iter', 'minor/iter'], gc_table[0]
      assert_equal ['%s'] * 8, gc_format
      assert_equal ['object-new', '0', '0.000', '0.000', 'N/A', '0.0', '0.0', '0.0'], gc_table[1]
      assert_equal ['object-new', '2', '4.000', '2.000', '1.000', '5.0', '1.0', '4.0'], gc_table[2]
    end

    it 'detects GC data from any recognized series, not just marking time' do
      bench_data = {
        'reference' => {
          'object-new' => ractor_gc_blob(
            '0' => { bench: [1.0], gc: gc_group(total: nil, major: [2], minor: [4]) }
          )
        }
      }

      _table, _format, gc_table, _gc_format = build_ractor_gc(bench_data)

      refute_nil gc_table, 'a blob with only count series is still GC data'
      assert_equal ['object-new', '0', 'N/A', 'N/A', 'N/A', '6.0', '2.0', '4.0'], gc_table[1]
    end
  end
end
