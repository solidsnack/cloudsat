require 'yaml'
require 'socket'

require 'pg'

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
    register(@addresses)
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
    @connection.wait_for_notify do |chan, _, data|
      parsed = Message.parse(data)
      yield parsed if parsed
    end
  end
  def array(args, type)
    args_ = args.map{|s| "'#{@connection.escape(s)}'" }.join(', ')
    "ARRAY[#{args_}]::#{type}[]"
  end
  def fetch(*messages, &block)
    as_args = messages.map{|s| "'#{@connection.escape(s)}'" }.join(', ')
    s = <<SELECT
SELECT * FROM cloudsat.messages WHERE uuid = ANY (#{array(messages, 'uuid')});
SELECT
    @connection.exec(s, &block)
  end
  def inbox(&block)
    q =<<SQL
SELECT uuid, iso8601utc(timestamp) AS timestamp, poster, chan, message
  FROM cloudsat.inbox LIMIT 64;
SQL
    @connection.exec(q) do |res|
      res.each(&block)
    end
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

module Message
UUID_RE = /[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}/
extend self
def yaml(message)
  "---\n" + %w| uuid timestamp poster chan message |.map do |k|
              YAML.dump(k=>message[k]).lines.to_a[1..-1]
            end.join('')
end
def parse(s)
  meta, message = s.split(' // ', 2);
  uuid, date, time, tz, poster, chan = meta.split(' ');
  if [uuid, date, time, tz, poster, chan, message].all? and UUID_RE.match(uuid)
    { 'uuid'=>uuid, 'timestamp'=>"#{date} #{time} #{tz}",
      'poster'=>poster, 'chan'=>chan,
      'message'=>message }
  end
end
end

end
