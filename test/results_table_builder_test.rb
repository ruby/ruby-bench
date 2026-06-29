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
end
