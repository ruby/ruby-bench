require_relative '../../lib/harness/loader'
Dir.chdir __dir__

# This is an Etanni translation of the Erb template in the Erubi
# ruby-bench benchmark.
TEMPLATE_FILE = "simple_template.etanni"

require "json"

# Note: Etanni, as written, isn't friendly to frozen-string-literal: true
# since it has that chomp! call. Can we fix that without compromising
# performance?

class Etanni
  SEPARATOR = "E69t116A65n110N78i105S83e101P80a97R82a97T84o111R82"
  CHOMP = "<<#{SEPARATOR}.chomp!"
  START = "\n_out_ << #{CHOMP}\n"
  STOP = "\n#{SEPARATOR}\n"
  REPLACEMENT = "#{STOP}\\1#{START}"

  def initialize(template, filename = '<Etanni>')
    @template = template
    @filename = filename
    compile
  end

  def compile(filename = @filename)
    temp = @template.strip
    temp.gsub!(/<\?r\s+(.*?)\s+\?>/m, REPLACEMENT)
    @compiled = eval("Proc.new{ _out_ = [#{CHOMP}]\n#{temp}#{STOP}_out_.join }",
      nil, @filename)
  end

  def result(instance, filename = @filename)
    instance.instance_eval(&@compiled)
  end
end


ETANNI_ENGINE = Etanni.new(File.read(TEMPLATE_FILE), TEMPLATE_FILE)
MAIN_OBJ = self
def run_etanni
  ETANNI_ENGINE.result(MAIN_OBJ)
end

# This is taken from actual "gem server" data
@values = JSON.load(File.read "gem_specs.json")
result = run_etanni

run_benchmark(25) do
  250.times do
    result = run_etanni
  end
end

