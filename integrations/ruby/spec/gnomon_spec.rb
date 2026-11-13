require "pg"
require "tmpdir"
begin
  require "logger"   # (ActiveSupport 6.1 needs Logger loaded first with newer concurrent-ruby)
  require "active_record"
rescue LoadError, StandardError
  # No ActiveRecord to load: exercise the Rails code through a minimal stand-in with the same
  # surface (Base.connection.raw_connection, transaction, connection_pool). CI loads the real one.
  module ActiveRecord
    class Base
      class << self
        attr_accessor :pg
        def connection
          Struct.new(:raw_connection).new(pg)
        end

        def transaction(&blk)
          pg.transaction { blk.call }
        end

        def connection_pool
          Struct.new(:c) do
            def with_connection
              yield c
            end

            def disconnect!
              c.close unless c.finished?
            end
          end.new(pg)
        end
      end
    end
  end
  STANDIN = true
end
require "gnomon"
require "gnomon/rails"
require "gnomon/rspec"

HOST = ENV["GNOMON_TEST_HOST"] || File.expand_path("../../../build", __dir__)
PORT = (ENV["GNOMON_TEST_PORT"] || 54329).to_i
DB = "rb_gnomon_test"

admin = PG.connect(host: HOST, port: PORT, user: "postgres", dbname: "postgres")
admin.exec("drop database if exists #{DB} with (force)")
admin.exec("create database #{DB}")
admin.close
seed = PG.connect(host: HOST, port: PORT, user: "postgres", dbname: DB)
seed.exec("set client_min_messages = warning; create extension gnomon")
seed.exec("create table accounts (id int primary key, name text not null, balance int not null default 0)")
seed.exec("insert into accounts select g, 'acct ' || g, 100 from generate_series(1, 10) g")
seed.exec("select gnomon.track('accounts')")
seed.close

if defined?(STANDIN)
  ActiveRecord::Base.pg = PG.connect(host: HOST, port: PORT, user: "postgres", dbname: DB)
  # a tiny Account model over the raw connection
  class Account
    Row = Struct.new(:id, :name, :balance) do
      def update!(attrs)
        attrs.each { |k, v| ActiveRecord::Base.pg.exec_params("update accounts set #{k} = $1 where id = $2", [v, id]) }
      end
    end
    def self.find(id)
      r = ActiveRecord::Base.pg.exec_params("select id, name, balance from accounts where id = $1", [id]).first
      Row.new(r["id"].to_i, r["name"], r["balance"].to_i)
    end
  end
else
  ActiveRecord::Base.establish_connection(adapter: "postgresql", host: HOST, port: PORT, username: "postgres", database: DB)
  class Account < ActiveRecord::Base; end
end

RSpec.configure do |c|
  Gnomon::RSpec.install(c, -> { ActiveRecord::Base.connection.raw_connection })
  c.after(:suite) do
    ActiveRecord::Base.connection_pool.disconnect!
    a = PG.connect(host: HOST, port: PORT, user: "postgres", dbname: "postgres")
    a.exec("drop database if exists #{DB} with (force)")
    a.close
  end
end

def main_conn
  PG.connect(host: HOST, port: PORT, user: "postgres", dbname: DB)
end

RSpec.describe "gnomon RSpec branches" do
  3.times do |n|
    it "isolates example #{n}" do |ex|
      expect(Account.find(1).balance).to eq(100)
      Account.find(1).update!(balance: 100 + n + 1)
      expect(Account.find(1).balance).to eq(101 + n)
      expect(ex.metadata[:gnomon_branch]).to start_with("rspec-")
    end
  end

  it "never reaches main", gnomon: false do
    c = main_conn
    expect(c.exec("select balance from accounts where id = 1").getvalue(0, 0).to_i).to eq(100)
    c.close
  end
end

RSpec.describe "ActiveRecord itself", gnomon: false do
  it "runs on real ActiveRecord when it can be loaded (CI)" do
    skip "ActiveRecord is not installed here" if defined?(STANDIN)
    expect(ActiveRecord::Base.connection.adapter_name).to eq("PostgreSQL")
    Gnomon.create_branch(ActiveRecord::Base.connection.raw_connection, "rb-ar")
    Gnomon.use(ActiveRecord::Base.connection.raw_connection, "rb-ar")
    Account.find(5).update!(name: "active record")
    expect(Account.where(name: "active record").count).to eq(1)
    Gnomon.use(ActiveRecord::Base.connection.raw_connection, "main")
    expect(Account.find(5).name).to eq("acct 5")
  end

  it "routing schemas for scratch branches" do
    expect(Gnomon.routing_schema("app", scratch: true)).to eq("gnomon_r_app__s")
    expect(Gnomon.branch_options("s", scratch: true)).to eq("-c gnomon.branch=s -c search_path=gnomon_r_public__s,public")
  end
end

RSpec.describe "helpers", gnomon: false do
  it "branch_options and a connection opened on a branch" do
    expect(Gnomon.branch_options("f")).to eq("-c gnomon.branch=f -c search_path=gnomon_r_public,public")
    c = main_conn
    Gnomon.create_branch(c, "rb-opts")
    b = PG.connect(host: HOST, port: PORT, user: "postgres", dbname: DB, options: Gnomon.branch_options("rb-opts"))
    b.exec("update accounts set name = 'ruby' where id = 2")
    expect(b.exec("select name from accounts where id = 2").getvalue(0, 0)).to eq("ruby")
    b.close
    expect(c.exec("select name from accounts where id = 2").getvalue(0, 0)).to eq("acct 2")
    expect(Gnomon.diff(c, "rb-opts").size).to eq(1)
    expect(Gnomon.merge(c, "rb-opts")["status"]).to eq("applied")
    expect(c.exec("select name from accounts where id = 2").getvalue(0, 0)).to eq("ruby")
    c.close
  end

  it "connection_options names the branch's schema version" do
    c = main_conn
    Gnomon.create_branch(c, "rb-sv")
    Gnomon.use(c, "rb-sv")
    c.exec("select gnomon.ddl($$alter table accounts add column tier text default 'basic'$$)")
    Gnomon.use(c, "main")
    opts = Gnomon.connection_options(c, "rb-sv")
    expect(opts).to match(/__v\d+/)
    b = PG.connect(host: HOST, port: PORT, user: "postgres", dbname: DB, options: opts)
    expect(b.exec("select tier from accounts where id = 1").getvalue(0, 0)).to eq("basic")
    b.close
    Gnomon.drop_branch(c, "rb-sv")
    c.close
  end

  it "with_branch is one transaction" do
    c = main_conn
    Gnomon.create_branch(c, "rb-tx")
    Gnomon.with_branch(c, "rb-tx") { |t| t.exec("update accounts set balance = 1 where id = 3") }
    expect(c.exec("select balance from accounts where id = 3").getvalue(0, 0).to_i).to eq(100)
    Gnomon.with_branch(c, "rb-tx") { |t| expect(t.exec("select balance from accounts where id = 3").getvalue(0, 0).to_i).to eq(1) }
    Gnomon.drop_branch(c, "rb-tx")
    c.close
  end

  it "Rails middleware routes a request by header and resets the connection" do
    Gnomon.create_branch(ActiveRecord::Base.connection.raw_connection, "rb-mw")
    app = ->(_env) { [200, {}, [Account.find(4).name]] }
    mw = Gnomon::Rails::Middleware.new(->(env) {
      Account.find(4).update!(name: "rails") if env["REQUEST_METHOD"] == "POST"
      app.call(env)
    })
    expect(mw.call("REQUEST_METHOD" => "POST", "HTTP_X_GNOMON_BRANCH" => "rb-mw")[2]).to eq(["rails"])
    expect(mw.call("REQUEST_METHOD" => "GET")[2]).to eq(["acct 4"])
    expect(mw.call("REQUEST_METHOD" => "GET", "HTTP_X_GNOMON_BRANCH" => "rb-mw")[2]).to eq(["rails"])
    Gnomon::Rails.transaction_pooling = true
    expect(mw.call("REQUEST_METHOD" => "GET", "HTTP_X_GNOMON_BRANCH" => "rb-mw")[2]).to eq(["rails"])
    Gnomon::Rails.transaction_pooling = false
  end
end

require "gnomon/testing"

RSpec.describe "snapshots", gnomon: false do
  it "normalizes the shared golden files as the other SDKs do" do
    Dir[File.expand_path("../../../sdk/spec/snapshot/*.json", __dir__)].sort.each do |f|
      g = JSON.parse(File.read(f))
      expect(Gnomon::Testing.normalize_diff(g["diff"], ignore: g["ignore"], foreign_keys: g["foreign_keys"])).to eq(g["expected"]), f
    end
  end

  it "match_gnomon_snapshot records a branch's diff, then compares with it" do
    c = main_conn
    Gnomon.create_branch(c, "rb-snap")
    Gnomon.use(c, "rb-snap")
    c.exec("update accounts set name = 'snap' where id = 3")
    path = File.join(Dir.mktmpdir, "rb.snap")
    expect(c).to match_gnomon_snapshot(path: path)
    expect(File.read(path)).to eq("public.accounts <accounts:1> update name: \"acct 3\" -> \"snap\"\n")
    expect(c).to match_gnomon_snapshot(path: path)
    c.exec("update accounts set name = 'other' where id = 4")
    expect(c).not_to match_gnomon_snapshot(path: path)
    Gnomon::Testing.assert_changed(c, "rb-snap", "accounts", { "id" => 3 }, "name", "snap")
    expect { Gnomon::Testing.assert_no_changes(c, "rb-snap") }.to raise_error(/expected no changes/)
    Gnomon.use(c, "main")
    Gnomon.drop_branch(c, "rb-snap")
    c.close
  end
end
