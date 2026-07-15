# frozen_string_literal: true

# Regenerate the committed LiquidIL-generated Ruby sample from templates.yml.
#
# LiquidIL (https://github.com/tobi/liquid-il) compiles a Liquid template to
# standalone Ruby (Template#to_ruby), inlining static partials so the result
# renders with no file_system. This script compiles each template in
# templates.yml to a module under generated/, writes its render assigns to
# fixtures/, and validates the standalone module reproduces the template's
# expected output. benchmark.rb then renders those committed modules in a hot
# loop, so the exact Ruby the JIT compiles lives in the repo and does not drift
# with the compiler.
#
#   BUNDLE_GEMFILE=$PWD/Gemfile bundle exec ruby extract.rb
#
# The generated/ and fixtures/ output is committed; you only need to re-run
# this when templates.yml or the pinned LiquidIL version changes.

require "json"
require "yaml"
require "liquid_il"

HERE    = __dir__
GEN_DIR = File.join(HERE, "generated")
FIX_DIR = File.join(HERE, "fixtures")

# Compile-time file system for the templates' inline partials. Static partials
# are inlined into the caller, so the generated Ruby holds no reference to it.
class SpecFileSystem
  def initialize(files) = @files = files || {}
  def read_template_file(name, _context = nil)
    @files.fetch(name.to_s) { raise LiquidIL::FileSystemError, "no such partial: #{name}" }
  end
end

def module_name_for(name)
  "LiquidILBench" + name.split(/[^a-zA-Z0-9]/).reject(&:empty?).map(&:capitalize).join
end

def deep_dup(obj)
  case obj
  when Hash  then obj.each_with_object({}) { |(k, v), h| h[k] = deep_dup(v) }
  when Array then obj.map { |v| deep_dup(v) }
  else obj
  end
end

Dir.mkdir(GEN_DIR) unless Dir.exist?(GEN_DIR)
Dir.mkdir(FIX_DIR) unless Dir.exist?(FIX_DIR)

specs    = YAML.safe_load(File.read(File.join(HERE, "templates.yml")), aliases: true).fetch("specs")
manifest = []

specs.each do |spec|
  name = spec.fetch("name")
  mod  = module_name_for(name)

  ctx      = LiquidIL::Context.new(file_system: SpecFileSystem.new(spec["filesystem"]))
  template = ctx.parse(spec.fetch("template"))
  ruby     = template.to_ruby(mod)

  # Validate the standalone module in an isolated namespace, no file_system.
  probe = Module.new
  probe.module_eval(ruby, "generated/#{name}.rb")
  produced = probe.const_get(mod).render(deep_dup(spec["environment"] || {}))
  expected = spec["expected"]
  if expected && produced != expected
    raise "#{name}: generated Ruby output does not match expected"
  end

  File.write(File.join(GEN_DIR, "#{name}.rb"), ruby)
  File.write(File.join(FIX_DIR, "#{name}.json"), JSON.pretty_generate(spec["environment"] || {}) + "\n")
  manifest << { "spec" => name, "module" => mod, "ruby_bytes" => ruby.bytesize }
  printf("  ok  %-32s %6d B\n", name, ruby.bytesize)
end

File.write(File.join(HERE, "manifest.json"), JSON.pretty_generate(manifest) + "\n")
puts "Extracted #{manifest.size} module(s); #{manifest.sum { |m| m["ruby_bytes"] }} B generated Ruby."
