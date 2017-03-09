# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'leganto_sync/version'

Gem::Specification.new do |spec|
  spec.name          = "leganto_sync"
  spec.version       = LegantoSync::VERSION
  spec.authors       = ["Digital Innovation, Lancaster University Library"]
  spec.email         = ["library.dit@lancaster.ac.uk"]

  spec.summary       = %q{Alma/Leganto synchronisation with Lancaster University data sources}
  spec.description   = %q{This gem provides utilities for loading and synchronising reading list and related data
                       between Lancaster University data sources (LUSI) and the Alma back-end to Leganto.}
  spec.homepage      = "https://github.com/lulibrary/leganto_sync"
  spec.license       = "MIT"

  # Prevent pushing this gem to RubyGems.org. To allow pushes either set the 'allowed_push_host'
  # to allow pushing to a single host or delete this section to allow pushing to any host.
  if spec.respond_to?(:metadata)
    spec.metadata['allowed_push_host'] = "TODO: Set to 'http://mygemserver.com'"
  else
    raise "RubyGems 2.0 or newer is required to protect against public gem pushes."
  end

  spec.files         = `git ls-files -z`.split("\x0").reject { |f| f.match(%r{^(test|spec|features)/}) }
  spec.bindir        = "exe"
  spec.executables   = spec.files.grep(%r{^exe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "loofah", "~> 2.0.3"
  spec.add_dependency "net-ldap", "~> 0.15.0"
  spec.add_dependency "writeexcel", "~> 1.0.5"

  spec.add_development_dependency "bundler", "~> 1.12"
  spec.add_development_dependency "dotenv", "~> 2.1.2"
  spec.add_development_dependency "rake", "~> 10.0"
  spec.add_development_dependency "minitest", "~> 5.0"
  spec.add_development_dependency "minitest-reporters"

end
