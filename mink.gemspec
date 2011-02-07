require "./lib/mink"

Gem::Specification.new do |s|
  s.name = 'mink'

  s.version = Mink::VERSION

  s.platform = Gem::Platform::RUBY
  s.summary = 'MongoDB configuations on localhost made easy.'
  s.description = 'Set up MongoDB shard clusters and replica sets on localhost with ease.'

  s.require_paths = ['lib']

  s.files  = ['README.md', 'mink.gemspec', 'LICENSE.md', 'lib/mink.rb']
  s.files += Dir['lib/mink/**/*.rb']
  s.files += Dir['templates/**/*.yml']
  s.files += ['bin/mink']

  s.executables = ['mink']

  s.has_rdoc = false

  s.authors = ['Kyle Banker']
  s.email = 'kyle@10gen.com'

  s.add_dependency('mongo', ['>= 1.2.0'])
end
