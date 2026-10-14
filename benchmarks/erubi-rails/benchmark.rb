require_relative '../../lib/harness/loader'
Dir.chdir __dir__
use_gemfile

ENV['RAILS_ENV'] ||= 'production'
# The SECRET_KEY_BASE isn't used for anything, but we have to have one.
ENV['SECRET_KEY_BASE'] = "1d1214a477334166ec542edb79047c7a042fb2b6dc90206d07b580615e0165c0371f365f20c93a06532b8462c11c0ce59da885734cb7b4e46805e2580b26ece5"
require_relative 'config/environment'

EXPECTED_TEXT_SIZE = 9369

app = Rails.application
fake_controller = FakeDiscourseController.new

run_benchmark(10) do
  10000.times do
    out = FakeDiscourseController.render :topics_show, assigns: fake_controller.stub_assigns
  end
end

# This benchmark will keep writing the production log on every request. It adds up.
# Let's not fill the disk.
File.unlink(File.join(__dir__, "log/#{ENV['RAILS_ENV']}.log")) rescue nil
