Gem::Specification.new do |s|
  s.name        = "gnomon-postgres"
  s.version     = "1.0.2"
  s.summary     = "Branches, time travel and merges for PostgreSQL apps (gnomon): pg helpers, Rails middleware, RSpec branches per example"
  s.authors     = ["Gnomon contributors"]
  s.license     = "PostgreSQL"
  s.homepage    = "https://github.com/bitsinfra/gnomon"
  s.metadata    = { "source_code_uri" => "https://github.com/bitsinfra/gnomon", "bug_tracker_uri" => "https://github.com/bitsinfra/gnomon/issues" }
  s.files       = Dir["lib/**/*.rb"]
  s.add_dependency "pg", ">= 1.4"
  s.add_development_dependency "activerecord", ">= 6.1"
  s.add_development_dependency "rspec", "~> 3.12"
end
