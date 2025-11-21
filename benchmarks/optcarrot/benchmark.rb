require_relative '../../harness/loader'
require_relative "lib/optcarrot"

if ENV["RUBY_BENCH_RACTOR_HARNESS"]
  # Based on bin/optcarrot-bench-parallel-on-ractor
  [
    Optcarrot::Config::DEFAULT_OPTIONS,
    Optcarrot::Config::OPTIONS,
    Optcarrot::Driver::DRIVER_DB,
    Optcarrot::Audio::PACK_FORMAT,
    Optcarrot::APU::Pulse::WAVE_FORM,
    Optcarrot::APU::Triangle::WAVE_FORM,
    Optcarrot::APU::FRAME_CLOCKS,
    Optcarrot::APU::OSCILLATOR_CLOCKS,
    Optcarrot::APU::LengthCounter::LUT,
    Optcarrot::APU::Noise::LUT,
    Optcarrot::APU::Noise::NEXT_BITS_1,
    Optcarrot::APU::Noise::NEXT_BITS_6,
    Optcarrot::APU::DMC::LUT,
    Optcarrot::PPU::DUMMY_FRAME,
    Optcarrot::PPU::BOOT_FRAME,
    Optcarrot::PPU::SP_PIXEL_POSITIONS,
    Optcarrot::PPU::TILE_LUT,
    Optcarrot::PPU::NMT_TABLE,
    Optcarrot::CPU::DISPATCH,
    Optcarrot::ROM::MAPPER_DB,
  ].each { |const| make_shareable(const) }

  ROM_PATH = File.join(__dir__, "examples/Lan_Master.nes").freeze
  ENV["WARMUP_ITRS"] = "1"

  run_benchmark(10) do
    nes = Optcarrot::NES.new(["-b", "--no-print-video-checksum", ROM_PATH])
    nes.reset

    200.times { nes.step }
  end
else
  rom_path = File.join(__dir__, "examples/Lan_Master.nes")
  nes = Optcarrot::NES.new(["--headless", rom_path])
  nes.reset

  run_benchmark(10) do
    200.times { nes.step }
  end
end
