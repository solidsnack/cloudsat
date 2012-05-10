git_version = begin
  describe = `git describe --tags`
  if $?.success?
    stripped = describe.strip
    /^([^-]+)-([0-9]+)-[^-]+$/.match(stripped) ? "#{$1}.#{$2}" : stripped
  else
    git_raw = `git log --pretty=format:%h | head -n1`
    $?.success? ? '0.0.0.%d' % git_raw.strip.to_i(16) : '0.0.0'
  end
end
@spec = Gem::Specification.new do |s|
  s.name                     =  'cloudsat'
  s.author                   =  'Airbnb'
  s.email                    =  'contact@airbnb.com'
  s.homepage                 =  'https://github.com/airbnb/cloudsat'
  s.version                  =  git_version
  s.summary                  =  'Client library for cloudsat.'
  s.description              =  <<DESC
Client library and model bot for cloudsat, a message board for host management.
DESC
  s.license                  =  'BSD'
  s.add_dependency(             'pg'                                          )
  s.add_dependency(             'sqlite3'                                     )
  s.files                    =  Dir['lib/**/*.rb', 'README']
  s.require_path             =  'lib'
  s.bindir                   =  'bin'
  s.executables              =  %w| cloudbot |
end

