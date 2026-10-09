# Multiple ractors each build a large live set and then terminate.
# The final live sets of dead ractors are garbage after death. Measured
# retention shows how much of that memory a full GC fails to reclaim.

Warning[:experimental] = false

require_relative "../../harness/loader"

DEAD_SET_ITEMS = Integer(ENV.fetch("RACTOR_DEAD_SET_ITEMS", 100_000))

run_benchmark(3, scenario: true) do |num_ractors|
  worker_ids = {}
  num_ractors.times do |worker_id0|
    ractor = Ractor.new(worker_id0, DEAD_SET_ITEMS) do |worker_id, items|
      measure_worker_gc do
        keep = []
        i = 0
        while i < items
          keep << "worker #{worker_id} item #{i} " + ("y" * 100)
          i += 1
        end
        keep.size
      end
    end
    worker_ids[ractor] = worker_id0
  end

  # Harvest in completion order, so a worker that finishes early is not held
  # alive waiting on a slower worker ahead of it.
  total = 0
  pending = worker_ids.keys
  until pending.empty?
    worker, (size, sample) = Ractor.select(*pending)
    pending.delete(worker)
    record_worker_gc(worker_ids.fetch(worker), sample)
    total += size
  end
  raise "unexpected dead-set size" unless total == num_ractors * DEAD_SET_ITEMS
  nil
end
