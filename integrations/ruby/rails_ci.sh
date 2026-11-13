#!/bin/bash
# A real Rails app on a branch: rails new, a scaffold migrated on main, then the
# app's own requests and models on a branch through Gnomon::Rails::Middleware (session mode and
# transaction-pooling mode), main untouched until the merge. CI runs it after
# `gem install rails`; it uses the dev cluster unless PGHOST/PGPORT say otherwise (54330: the C
# module, where ActiveRecord reads main's catalog as it is).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
export PGHOST=${PGHOST:-$ROOT/build} PGPORT=${PGPORT:-54329} PGUSER=${PGUSER:-postgres}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
APP=$WORK/shop
DB=gn_rails
psql -X -q -d postgres -c "drop database if exists $DB" -c "create database $DB"
psql -X -q -d $DB -c "set client_min_messages=warning" -c "create extension gnomon cascade"

rails new "$APP" --database=postgresql --minimal --skip-git --skip-test --skip-bundle --quiet
cd "$APP"
echo "gem \"gnomon-postgres\", path: \"$ROOT/integrations/ruby\", require: [\"gnomon\", \"gnomon/rails\"]" >> Gemfile
bundle install --quiet
cat > config/database.yml <<YML
default: &default
  adapter: postgresql
  host: $PGHOST
  port: $PGPORT
  username: $PGUSER
  database: $DB
development:
  <<: *default
test:
  <<: *default
YML
echo 'Rails.application.config.middleware.use Gnomon::Rails::Middleware' > config/initializers/gnomon.rb
export RAILS_ENV=test
bin/rails generate scaffold Product name:string price:decimal --quiet
bin/rails db:migrate
psql -X -q -d $DB -c "select gnomon.track('public.products')" -c "select gnomon.create_branch('rails-ci')" >/dev/null

mkdir -p script
cat > script/gnomon_ci.rb <<'RUBY'
require "rack/mock"

def check(cond, what)
  raise "FAILED: #{what}" unless cond
  puts "ok - #{what}"
end

def request(method, path, branch: nil, **opts)
  env = { "HTTP_HOST" => "localhost" }
  env["HTTP_X_GNOMON_BRANCH"] = branch if branch
  Rack::MockRequest.new(Rails.application).request(method, path, env.merge(opts))
end

def on(branch)
  Gnomon::Rails.use(branch)
  yield
ensure
  Gnomon::Rails.use("main")
end

check Product.count == 0, "main starts empty"

# a form post through the middleware, on the branch
res = request("POST", "/products", branch: "rails-ci", params: { product: { name: "lamp", price: "9.50" } })
check res.status == 302, "POST /products on the branch redirects (#{res.status})"
id = res.location[%r{/products/(\d+)}, 1]
check id, "the redirect names the new record"

check Product.count == 0, "main does not see the branch's record"
check request("GET", "/products/#{id}", branch: "rails-ci").body.include?("lamp"), "the show page on the branch"
check request("GET", "/products/#{id}").status == 404, "the show page on main is a 404"

on("rails-ci") do
  p = Product.find(id)                                # find needs the primary key
  check p.name == "lamp", "find on the branch"
  p.update!(price: 12)
  Product.transaction do
    Product.create!(name: "desk", price: 100)
    raise ActiveRecord::Rollback
  end
  check Product.count == 1, "a rolled-back transaction on the branch leaves nothing"
  Product.create!(name: "chair", price: 40)
  Product.where(name: "chair").delete_all
  check Product.pluck(:name) == ["lamp"], "create and delete on the branch"
end

# transaction pooling mode: the request is one transaction opened with gnomon.begin
Gnomon::Rails.transaction_pooling = true
res = request("POST", "/products", branch: "rails-ci", params: { product: { name: "rug", price: "30" } })
check res.status == 302, "POST in transaction-pooling mode"
Gnomon::Rails.transaction_pooling = false
check Product.count == 0, "main still empty"
on("rails-ci") { check Product.order(:name).pluck(:name) == %w[lamp rug], "both records on the branch" }

merge = ActiveRecord::Base.connection.select_value("select gnomon.merge('rails-ci')")
status = ActiveRecord::Base.connection.select_value("select status from gnomon.merge where id = #{merge.to_i}")
check status == "applied", "merge into main (#{status})"
Product.reset_column_information
check Product.order(:name).map { |p| [p.name, p.price.to_i] } == [["lamp", 12], ["rug", 30]], "main has the branch's records after the merge"
RUBY
bin/rails runner script/gnomon_ci.rb
