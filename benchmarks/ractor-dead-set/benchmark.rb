# Multiple ractors each build a large live set and then terminate.
# The final live sets of dead ractors are garbage after death. Measured
# retention shows how much of that memory a full GC fails to reclaim.

Warning[:experimental] = false

require_relative "../../harness/loader"

DEAD_SET_ITEMS = Integer(ENV.fetch("RACTOR_DEAD_SET_ITEMS", 100_000))

run_benchmark(3) do |num_ractors|
  workers = num_ractors.times.map do |worker|
    Ractor.new(worker, DEAD_SET_ITEMS) do |worker_id, items|
      keep = []
      i = 0
      while i < items
        keep << "worker #{worker_id} item #{i} " + ("y" * 100)
        i += 1
      end
      keep.size
    end
  end

  total = workers.sum(&:value)
  raise "unexpected dead-set size" unless total == num_ractors * DEAD_SET_ITEMS
  nil
end
