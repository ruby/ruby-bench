class Stats
  class << self
    # Welch's t-test (two-tailed). Returns the p-value, or nil if
    # either sample is too small to compute a meaningful test.
    def welch_p_value(a, b)
      return nil if a.size < 2 || b.size < 2

      stats_a = new(a)
      stats_b = new(b)

      n_a = a.size.to_f
      n_b = b.size.to_f
      var_a = stats_a.sample_variance
      var_b = stats_b.sample_variance

      se_sq = var_a / n_a + var_b / n_b
      if se_sq == 0.0
        # Both samples have zero variance — if means match they're
        # indistinguishable, otherwise they're trivially different.
        return stats_a.mean == stats_b.mean ? 1.0 : 0.0
      end

      t = (stats_a.mean - stats_b.mean) / Math.sqrt(se_sq)

      # Welch-Satterthwaite degrees of freedom
      df = se_sq ** 2 / ((var_a / n_a) ** 2 / (n_a - 1) + (var_b / n_b) ** 2 / (n_b - 1))

      # Two-tailed p-value: I_x(df/2, 1/2) where x = df/(df + t^2)
      x = df / (df + t * t)
      regularized_incomplete_beta(x, df / 2.0, 0.5)
    end

    private

    # Regularized incomplete beta function I_x(alpha, beta) via continued fraction (Lentz's method).
    # Returns the probability that a Beta(alpha, beta)-distributed variable is <= x.
    def regularized_incomplete_beta(x, alpha, beta)
      return 0.0 if x <= 0.0
      return 1.0 if x >= 1.0

      # Symmetry relation: pick the side that converges faster
      if x > (alpha + 1.0) / (alpha + beta + 2.0)
        return 1.0 - regularized_incomplete_beta(1.0 - x, beta, alpha)
      end

      # B(alpha, beta) * x^alpha * (1-x)^beta — computed in log-space to avoid overflow
      ln_normalizer = Math.lgamma(alpha + beta)[0] - Math.lgamma(alpha)[0] - Math.lgamma(beta)[0] +
                      alpha * Math.log(x) + beta * Math.log(1.0 - x)
      normalizer = Math.exp(ln_normalizer)

      normalizer * beta_continued_fraction(x, alpha, beta) / alpha
    end

    # Evaluates the continued fraction for I_x(alpha, beta) using Lentz's algorithm.
    # Each iteration computes two sub-steps (even and odd terms of the fraction).
    def beta_continued_fraction(x, alpha, beta)
      floor = 1.0e-30 # prevent division by zero in Lentz's method
      converged = false

      numerator_term = 1.0
      denominator_term = 1.0 - (alpha + beta) * x / (alpha + 1.0)
      denominator_term = floor if denominator_term.abs < floor
      denominator_term = 1.0 / denominator_term
      fraction = denominator_term

      (1..200).each do |iteration|
        two_i = 2 * iteration

        # Even sub-step: d_{2m} coefficient of the continued fraction
        coeff = iteration * (beta - iteration) * x / ((alpha + two_i - 1.0) * (alpha + two_i))
        denominator_term = 1.0 + coeff * denominator_term
        denominator_term = floor if denominator_term.abs < floor
        numerator_term = 1.0 + coeff / numerator_term
        numerator_term = floor if numerator_term.abs < floor
        denominator_term = 1.0 / denominator_term
        fraction *= denominator_term * numerator_term

        # Odd sub-step: d_{2m+1} coefficient of the continued fraction
        coeff = -(alpha + iteration) * (alpha + beta + iteration) * x / ((alpha + two_i) * (alpha + two_i + 1.0))
        denominator_term = 1.0 + coeff * denominator_term
        denominator_term = floor if denominator_term.abs < floor
        numerator_term = 1.0 + coeff / numerator_term
        numerator_term = floor if numerator_term.abs < floor
        denominator_term = 1.0 / denominator_term
        correction = denominator_term * numerator_term
        fraction *= correction

        if (correction - 1.0).abs < 1.0e-10
          converged = true
          break
        end
      end

      warn "Stats.beta_continued_fraction: did not converge (alpha=#{alpha}, beta=#{beta}, x=#{x})" unless converged
      fraction
    end
  end

  def initialize(data)
    @data = data
  end

  def min
    @data.min
  end

  def max
    @data.max
  end

  def mean
    @data.sum(0.0) / @data.size
  end

  # Population standard deviation (N denominator) — describes these specific values.
  def stddev
    mean = self.mean
    diffs_squared = @data.map { |v| (v-mean) * (v-mean) }
    mean_squared = diffs_squared.sum(0.0) / @data.size
    Math.sqrt(mean_squared)
  end

  # Unbiased sample variance (N-1 denominator, Bessel's correction) — for inference.
  def sample_variance
    m = mean
    @data.sum { |v| (v - m) ** 2 } / (@data.size - 1).to_f
  end

  def median
    compute_median(@data)
  end

  def median_absolute_deviation(median)
    compute_median(@data.map { |v| (v - median).abs })
  end

  private

  def compute_median(data)
    size = data.size
    sorted = data.sort
    if size.odd?
      sorted[size/2]
    else
      (sorted[size/2-1] + sorted[size/2]) / 2.0
    end
  end
end
