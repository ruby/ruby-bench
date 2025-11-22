# frozen_string_literal: true

require 'rake/testtask'

desc 'Run all tests'
Rake::TestTask.new(:test) do |t|
  t.libs << 'test'
  t.libs << 'lib'
  test_files = FileList['test/**/*_test.rb']
  if RUBY_ENGINE == 'truffleruby'
    # rmagick segfaults on truffleruby 25.0.0
    test_files -= ['test/graph_renderer_test.rb']
  end
  t.test_files = test_files
  t.verbose = true
  t.warning = true
end

task default: :test
