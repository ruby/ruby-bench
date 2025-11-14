# frozen_string_literal: true

# Filters benchmarks based on categories and name patterns
class BenchmarkFilter
  def initialize(categories:, name_filters:, metadata:)
    @categories = categories
    @name_filters = process_name_filters(name_filters)
    @metadata = metadata
    @category_cache = {}
  end

  def match?(entry)
    name = entry.sub(/\.rb\z/, '')
    matches_category?(name) && matches_name_filter?(name)
  end

  private

  def matches_category?(name)
    return true if @categories.empty?

    benchmark_categories = get_benchmark_categories(name)
    @categories.intersect?(benchmark_categories)
  end

  def matches_name_filter?(name)
    return true if @name_filters.empty?

    @name_filters.any? { |filter| filter === name }
  end

  def get_benchmark_categories(name)
    @category_cache[name] ||= begin
      benchmark_metadata = @metadata[name] || {}
      categories = [benchmark_metadata.fetch('category', 'other')]
      categories << 'ractor' if benchmark_metadata['ractor']
      categories
    end
  end

  # Process "/my_benchmark/i" into /my_benchmark/i
  def process_name_filters(name_filters)
    name_filters.map do |name_filter|
      if name_filter.start_with?("/")
        parse_regexp_filter(name_filter)
      else
        name_filter
      end
    end
  end

  def parse_regexp_filter(filter)
    regexp_str = filter[1..-1].reverse.sub(/\A(\w*)\//, "")
    regexp_opts = ::Regexp.last_match(1).to_s
    regexp_str.reverse!

    return Regexp.new(regexp_str) if regexp_opts.empty?

    # Convert option string to Regexp option flags
    flags = 0
    flags |= Regexp::IGNORECASE if regexp_opts.include?('i')
    flags |= Regexp::MULTILINE if regexp_opts.include?('m')
    flags |= Regexp::EXTENDED if regexp_opts.include?('x')

    Regexp.new(regexp_str, flags)
  end
end
