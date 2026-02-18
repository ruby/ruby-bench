# frozen_string_literal: true

# Formats benchmark data as an ASCII table with aligned columns
class TableFormatter
  COLUMN_SEPARATOR = '  '
  FAILURE_PLACEHOLDER = 'N/A'

  def initialize(table_data, format, failures)
    @header = table_data.first
    @data_rows = table_data.drop(1)
    @format = format
    @failures = failures
    @num_columns = @header.size
  end

  def to_s
    rows = build_all_rows
    col_widths = calculate_column_widths(rows)

    format_table(rows, col_widths)
  end

  private

  attr_reader :num_columns

  def build_all_rows
    [@header, *build_failure_rows, *build_formatted_data_rows]
  end

  def build_failure_rows
    return [] if @failures.empty?

    failed_benchmarks = extract_failed_benchmarks
    failed_benchmarks.map { |name| build_failure_row(name) }
  end

  def extract_failed_benchmarks
    @failures.flat_map { |_exe, data| data.keys }.uniq
  end

  def build_failure_row(benchmark_name)
    [benchmark_name, *Array.new(num_columns - 1, FAILURE_PLACEHOLDER)]
  end

  def build_formatted_data_rows
    @data_rows.map { |row| apply_format(row) }
  end

  def apply_format(row)
    @format.zip(row).map { |fmt, data| fmt % data }
  end

  def calculate_column_widths(rows)
    (0...num_columns).map do |col_index|
      rows.map { |row| row[col_index].length }.max
    end
  end

  def format_table(rows, col_widths)
    separator = build_separator(col_widths)

    formatted_rows = rows.map { |row| format_row(row, col_widths) }

    [separator, *formatted_rows, separator].join("\n") + "\n"
  end

  def build_separator(col_widths)
    col_widths.map { |width| '-' * width }.join(COLUMN_SEPARATOR)
  end

  def format_row(row, col_widths)
    row.map.with_index { |cell, i|
      i == 0 ? cell.ljust(col_widths[i]) : cell.rjust(col_widths[i])
    }.join(COLUMN_SEPARATOR)
      .rstrip
  end
end
