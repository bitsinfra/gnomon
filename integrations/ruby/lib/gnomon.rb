# Helpers for apps on a PostgreSQL database with the gnomon extension.
# A branch is the gnomon.branch setting plus (in SQL-only mode) the routing search_path;
# gnomon.use() sets both for a session, gnomon.begin() for one transaction (poolers).
require "securerandom"

module Gnomon
  module_function

  # The routing schema of a user schema; scratch branches have their own (__s).
  def routing_schema(schema = "public", scratch: false)
    "gnomon_r_#{schema}#{scratch ? '__s' : ''}"
  end

  def branch_options(branch, c_module: false, schemas: ["public"], as_of: nil, scratch: false)
    opts = ["-c gnomon.branch=#{branch}"]
    opts << "-c gnomon.as_of=#{as_of}" if as_of
    opts << "-c search_path=#{schemas.flat_map { |s| [routing_schema(s, scratch: scratch), s] }.join(',')}" unless c_module
    opts.join(" ")
  end

  # The options the database computes for a branch (gnomon.connection_options): unlike
  # branch_options it knows the branch's kind, a confined role's mask profile and the branch's
  # schema version.
  def connection_options(conn, branch, c_module: false)
    q(conn, "select gnomon.connection_options($1, $2) as o", [branch, c_module]).first["o"]
  end

  # Works with a PG::Connection or anything that responds to exec_params (or exec_query).
  def q(conn, sql, params = [])
    if conn.respond_to?(:exec_params)
      conn.exec_params(sql, params).to_a
    else
      conn.exec_query(sql, "gnomon", params).to_a
    end
  end

  def use(conn, branch = "main", as_of = nil)
    q(conn, "select gnomon.use($1, $2) as path", [branch, as_of]).first["path"]
  end

  def create_branch(conn, name, parent: "main", scratch: false, at: nil)
    q(conn, "select gnomon.create_branch($1, $2, $3, $4) as id", [name, parent, scratch ? "scratch" : "logged", at]).first["id"].to_i
  end

  def create_scratch(conn, prefix = "test", parent = "main")
    name = "#{prefix}-#{Process.pid.to_s(16)}-#{SecureRandom.hex(4)}"
    create_branch(conn, name, parent: parent, scratch: true)
    name
  end

  def drop_branch(conn, name, cascade: true)
    q(conn, "select gnomon.drop_branch($1, $2)", [name, cascade])
  end

  def diff(conn, a, b = nil)
    q(conn, "select tbl::text as table, key, kind, col, old, new from gnomon.diff($1, $2)", [a, b])
  end

  def merge(conn, source, target = nil)
    id = q(conn, "select gnomon.merge($1, $2) as id", [source, target]).first["id"]
    q(conn, "select id, status, stats from gnomon.merge where id = $1", [id]).first
  end

  # One transaction on a branch (a PG::Connection).
  def with_branch(conn, branch, as_of: nil)
    conn.transaction do |c|
      q(c, "select gnomon.begin($1, $2)", [branch, as_of])
      yield c
    end
  end
end
