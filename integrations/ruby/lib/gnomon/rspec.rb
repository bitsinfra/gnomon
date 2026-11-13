require "gnomon"

module Gnomon
  # RSpec: every example runs on its own scratch branch of one seeded database.
  #
  #   require "gnomon/rspec"
  #   RSpec.configure { |c| Gnomon::RSpec.install(c, -> { ActiveRecord::Base.connection.raw_connection }) }
  #
  # Tag an example group with `gnomon: false` to run it on main.
  module RSpec
    module_function

    def install(config, conn_proc, prefix: "rspec", keep: ENV["GNOMON_KEEP"] == "1")
      config.around(:each) do |example|
        if example.metadata[:gnomon] == false
          example.run
        else
          conn = conn_proc.call
          name = Gnomon.create_scratch(conn, prefix)
          Gnomon.use(conn, name)
          example.metadata[:gnomon_branch] = name
          begin
            example.run
          ensure
            Gnomon.use(conn, "main")
            Gnomon.drop_branch(conn, name) unless keep
          end
        end
      end
    end
  end
end
