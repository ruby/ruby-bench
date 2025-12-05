# frozen_string_literal: true

require_relative "../../lib/harness/loader"

Dir.chdir(__dir__)
use_gemfile

# This benchmark checks the Ruby LSP indexing mechanism, which is used to keep track of all project declarations in
# every file of a project and its dependencies

require "ruby_lsp/internal"

path = File.expand_path("fixture.rb", __dir__)
INDEX_PATH = make_shareable(RubyIndexer::IndexablePath.new(File.expand_path("../..", __dir__), path))
CONTENT = make_shareable(File.read(path))

run_benchmark(200) do
  RubyIndexer::Index.new.index_single(INDEX_PATH, CONTENT)
end
