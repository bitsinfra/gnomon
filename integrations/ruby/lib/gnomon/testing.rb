# The testing layer: snapshot assertions on a branch's diff, normalized as the
# specification says (sdk/spec/SPEC.md, Snapshots), with the golden files the TypeScript and
# Python SDKs check.
#
#   RSpec.describe "signup", gnomon: true do
#     it "writes a customer and an order" do
#       ...
#       expect(conn).to match_gnomon_snapshot          # GNOMON_UPDATE_SNAPSHOTS=1 to record
#     end
#   end
require "json"
require "fileutils"

module Gnomon
  module Testing
    module_function

    # JSON text with object keys sorted, compact (snapshots and digests share it across languages).
    def stable_json(v)
      JSON.generate(sorted(v))
    end

    def sorted(v)
      case v
      when Hash then v.keys.map(&:to_s).sort.to_h { |k| [k, sorted(v.key?(k) ? v[k] : v[k.to_sym])] }
      when Array then v.map { |x| sorted(x) }
      when Float then v == v.floor && v.abs < 1e15 ? v.to_i : v
      else v
      end
    end

    def short(t)
      t.split(".").last
    end

    def sort_key(k)
      k.keys.map(&:to_s).sort.map do |name|
        v = k[name]
        v.is_a?(Numeric) ? [0, v, ""] : [1, 0, v.to_s]
      end
    end

    # The diff rows (table, key, kind, col, old, new) as the snapshot's lines.
    def normalize_diff(diff, ignore: [], foreign_keys: [])
      rows = diff.map do |d|
        d = d.transform_keys(&:to_s)
        { "table" => d["table"].to_s, "key" => d["key"], "kind" => d["kind"], "col" => d.key?("column") ? d["column"] : d["col"],
          "old" => d["old"], "new" => d["new"] }
      end
      ignore = ignore.map(&:to_s)
      by_table = {}
      rows.each do |r|
        ks = (by_table[r["table"]] ||= [])
        ks << r["key"] unless ks.any? { |k| stable_json(k) == stable_json(r["key"]) }
      end
      ph = {}
      idx = {}
      by_table.each do |t, ks|
        ks.sort_by { |k| sort_key(k) }.each_with_index do |k, i|
          ph["#{t}|#{stable_json(k)}"] = "<#{short(t)}:#{i + 1}>"
          idx["#{t}|#{stable_json(k)}"] = i + 1
        end
      end
      fks = foreign_keys.map { |f| f.transform_keys(&:to_s) }
      value = lambda do |table, key, col, v|
        if key.size == 1 && key.key?(col)
          return ph.fetch("#{table}|#{stable_json(key)}", stable_json(v))
        end
        fks.each do |f|
          next unless f["table"] == table && f["columns"] == [col]
          p = ph["#{f['references']}|#{stable_json({ f['referenced_columns'][0] => v })}"]
          return p if p
        end
        stable_json(v)
      end
      lines = {}
      rows.each do |r|
        ident = "#{r['table']}|#{stable_json(r['key'])}"
        p = ph[ident]
        i = idx[ident]
        case r["kind"]
        when "delete"
          s = "#{r['table']} #{p} delete"
          lines[s] = [r["table"], i, s]
        when "insert"
          (r["new"] || {}).each do |c, v|
            next if ignore.include?(c.to_s)
            s = "#{r['table']} #{p} insert #{c} = #{value.call(r['table'], r['key'], c.to_s, v)}"
            lines[s] = [r["table"], i, s]
          end
        else
          next if r["col"].nil? || ignore.include?(r["col"])
          s = "#{r['table']} #{p} update #{r['col']}: #{value.call(r['table'], r['key'], r['col'], r['old'])} -> #{value.call(r['table'], r['key'], r['col'], r['new'])}"
          lines[s] = [r["table"], i, s]
        end
      end
      lines.values.sort.map { |x| x[2] }
    end

    FK_SQL = <<~SQL.freeze
      select format('%I.%I', n.nspname, c.relname) as tbl,
             (select array_to_json(array_agg(a.attname::text order by k.o)) from unnest(f.conkey) with ordinality k(n, o) join pg_attribute a on a.attrelid = f.conrelid and a.attnum = k.n) as cols,
             format('%I.%I', pn.nspname, p.relname) as ref,
             (select array_to_json(array_agg(a.attname::text order by k.o)) from unnest(f.confkey) with ordinality k(n, o) join pg_attribute a on a.attrelid = f.confrelid and a.attnum = k.n) as refcols
        from pg_constraint f join pg_class c on c.oid = f.conrelid join pg_namespace n on n.oid = c.relnamespace
        join pg_class p on p.oid = f.confrelid join pg_namespace pn on pn.oid = p.relnamespace where f.contype = 'f'
    SQL

    # A branch's diff as snapshot text.
    def branch_snapshot(conn, branch, ignore: [])
      diff = Gnomon.q(conn, "select tbl::text as tbl, key::text as key, kind, col, old::text as old, new::text as new from gnomon.diff($1)", [branch]).map do |r|
        t = r["tbl"]
        { "table" => t.include?(".") ? t : "public.#{t}", "key" => parse(r["key"]), "kind" => r["kind"], "col" => r["col"],
          "old" => parse(r["old"]), "new" => parse(r["new"]) }
      end
      fks = Gnomon.q(conn, FK_SQL).map do |r|
        { "table" => r["tbl"], "columns" => JSON.parse(r["cols"]), "references" => r["ref"], "referenced_columns" => JSON.parse(r["refcols"]) }
      end
      normalize_diff(diff, ignore: ignore, foreign_keys: fks).join("\n") + "\n"
    end

    def parse(s)
      s.nil? ? nil : JSON.parse(s, decimal_class: nil)
    end

    def current_branch(conn)
      Gnomon.q(conn, "select gnomon.current_branch() as b").first["b"]
    end

    # Raises unless the branch changed none of the tables (all of them by default).
    def assert_no_changes(conn, branch, tables: nil)
      hit = Gnomon.q(conn, "select tbl::text as tbl, key::text as key from gnomon.diff($1)", [branch])
                  .select { |r| tables.nil? || tables.any? { |x| r["tbl"] == x || r["tbl"].end_with?(".#{x}") } }
      raise "expected no changes, found #{hit.size}: #{hit.first(5)}" unless hit.empty?
    end

    # Raises unless the branch set table.column to value for the key.
    def assert_changed(conn, branch, table, key, column, value)
      rows = Gnomon.q(conn, "select kind, col, new::text as new from gnomon.diff($1, null, array[$2::regclass], $3::jsonb)",
                      [branch, table, stable_json([key])])
      ok = rows.any? do |r|
        n = parse(r["new"])
        (r["kind"] == "update" && r["col"] == column.to_s && n == value) ||
          (r["kind"] == "insert" && n.is_a?(Hash) && n[column.to_s] == value)
      end
      raise "#{table} #{stable_json(key)}: #{column} was not changed to #{value.inspect} on #{branch}" unless ok
    end

    def snapshot_path(example)
      file = example.metadata[:file_path] || "spec/unknown_spec.rb"
      dir = File.join(File.dirname(file), "__snapshots__")
      name = example.full_description.downcase.gsub(/[^a-z0-9]+/, "_").gsub(/^_|_$/, "")
      File.join(dir, "#{File.basename(file, '.rb')}__#{name}.snap")
    end
  end
end

if defined?(RSpec) && RSpec.respond_to?(:configure) && defined?(RSpec::Matchers)
  # expect(conn).to match_gnomon_snapshot                 (the session's branch)
  # expect(conn).to match_gnomon_snapshot(branch: "b", ignore: %w[created_at])
  RSpec::Matchers.define :match_gnomon_snapshot do |branch: nil, ignore: [], path: nil|
    match do |conn|
      example = RSpec.current_example
      @path = path || Gnomon::Testing.snapshot_path(example)
      @got = Gnomon::Testing.branch_snapshot(conn, branch || Gnomon::Testing.current_branch(conn), ignore: ignore)
      if ENV["GNOMON_UPDATE_SNAPSHOTS"] == "1" || !File.exist?(@path)
        FileUtils.mkdir_p(File.dirname(@path))
        File.write(@path, @got)
        next true
      end
      @want = File.read(@path)
      @got == @want
    end
    failure_message do
      "the branch's changes differ from #{@path}:\n--- stored\n#{@want}--- now\n#{@got}(GNOMON_UPDATE_SNAPSHOTS=1 records them)"
    end
  end
end
