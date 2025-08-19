# frozen_string_literal: true
require_relative '../harness/harness-common'

Warning[:experimental] = false
ENV["YJIT_BENCH_RACTOR_HARNESS"] = "1"

default_ractors = [
  0, # without ractor
  1, 2, 4, 6, 8, 12, 16, 32
]
if rs = ENV["YJIT_BENCH_RACTORS"]
  rs = rs.split(",").map(&:to_i) # If you want to include 0, you have to specify
  rs = rs.sort.uniq
  if rs.any?
    ractors = rs
  end
end
RACTORS = (ractors || default_ractors).freeze

unless Ractor.method_defined?(:join)
  class Ractor
    def join
      take
      self
    end
    alias value take
  end
end

MAX_ITERS = Integer(ENV.fetch("MAX_BENCH_ITRS", 5))

def run_benchmark(num_itrs_hint, ractor_args: [], &block)
  warmup_itrs = Integer(ENV.fetch('WARMUP_ITRS', 5))
  bench_itrs = Integer(ENV.fetch('MIN_BENCH_ITRS', num_itrs_hint))
  if bench_itrs > MAX_ITERS
    bench_itrs = MAX_ITERS
  end
  # { num_ractors => [itr_in_ms, ...] }
  stats = Hash.new { |h,k| h[k] = [] }

  header = "r:   itr:   time"
  puts header

  i = 0
  while i < warmup_itrs
    args = if ractor_args.empty?
      []
    else
      ractor_deep_dup(ractor_args)
    end
    block.call *([0] + args)
    i += 1
  end

  blk = Ractor.make_shareable(block)
  RACTORS.each do |rs|
    num_itrs = 0
    while num_itrs < bench_itrs
      before = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      if rs.zero?
        block.call *([rs] + ractor_deep_dup(ractor_args))
      else
        rs_list = []
        rs.times do
          rs_list << Ractor.new(*([rs] + ractor_args), &block)
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

def ractor_deep_dup(args)
  if Array === args
    ret = []
    args.each do |el|
      ret << ractor_deep_dup(el)
    end
    ret
  elsif Hash === args
    ret = {}
    args.each do |k,v|
      ret[ractor_deep_dup(k)] = ractor_deep_dup(v)
    end
    ret
  else
    args.dup
  end
end

Ractor.make_shareable(self)
