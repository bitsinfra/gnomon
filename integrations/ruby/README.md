# gnomon-postgres (Ruby)

Helpers for apps on a PostgreSQL database with the gnomon extension: `pg` and ActiveRecord on a
branch, a Rack middleware for a branch per request, RSpec examples on scratch branches, and
snapshots of a branch's diff.

```ruby
require "gnomon"
conn = PG.connect(dbname: "shop", options: Gnomon.branch_options("feature"))  # sessions start on a branch
Gnomon.with_branch(conn, "feature") { conn.exec("update accounts set ...") }   # one transaction
Gnomon.connection_options(conn, "feature")    # what the database says the branch needs
```

`use`, `create_branch`, `create_scratch`, `drop_branch`, `diff`, `merge`. Rails:
`require "gnomon/rails"`, `Gnomon::Rails.with_branch(branch) { ... }` and the
`Gnomon::Rails::Middleware` (a branch per request from `X-Gnomon-Branch`); the routing views'
primary keys are taught to ActiveRecord.

RSpec:

```ruby
require "gnomon/rspec"
require "gnomon/testing"
RSpec.configure { |c| Gnomon::RSpec.install(c, -> { ActiveRecord::Base.connection.raw_connection }) }

it "cancels an order" do
  Order.find(1).cancel!
  expect(ActiveRecord::Base.connection.raw_connection).to match_gnomon_snapshot   # GNOMON_UPDATE_SNAPSHOTS=1 records
end
```

Every example runs on its own scratch branch; tag a group `gnomon: false` to run it on main.
`Gnomon::Testing.assert_no_changes` and `assert_changed` check a branch's diff directly. Snapshots
use the format and golden files the Python and TypeScript SDKs share.
