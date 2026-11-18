require_relative 'test_helper'
require_relative '../lib/metric'

describe Metric do
  before do
    @ir = Metric.register('test_ir', noun: 'instruction count', unit: 'MIr', scale: 1e-6,
                                     better: 'fewer instructions', ratio_title: 'Instruction count ratio')
  end

  after do
    Metric::REGISTRY.delete('test_ir')
  end

  it 'reads wall time from the top-level series in milliseconds' do
    data = { 'warmup' => [0.5], 'bench' => [0.1, 0.2] }
    assert_equal [500.0], Metric::TIME.warmup(data)
    assert_equal [100.0, 200.0], Metric::TIME.bench(data)
  end

  it 'reads other metrics from the metrics hash in display units' do
    data = { 'bench' => [1.0], 'metrics' => { 'test_ir' => { 'bench' => [2_000_000, 3_000_000] } } }
    assert_equal [2.0, 3.0], @ir.bench(data)
    assert_nil @ir.warmup(data)
  end

  it 'takes the first iteration from warmup, falling back to bench only when warmup is empty' do
    assert_equal 500.0, Metric::TIME.first_iteration({ 'warmup' => [0.5], 'bench' => [0.1] })
    assert_equal 100.0, Metric::TIME.first_iteration({ 'warmup' => [], 'bench' => [0.1] })
    assert_nil @ir.first_iteration({ 'metrics' => { 'test_ir' => { 'bench' => [1] } } })
  end

  it 'compares on the primary metric only when every result agrees' do
    ir = { 'primary_metric' => 'test_ir' }
    assert_same @ir, Metric.for([ir, ir])
    assert_same Metric::TIME, Metric.for([ir, {}])
    assert_same Metric::TIME, Metric.for([])
  end

  it 'shows unregistered metrics in their raw unit' do
    metric = Metric['cycles']
    assert_equal 'cycles', metric.unit
    assert_equal [7], metric.bench({ 'metrics' => { 'cycles' => { 'bench' => [7] } } })
  end
end
