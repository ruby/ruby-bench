require_relative '../../harness/loader'
require_relative "lib/optcarrot"

ROM_PATH = File.join(__dir__, "examples/Lan_Master.nes").freeze
ENV["WARMUP_ITRS"] = "1"

run_benchmark(10) do
  nes = Optcarrot::NES.new(["-b", "--no-print-video-checksum", ROM_PATH])
  nes.cpu.load!
  nes.reset
  200.times { nes.step }
end
