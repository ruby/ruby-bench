require_relative '../../harness/loader'
require_relative "../../benchmarks/optcarrot/lib/optcarrot"

ROM_PATH = File.expand_path("../../benchmarks/optcarrot/examples/Lan_Master.nes", __dir__).freeze
# deep freeze all the constants

# rubocop:disable Lint/ShadowingOuterLocalVariable, Style/Semicolon
Optcarrot::Config::DEFAULT_OPTIONS.each {|k, v| k.freeze; v.freeze }.freeze
Optcarrot::Config::OPTIONS.each do |k, v|
  k.freeze
  v.each do |k, v|
    k.freeze
    v.each do |k, v|
      k.freeze
      if v.is_a?(Array)
        v.each {|v| v.freeze }
      end
      v.freeze
    end.freeze
  end.freeze
end.freeze
Optcarrot::Driver::DRIVER_DB.each do |k, v|
  k.freeze
  v.each {|k, v| k.freeze; v.freeze }.freeze
end.freeze
Optcarrot::Audio::PACK_FORMAT.each {|k, v| k.freeze; v.freeze }.freeze
Optcarrot::APU::Pulse::WAVE_FORM.each {|a| a.freeze }.freeze
Optcarrot::APU::Triangle::WAVE_FORM.freeze
Optcarrot::APU::FRAME_CLOCKS.freeze
Optcarrot::APU::OSCILLATOR_CLOCKS.each {|a| a.freeze }.freeze
Optcarrot::APU::LengthCounter::LUT.freeze
Optcarrot::APU::Noise::LUT.freeze
Optcarrot::APU::Noise::NEXT_BITS_1.each {|a| a.freeze }.freeze
Optcarrot::APU::Noise::NEXT_BITS_6.each {|a| a.freeze }.freeze
Optcarrot::APU::DMC::LUT.freeze
Optcarrot::PPU::DUMMY_FRAME.freeze
Optcarrot::PPU::BOOT_FRAME.freeze
Optcarrot::PPU::SP_PIXEL_POSITIONS.each {|k, v| k.freeze; v.freeze }.freeze
Optcarrot::PPU::TILE_LUT.each {|a| a.each {|a| a.each {|a| a.freeze }.freeze }.freeze }.freeze
Optcarrot::PPU::NMT_TABLE.each {|k, v| k.freeze; v.freeze }.freeze
Optcarrot::CPU::DISPATCH.each {|a| a.freeze }.freeze
Optcarrot::ROM::MAPPER_DB.freeze
# rubocop:enable Style/Semicolon

# rubocop:disable Style/MultilineBlockChain

run_benchmark(10) do
  nes = Optcarrot::NES.new(["-b", "--no-print-video-checksum", ROM_PATH])
  200.times { nes.step }
end
