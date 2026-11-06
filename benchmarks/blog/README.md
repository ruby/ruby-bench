# Blog benchmark

This is the blog app from Sam Ruby's
[`create-blog`](https://github.com/roundhouse-rb/roundhouse/blob/aa60799f53b36084c6311ffcda8f14e746eebf79/scripts/create-blog)
script in [roundhouse-rb/roundhouse](https://github.com/roundhouse-rb/roundhouse) (MIT or Apache-2.0, used here under
MIT, see [LICENSE](LICENSE)):
`rails new --css tailwind` plus Article and Comment scaffolds with comments nested under articles, validations,
Turbo broadcasts, jbuilder JSON and seeds. It runs the production defaults of `rails new`: SQLite, Solid Cache,
Solid Queue, Solid Cable, Propshaft, importmap, Turbo and Stimulus.

It was generated with `RAILS_NEW_VERSION=8.1.4.1 scripts/create-blog blog`, then `bin/rails db:migrate` to write
`db/schema.rb`. Changes after that:

- `config/master.key`, `config/credentials.yml.enc`, `.github/` and `.ruby-version` are removed; `benchmark.rb` sets
  `SECRET_KEY_BASE`. It also sets `DISABLE_BOOTSNAP`, so Ruby builds don't share Bootsnap's bytecode cache in `tmp/`.
- `config/environments/production.rb` sets `config.yjit = false`, so ruby-bench decides which JIT runs.
- `app/assets/builds/tailwind.css` is built and checked in, so the benchmark runs no Tailwind build. `.gitignore` is
  the one `rails new` writes without `--skip-git`, plus that file.
- `gem "image_processing"` is removed from the Gemfile. Nothing here touches images, and with it Active Storage loads
  libvips at boot when the host has it, so boot would depend on the machine.
- `Gemfile.lock` lists the `ruby` and `x86_64-linux` platforms, like the other benchmarks.
- This README and LICENSE.

## What an iteration does

`benchmark.rb` calls the app in-process with a fixed, seeded sequence of 200 visits: the index, article pages and
their JSON; creating, updating and deleting articles; adding and deleting comments; and a create that fails
validation with a 422. Each write first GETs the page with its form, submits that form's CSRF token the way a
browser does, and follows the redirect. Every response is checked for its status, and for a marker in the body or
the redirect's `Location`.

Each iteration runs in one transaction per database (primary, cache, queue and cable) that is rolled back at the
end, as in Rails tests, so every iteration starts from the same rows and gets the same IDs. While the app runs, the
clock starts at 2026-07-01 12:00 UTC and advances one second per visit, so updates still write `updated_at`.

Because the iteration's outer transaction is not joinable, each save runs as a savepoint, and its after-commit
callbacks run when the savepoint is released, as in Rails tests. They run in the same order relative to each write
as in production; what differs is SAVEPOINT/RELEASE in place of BEGIN IMMEDIATE/COMMIT. Nothing is ever committed,
so a real COMMIT and its WAL write are not measured.

Turbo renders the immediate broadcasts in the request and Solid Cable inserts them; `benchmark.rb` makes that insert
synchronous instead of batching it on Solid Cable's writer thread, which also skips Solid Cable's random autotrim.
The later broadcasts are enqueued into Solid Queue, and no worker runs them. Each iteration checks the number of
Solid Cable messages and Solid Queue jobs it wrote. Solid Cache is configured but the app doesn't use the cache.
Assets aren't precompiled, so Propshaft resolves their digested paths from its load path rather than a manifest.

An iteration holds write locks on the four SQLite files, so two processes can't run this benchmark from the same
directory at the same time.

The app uses the `sqlite3` C extension, so like lobsters and shipit it doesn't run on JRuby.
