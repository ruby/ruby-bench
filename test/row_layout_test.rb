require_relative 'test_helper'
require_relative '../lib/row_layout'

describe FlatRowLayout do
  before { @layout = FlatRowLayout.new }

  it 'adds no extra columns' do
    assert_empty @layout.extra_header_columns
    assert_empty @layout.extra_format_columns
  end

  it 'yields one entry per bench name with the name as the only label cell' do
    entries = @layout.entries(['fib', 'loop'])

    assert_equal ['fib', 'loop'], entries.map(&:data_key)
    assert_equal [['fib'], ['loop']], entries.map(&:label_cells)
  end

  it 'maps a data key to itself as the base name' do
    assert_equal 'fib', @layout.base_name('fib')
  end
end

describe RactorRowLayout do
  before do
    @groups = [
      ['symbol-name-ractor', [
        ["symbol-name-ractor\x000", 0],
        ["symbol-name-ractor\x002", 2]
      ]],
      ['gvl', [
        ["gvl\x001", 1]
      ]]
    ]
    @layout = RactorRowLayout.new(groups: @groups)
  end

  it 'adds a ractors column with a string format' do
    assert_equal ['ractors'], @layout.extra_header_columns
    assert_equal ['%s'], @layout.extra_format_columns
  end

  it 'yields one entry per (bench, count) keyed by the synthetic data key' do
    entries = @layout.entries(["symbol-name-ractor\x000", "symbol-name-ractor\x002", "gvl\x001"])

    assert_equal(
      ["symbol-name-ractor\x000", "symbol-name-ractor\x002", "gvl\x001"],
      entries.map(&:data_key)
    )
  end

  it 'shows the bench name on the first row of a group and blanks the rest' do
    entries = @layout.entries(["symbol-name-ractor\x000", "symbol-name-ractor\x002", "gvl\x001"])

    assert_equal(
      [
        ['symbol-name-ractor', '0'],
        ['', '2'],
        ['gvl', '1']
      ],
      entries.map(&:label_cells)
    )
  end

  it 'follows the supplied benchmark order' do
    entries = @layout.entries(["gvl\x001", "symbol-name-ractor\x000", "symbol-name-ractor\x002"])

    assert_equal(
      ["gvl\x001", "symbol-name-ractor\x000", "symbol-name-ractor\x002"],
      entries.map(&:data_key)
    )
  end

  it 'normalizes a synthetic data key back to its base benchmark name' do
    assert_equal 'symbol-name-ractor', @layout.base_name("symbol-name-ractor\x002")
  end
end
