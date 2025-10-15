require_relative "../../harness/loader"

require "json"
require "strscan"

class JSONParser < StringScanner
  def initialize(source)
    if source.respond_to?(:to_str)
      source = source.to_str
    else
      raise TypeError, "#{source.inspect} is not like a string"
    end

    if source.encoding != ::Encoding::ASCII_8BIT
      source = source.encode(::Encoding::UTF_8)
      source.force_encoding(::Encoding::ASCII_8BIT)
    end

    super(source)
    @current_nesting = 0
  end

  def parse
    skip(/\s*/)
    value = parse_item

    skip(/\s*/)
    raise JSON::ParserError, "unexpected tokens after value" unless eos?

    value
  end

  private

  def parse_item
    case
    when scan(/"((?:[^\x0-\x1f"\\]|\\["\\\/bfnrt]|\\u[0-9a-fA-F]{4}|\\[\x20-\x21\x23-\x2e\x30-\x5b\x5d-\x61\x63-\x65\x67-\x6d\x6f-\x71\x73\x75-\xff])*)"/n)
      string = self[1]
      return string if string.empty?

      string.gsub!(%r{(?:\\[\\bfnrt"/]|(?:\\u(?:[A-Fa-f\d]{4}))+|\\[\x20-\xff])}n) do |c|
        case c.getbyte(1)
        when 98 # b
          "\b"
        when 102 # f
          "\f"
        when 110 # n
          "\n"
        when 114 # r
          "\r"
        when 116 # t
          "\t"
        when 117 # \uXXXX
          bytes = String.new(encoding: Encoding::ASCII_8BIT)
          i = 0
          while c[i] == "\\" && c[i + 1] == "u"
            bytes << c[i + 2, 2].to_i(16) << c[i + 4, 2].to_i(16)
            i += 6
          end
          JSON.iconv("utf-8", "utf-16be", bytes).force_encoding(::Encoding::ASCII_8BIT)
        else
          c[1]
        end
      end

      string.force_encoding(::Encoding::UTF_8)
      string
    when skip("{")
      @current_nesting += 1
      if @current_nesting > 100
        raise JSON::NestingError, "nesting of #{@current_nesting} is too deep"
      end

      values = {}
      skip(/\s*/)

      if skip("}")
        @current_nesting -= 1
        return values
      end

      while true
        key = parse_item
        raise JSON::ParserError, "expected a string key" unless key.is_a?(String)
        raise JSON::ParserError, "expected a ':' to follow the string key" unless skip(/\s*:\s*/)

        values[key] = parse_item
        skip(/\s*/)

        case
        when skip(",")
          skip(/\s*/)
        when skip("}")
          @current_nesting -= 1
          return values
        else
          raise JSON::ParserError, "expected ',' or '}' after object value"
        end
      end
    when skip("[")
      @current_nesting += 1
      if @current_nesting > 100
        raise JSON::NestingError, "nesting of #{@current_nesting} is too deep"
      end

      values = []
      skip(/\s*/)

      if skip("]")
        @current_nesting -= 1
        return values
      end

      while true
        values << parse_item
        skip(/\s*/)

        case
        when skip(",")
          skip(/\s*/)
        when skip("]")
          @current_nesting -= 1
          return values
        else
          raise JSON::ParserError, "expected ',' or ']' after array value"
        end
      end
    when skip("true")
      true
    when skip("false")
      false
    when skip("null")
      nil
    when scan(/-?(?:0|[1-9]\d*)((?:\.\d+)?(?:[Ee][-+]?\d+)?)?/)
      self[1] ? Float(self[0]) : Integer(self[0])
    else
      raise JSON::ParserError, "unexpected token at #{pos}: '#{peek(1)}'"
    end
  end
end

# Public domain football data taken from:
# https://github.com/openfootball/football.json/blob/master/2011-12/at.1.json
SOURCE = Ractor.make_shareable(IO.read("#{__dir__}/data.json"))

run_benchmark(10) { source = SOURCE; 100.times { JSONParser.new(source).parse } }
