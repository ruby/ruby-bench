require_relative 'test_helper'
require_relative '../lib/table_formatter'

describe TableFormatter do
  describe '#to_s' do
    it 'formats a simple table correctly' do
      table_data = [
        ['bench', 'time (ms)', 'stddev (%)'],
        ['fib', '100.5', '2.3'],
        ['loop', '50.2', '1.1']
      ]
      format = ['%s', '%s', '%s']
      failures = {}

      result = TableFormatter.new(table_data, format, failures).to_s

      assert_equal <<~TABLE, result
        -----  ---------  ----------
        bench  time (ms)  stddev (%)
        fib    100.5      2.3
        loop   50.2       1.1
        -----  ---------  ----------
      TABLE
    end

    it 'includes failure rows when failures are present' do
      table_data = [
        ['bench', 'time (ms)'],
        ['fib', '100.5']
      ]
      format = ['%s', '%s']
      failures = { 'ruby' => { 'broken_bench' => 1 } }

      result = TableFormatter.new(table_data, format, failures).to_s

      assert_equal <<~TABLE, result
        ------------  ---------
        bench         time (ms)
        broken_bench  N/A
        fib           100.5
        ------------  ---------
      TABLE
    end

    it 'handles empty failures hash' do
      table_data = [['bench'], ['fib']]
      format = ['%s']
      failures = {}

      result = TableFormatter.new(table_data, format, failures).to_s

      assert_equal <<~TABLE, result
        -----
        bench
        fib
        -----
      TABLE
    end

    it 'handles empty failures hash' do
      table_data = [['bench'], ['fib']]
      format = ['%s']
      failures = {}

      result = TableFormatter.new(table_data, format, failures).to_s
      refute_includes result, 'N/A'
    end

    it 'handles multiple failures from different executables' do
      table_data = [
        ['bench', 'time (ms)'],
        ['fib', '100.5']
      ]
      format = ['%s', '%s']
      failures = {
        'ruby' => { 'broken_bench' => 1 },
        'ruby-yjit' => { 'another_broken' => 1 }
      }

      result = TableFormatter.new(table_data, format, failures).to_s

      assert_includes result, 'broken_bench'
      assert_includes result, 'another_broken'
      # Count N/A occurrences - should have 2 (one for each failed benchmark)
      assert_equal 2, result.scan(/N\/A/).count
    end

    it 'removes trailing spaces from last column' do
      table_data = [
        ['bench', 'time (ms)', 'stddev (%)'],
        ['fib', '100.5', '2.3']
      ]
      format = ['%s', '%s', '%s']
      failures = {}

      result = TableFormatter.new(table_data, format, failures).to_s
      lines = result.lines

      # No line should have trailing spaces before the newline
      lines.each do |line|
        refute_match(/ \n\z/, line, "Line should not have trailing spaces: #{line.inspect}")
      end
    end

    it 'applies format strings correctly' do
      table_data = [
        ['bench', 'time'],
        ['fib', 123.456]
      ]
      format = ['%s', '%.1f']
      failures = {}

      result = TableFormatter.new(table_data, format, failures).to_s

      assert_includes result, '123.5' # Should round to 1 decimal
      refute_includes result, '123.456'
    end
  end
end
