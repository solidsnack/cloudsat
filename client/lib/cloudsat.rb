require 'pg'

require 'socket'


module Cloudsat

class Err < StandardError ; end

class Bot
  attr_reader :addresses, :conninfo, :connection
  def initialize(addresses, conninfo)
    @addresses = addresses
    @conninfo  = conninfo
  end
  def nick
    @addresses[0]
  end
  def connect!
    @connection = PG.connect(@conninfo)
  end
  def connect
    connect!  unless @connection and @connection.status == PG::CONNECTION_OK
    raise Err unless                 @connection.status == PG::CONNECTION_OK
  end
  def join
    connect
    register(@addresses) do |res|
      require 'pp'
      pp res
      res.each{|t| pp t }
    end
  end
  def command(cmd, *args, &block)
    placeholders = (1..args.length).map{|n| "$#{n}" }.join(', ')
    escaped = @connection.quote_ident(cmd)
    s = "SELECT * FROM cloudsat.#{escaped}(#{placeholders});"
    @connection.exec(s, args, &block)
  end
  def command_with_array(cmd, args, type, &block)
    escaped = @connection.quote_ident(cmd)
    s = "SELECT * FROM cloudsat.#{escaped}(#{array(args, type)});"
    @connection.exec(s, &block)
  end
  def receive(&block) # The full bodies of all messages are retrieved.
    @connection.wait_for_notify do |chan, _, meta|
      uuid, poster = meta.split(' ');
      # Ignore notifications that aren't in the right format since we have
      # to look up a UUID in the end.
      if /[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}/.match(uuid) and poster
        fetch(uuid) do |res|
          # TODO: Do error handling here...
          res.each(&block)
        end
      end
    end
  end
  def array(args, type)
    args_ = args.map{|s| "'#{@connection.escape(s)}'" }.join(', ')
    "ARRAY[#{args_}]::#{type}[]"
  end
  def fetch(*messages, &block)
    as_args = messages.map{|s| "'#{@connection.escape(s)}'" }.join(', ')
    s = <<SELECT
SELECT * FROM cloudsat.messages WHERE ANY uuid = (#{array(messages, 'uuid')});
SELECT
    @connection.exec(s, &block)
  end
  def inbox(&block)
    @connection.exec('SELECT * FROM cloudsat.posts LIMIT 64;', &block)
  end
  def post(*args, &block)
    command('post', *([nick]+args), &block)
  end
  def reply(*args, &block)
    command('reply', *([nick]+args), &block)
  end
  def locking(*args, &block)
    command('locking', *([nick]+args), &block)
  end
  def unlocking(*args, &block)
    command('unlocking', *([nick]+args), &block)
  end
private
  def wrapped(cmd, *args, &block)
    command(cmd, *([nick]+args), &block)
  end
  def register(addresses, &block)
    STDERR.puts 'register'
    command_with_array('register', addresses, 'text', &block)
  end
end

end
