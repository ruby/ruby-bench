require_relative '../../lib/harness/loader'

ENV['RAILS_ENV'] ||= 'production'
ENV['RAILS_LOG_LEVEL'] ||= 'error' # Production logs every request to STDOUT at info.
ENV['SECRET_KEY_BASE'] ||= 'in general secret should not be in the git repo but this is a benchmark'
ENV['DISABLE_BOOTSNAP'] ||= '1' # Its bytecode cache in tmp/ would be shared by Ruby builds with the same RUBY_DESCRIPTION.

# db:prepare creates the four production SQLite databases and seeds the primary one.
# Iterations roll back their writes, so rows don't accumulate between runs.
Dir.chdir __dir__
use_gemfile extra_setup_cmd: "ruby bin/rails db:prepare" # Windows cannot run bin/rails by its shebang

# Fix the clock so the work doesn't depend on the date. It advances one second per
# visit, so updates write updated_at as they would in production.
START_TIME = Time.utc(2026, 7, 1, 12, 0, 0, 123456.789r).getlocal.freeze
REAL_NOW = Time.method(:now)
def Time.now = $now ? $now.dup : REAL_NOW.call

class Browser
  USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36"
  FORM_ACCEPT = "text/vnd.turbo-stream.html, text/html, application/xhtml+xml" # what Turbo sends on form submissions

  attr_accessor :cookie

  def initialize(app)
    @app = app
  end

  def get(path)
    request(path, method: "GET")
  end

  # Submits a form the way a browser does: POST with the form's token and, for PATCH and DELETE, _method.
  def submit(page, action, params = {}, method: nil)
    token = page[/<form [^>]*action="#{Regexp.escape(action)}"[^>]*>.*?name="authenticity_token" value="([^"]+)"/m, 1]
    raise "No form for #{action}" unless token
    params = params.merge(authenticity_token: token)
    params[:_method] = method if method
    request(action, method: "POST", params: params, "HTTP_ACCEPT" => FORM_ACCEPT)
  end

  private

  def request(path, method:, params: nil, **headers)
    env = Rack::MockRequest.env_for("http://localhost#{path}", method: method, params: params,
      "HTTP_USER_AGENT" => USER_AGENT, **headers)
    env["HTTP_COOKIE"] = cookie if cookie
    status, response_headers, body = @app.call(env)
    self.cookie = response_headers["set-cookie"].split(";", 2).first if response_headers["set-cookie"]
    text = +""
    body.each { |part| text << part }
    body.close if body.respond_to?(:close) # Response might be a Rack::BodyProxy and MUST be closed.
    [status, response_headers["location"], text]
  end
end

def expect(response, status, *markers, location: nil)
  actual_status, actual_location, body = response
  if actual_status != status || (location && actual_location != "http://localhost#{location}") ||
      (missing = markers.find { |marker| marker.is_a?(Regexp) ? body !~ marker : !body.include?(marker) })
    raise "Expected #{status} #{location} #{missing.inspect}, got #{actual_status} #{actual_location}: #{body[0, 300]}"
  end
  body
end

begin
  $now = START_TIME
  require_relative 'config/environment'

  app = Rails.application

  # Solid Cable 4 inserts broadcasts in batches from a writer thread. Insert each one
  # in the request instead, so it lands in the iteration's transaction and doesn't
  # depend on thread timing. This is the gem's own single-message insert.
  ActionCable.server.pubsub.instance_variable_set(:@broadcaster, SolidCable::Message)

  # Build a fixed, seeded sequence of visits. IDs are predictable because every
  # iteration rolls back to the same database, sqlite_sequence included.
  sequence = ->(table) { ActiveRecord::Base.with_connection { _1.select_value("SELECT seq FROM sqlite_sequence WHERE name = '#{table}'") }.to_i }
  next_article_id = sequence.("articles") + 1
  next_comment_id = sequence.("comments") + 1
  articles = Article.order(:id).to_h { |article| [article.id, { title: article.title, comments: article.comments.ids }] }

  rng = Random.new(0x1be52551fc152997)
  bodies = [
    "Turbo Streams deliver page changes as fragments of HTML wrapped in turbo-stream elements.",
    "SQLite is a good default for small apps: one file, no server, and WAL mode keeps readers off the writer's back.",
    "Validations run before every save, and callbacks run around it. Both are plain Ruby, so both are worth measuring.",
  ]
  weights = { show: 20, index: 10, show_json: 8, index_json: 4, create_article: 12, create_comment: 20,
              update_article: 8, invalid_article: 6, destroy_comment: 6, destroy_article: 6 }
  kinds = weights.flat_map { |kind, weight| [kind] * weight }
  visits = []
  # Seeding enqueues broadcast jobs too, so count from what's there.
  expected_messages = SolidCable::Message.count
  expected_jobs = SolidQueue::Job.count
  until visits.size == 200
    kind = kinds.sample(random: rng)
    id = articles.keys.sample(random: rng)
    case kind
    when :create_article
      title = "Article #{next_article_id}"
      visits << [kind, next_article_id, title, bodies.sample(random: rng)]
      articles[next_article_id] = { title: title, comments: [] }
      next_article_id += 1
      expected_jobs += 1 # broadcasts_to prepends it on the index later
    when :update_article
      articles[id][:title] = "#{articles[id][:title]} (edited)"
      visits << [kind, id, articles[id][:title], bodies.sample(random: rng)]
      expected_jobs += 1 # broadcasts_to replaces it later
    when :create_comment
      visits << [kind, id, next_comment_id, "Reader #{next_comment_id}", bodies.sample(random: rng)]
      articles[id][:comments] << next_comment_id
      next_comment_id += 1
      expected_jobs += 1 # broadcasts_to appends it later
      expected_messages += 1 # the article's comment count, replaced now
    when :destroy_comment
      next if articles[id][:comments].empty?
      visits << [kind, id, articles[id][:comments].sample(random: rng)]
      articles[id][:comments].delete(visits.last.last)
      expected_messages += 2 # broadcasts_to removes it, and the article's comment count
    when :destroy_article
      next if articles.size < 2
      visits << [kind, id]
      expected_messages += 1 + 2 * articles.delete(id)[:comments].size # dependent: :destroy removes each comment
    else
      visits << [kind, id]
    end
    visits.last << articles.size << articles.dig(visits.last[1], :comments)&.size
  end
ensure
  $now = nil
end

browser = Browser.new(app)
pools = ActiveRecord::Base.connection_handler.connection_pool_list(:writing)

run_benchmark(10) do
  # Roll back every write at the end of the iteration, as Rails tests do,
  # so each iteration starts from the same databases. pin_connection! opens the
  # transaction on Rails 8.1 but no longer does on main (rails/rails 9e8fe3955b).
  pinned = []
  began = []
  pools.each do |pool|
    pool.pin_connection!(false)
    pinned << pool
    connection = pool.lease_connection
    next if connection.transaction_open?
    connection.begin_transaction(joinable: false, _lazy: false)
    began << connection
  end
  browser.cookie = nil
  visits.each_with_index do |(kind, id, *args, count, comments), index|
    $now = START_TIME + index
    case kind
    when :index
      body = expect(browser.get("/articles"), 200, "<h1 class=\"font-bold text-4xl\">Articles</h1>")
      raise "Expected #{count} articles" unless body.scan('<div id="article_').size == count
    when :index_json
      body = expect(browser.get("/articles.json"), 200, /\A\[\{"id":/)
      raise "Expected #{count} articles" unless body.scan('"url":').size == count
    when :show
      body = expect(browser.get("/articles/#{id}"), 200, "<h2 class=\"text-xl font-bold mb-4\">Comments</h2>")
      raise "Expected #{comments} comments" unless body.scan('<div id="comment_').size == comments
    when :show_json
      expect(browser.get("/articles/#{id}.json"), 200, "{\"id\":#{id},\"title\":")
    when :create_article, :invalid_article
      page = expect(browser.get("/articles/new"), 200, "New article")
      if kind == :invalid_article
        response = browser.submit(page, "/articles", { article: { title: "", body: "Too short" } })
        expect(response, 422, "2 errors prohibited this article from being saved")
      else
        title, body = args
        response = browser.submit(page, "/articles", { article: { title: title, body: body } })
        expect(response, 302, location: "/articles/#{id}")
        expect(browser.get("/articles/#{id}"), 200, "Article was successfully created.", "<h1 class=\"font-bold text-4xl\">#{title}</h1>")
      end
    when :update_article
      title, body = args
      page = expect(browser.get("/articles/#{id}/edit"), 200, "Editing article")
      expect(browser.submit(page, "/articles/#{id}", { article: { title: title, body: body } }, method: "patch"),
        303, location: "/articles/#{id}")
      expect(browser.get("/articles/#{id}"), 200, "Article was successfully updated.", "#{title}</h1>")
    when :create_comment
      comment_id, commenter, body = args
      page = expect(browser.get("/articles/#{id}"), 200, "Add a Comment")
      expect(browser.submit(page, "/articles/#{id}/comments", { comment: { commenter: commenter, body: body } }),
        302, location: "/articles/#{id}")
      expect(browser.get("/articles/#{id}"), 200, "Comment was successfully created.", "<div id=\"comment_#{comment_id}\"")
    when :destroy_comment
      comment_id = args.first
      page = expect(browser.get("/articles/#{id}"), 200, "<div id=\"comment_#{comment_id}\"")
      expect(browser.submit(page, "/articles/#{id}/comments/#{comment_id}", method: "delete"), 302, location: "/articles/#{id}")
      body = expect(browser.get("/articles/#{id}"), 200, "Comment was successfully deleted.")
      raise "Comment #{comment_id} was not deleted" if body.include?("<div id=\"comment_#{comment_id}\"")
    when :destroy_article
      page = expect(browser.get("/articles/#{id}"), 200, "Destroy this article")
      expect(browser.submit(page, "/articles/#{id}", method: "delete"), 303, location: "/articles")
      body = expect(browser.get("/articles"), 200, "Article was successfully destroyed.")
      raise "Expected #{count} articles" unless body.scan('<div id="article_').size == count
    end
  end
  # The broadcasts ran: Turbo rendered and Solid Cable inserted the messages, and
  # Solid Queue holds the later broadcasts' jobs.
  unless SolidCable::Message.count == expected_messages && SolidQueue::Job.count == expected_jobs
    raise "Expected #{expected_messages} Solid Cable messages and #{expected_jobs} Solid Queue jobs, " \
      "got #{SolidCable::Message.count} and #{SolidQueue::Job.count}"
  end
ensure
  clean = pinned.map { |pool| pool.lease_connection.transaction_open? }.all?
  began.each { |connection| connection.rollback_transaction if connection.transaction_open? }
  pinned.each(&:unpin_connection!)
  $now = nil
  raise "A request ended the iteration's transaction" unless clean || $!
end
