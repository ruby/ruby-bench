require_relative '../harness/harness-common'

Warning[:experimental] = false
ENV["YJIT_BENCH_RACTOR_HARNESS"] = "1"

RACTORS = [
  0, # without ractor
  1, 2, 4, 6, 8, 12, 16, 32
].freeze

unless Ractor.method_defined?(:join)
  class Ractor
    def join
      take
      self
    end
    alias value take
  end
end

def run_benchmark(num_itrs_hint, ractor_args: [], &block)
  warmup_itrs = Integer(ENV.fetch('WARMUP_ITRS', 10))
  bench_itrs = Integer(ENV.fetch('MIN_BENCH_ITRS', num_itrs_hint))
  # { num_ractors => [itr_in_ms, ...] }
  stats = Hash.new { |h,k| h[k] = [] }

  header = "r:   itr:   time"
  puts header

  i = 0
  while i < warmup_itrs
    args = if ractor_args.empty?
      []
    else
      Ractor.make_shareable(ractor_args, copy: true)
    end
    block.call *args
    i += 1
  end

  blk = Ractor.make_shareable(block)
  RACTORS.each do |rs|
    num_itrs = 0
    while num_itrs < bench_itrs
      # copy args before we begin measuring the time so it's not included
      shareable_args = ractor_args.empty? ? [] : Ractor.make_shareable(ractor_args, copy: true)
      before = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      if rs.zero?
        block.call *shareable_args
      else
        rs_list = []
        rs.times do
          rs_list << Ractor.new(*shareable_args, &block)
        end
        while rs_list.any?
          r, _obj = Ractor.select(*rs_list)
          rs_list.delete(r)
        end
      end
      num_itrs += 1
      time = Process.clock_gettime(Process::CLOCK_MONOTONIC) - before
      time_ms = (1000 * time).to_i
      itr_str = "%-3s %4s %6s" % ["#{rs}", "##{num_itrs}:", "#{time_ms}ms"]
      stats[rs] << time_ms
      puts itr_str
    end
  end
  return_results([], stats.values.flatten)
end

Ractor.make_shareable(self)
