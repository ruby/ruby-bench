require_relative 'test_helper'
require_relative '../misc/stats'

describe Stats do
  describe '#sample_variance' do
    it 'computes unbiased sample variance (n-1 denominator)' do
      stats = Stats.new([2.0, 4.0, 4.0, 4.0, 5.0, 5.0, 7.0, 9.0])
      assert_in_delta 4.571, stats.sample_variance, 0.001
    end

    it 'equals population variance * n/(n-1)' do
      data = [10.0, 12.0, 14.0, 16.0, 18.0]
      stats = Stats.new(data)
      n = data.size.to_f
      assert_in_delta stats.stddev ** 2 * n / (n - 1), stats.sample_variance, 1e-10
    end
  end

  describe '.welch_p_value' do
    it 'returns 1.0 for identical distributions' do
      a = [1.0, 1.0, 1.0, 1.0, 1.0]
      b = [1.0, 1.0, 1.0, 1.0, 1.0]
      assert_in_delta 1.0, Stats.welch_p_value(a, b), 0.001
    end

    it 'returns small p-value for clearly different distributions' do
      a = [100.0, 101.0, 99.0, 100.5, 99.5, 100.2, 99.8, 100.1, 99.9, 100.3]
      b = [50.0, 51.0, 49.0, 50.5, 49.5, 50.2, 49.8, 50.1, 49.9, 50.3]
      p_value = Stats.welch_p_value(a, b)
      assert p_value < 0.001, "Expected p < 0.001, got #{p_value}"
    end

    it 'returns high p-value for overlapping distributions' do
      a = [10.0, 11.0, 9.0, 10.5, 9.5]
      b = [10.1, 10.9, 9.1, 10.6, 9.4]
      p_value = Stats.welch_p_value(a, b)
      assert p_value > 0.5, "Expected p > 0.5, got #{p_value}"
    end

    it 'is symmetric' do
      a = [100.0, 102.0, 98.0, 101.0, 99.0]
      b = [90.0, 92.0, 88.0, 91.0, 89.0]
      assert_in_delta Stats.welch_p_value(a, b), Stats.welch_p_value(b, a), 1e-10
    end

    it 'handles different sample sizes' do
      a = [100.0, 101.0, 99.0]
      b = [50.0, 51.0, 49.0, 50.5, 49.5, 50.2, 49.8, 50.1, 49.9, 50.3]
      p_value = Stats.welch_p_value(a, b)
      assert p_value < 0.001, "Expected p < 0.001, got #{p_value}"
    end

    it 'handles unequal variances' do
      a = [100.0, 100.0, 100.0, 100.0, 100.0]  # zero variance
      b = [50.0, 60.0, 40.0, 70.0, 30.0]        # high variance
      p_value = Stats.welch_p_value(a, b)
      assert p_value < 0.05, "Expected p < 0.05, got #{p_value}"
    end

    it 'returns 0.0 when both samples have zero variance but different means' do
      a = [10.0, 10.0, 10.0, 10.0, 10.0]
      b = [5.0, 5.0, 5.0, 5.0, 5.0]
      assert_equal 0.0, Stats.welch_p_value(a, b)
    end

    it 'returns nil when a sample has fewer than 2 elements' do
      assert_nil Stats.welch_p_value([10.0], [5.0, 6.0, 7.0])
      assert_nil Stats.welch_p_value([5.0, 6.0, 7.0], [10.0])
      assert_nil Stats.welch_p_value([10.0], [5.0])
    end
  end
end
