require "gnomon"

module Gnomon
  # ActiveRecord / Rails integration.
  #
  #   Gnomon::Rails.with_branch("feature") { User.update_all(...) }    # one transaction on a branch
  #   config.middleware.use Gnomon::Rails::Middleware                 # X-Gnomon-Branch header per request
  #
  # The middleware puts the request's connection on the branch with gnomon.use() and resets it
  # afterwards; with transaction pooling set Gnomon::Rails.transaction_pooling = true and the
  # request runs in one transaction opened with gnomon.begin().
  module Rails
    class << self
      attr_accessor :transaction_pooling, :header
    end
    self.transaction_pooling = false
    self.header = "HTTP_X_GNOMON_BRANCH"

    module_function

    def connection
      ::ActiveRecord::Base.connection
    end

    def exec(sql, binds)
      conn = connection.raw_connection
      conn.exec_params(sql, binds)
    end

    def with_branch(branch, as_of: nil)
      ::ActiveRecord::Base.transaction do
        exec("select gnomon.begin($1, $2)", [branch, as_of])
        yield
      end
    end

    def use(branch, as_of = nil)
      exec("select gnomon.use($1, $2)", [branch, as_of])
    end

    class Middleware
      def initialize(app)
        @app = app
      end

      def call(env)
        branch = env["gnomon.branch"] || env[Gnomon::Rails.header]
        return @app.call(env) if branch.nil? || branch.empty? || branch == "main"
        if Gnomon::Rails.transaction_pooling
          Gnomon::Rails.with_branch(branch) { @app.call(env) }
        else
          ::ActiveRecord::Base.connection_pool.with_connection do
            Gnomon::Rails.use(branch)
            begin
              @app.call(env)
            ensure
              Gnomon::Rails.use("main")
            end
          end
        end
      end
    end
  end
end

module Gnomon
  module Rails
    # ActiveRecord reads a table's primary key from the catalog at run time. On a branch in
    # SQL-only mode the table's name resolves to its routing view (gnomon_r_<schema>), and a view
    # has no primary key: ActiveRecord then refuses find(). The base table's key is the view's.
    module PrimaryKeys
      def primary_keys(table_name)
        pks = super
        return pks unless pks.empty?

        query_values(<<~SQL, "SCHEMA")
          SELECT a.attname FROM pg_index i
            JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY (i.indkey)
           WHERE i.indisprimary
             AND i.indrelid = _gnomon.base_rel(#{quote(quote_table_name(table_name))}::regclass)
           ORDER BY array_position(i.indkey::int2[], a.attnum)
        SQL
      rescue ::ActiveRecord::StatementInvalid
        pks
      end
    end
  end
end

begin
  require "active_record/connection_adapters/postgresql_adapter"
  ::ActiveRecord::ConnectionAdapters::PostgreSQLAdapter.prepend(Gnomon::Rails::PrimaryKeys)
rescue LoadError, NameError
  # no ActiveRecord PostgreSQL adapter here: nothing to teach
end
