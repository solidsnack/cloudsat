DROP SCHEMA cloudsat CASCADE;
CREATE EXTENSION "uuid-ossp"; -- Needed for stored procedure. Loaded here so
                              -- we fail before making any changes to the
                              -- database if it's not available.
CREATE SCHEMA cloudsat;
SET search_path TO cloudsat,public;


CREATE TABLE messages
( uuid      uuid PRIMARY KEY,
  timestamp timestamp with time zone NOT NULL,
  poster    text NOT NULL,
  chan      text NOT NULL,
  message   text NOT NULL );
CREATE INDEX ON messages (timestamp);
CREATE INDEX ON messages USING hash(poster);
CREATE INDEX ON messages USING hash(chan);
CREATE INDEX ON messages USING gist(to_tsvector('english', message));

CREATE TABLE threads
( before      uuid NOT NULL REFERENCES messages(uuid),
  disposition disposition NOT NULL,
  after       uuid NOT NULL REFERENCES messages(uuid) );
 -- Foreign key allows us to cascade deletes of old messages.
CREATE INDEX ON threads (before);
CREATE INDEX ON threads USING hash(disposition);
CREATE INDEX ON threads (after);
COMMENT ON TABLE threads IS 'Links messages with their replies.';

CREATE TABLE registered
( procpid       integer NOT NULL,
  backend_start timestamp with time zone NOT NULL,
  timestamp     timestamp with time zone NOT NULL,
  chans         text[] NOT NULL );
CREATE INDEX ON registered (procpid);
CREATE INDEX ON registered (backend_start);
CREATE INDEX ON registered (timestamp);
CREATE INDEX ON registered (chans);
COMMENT ON TABLE registered IS
 'Explicit information about connected clients and their subscriptions.';

CREATE TYPE disposition AS ENUM
( 'ignored', 'acknowledged', 'info', 'problem', 'done' );


CREATE FUNCTION post(poster text, chan text, message text)
RETURNS uuid AS $$
DECLARE
  id    uuid := uuid_generate_v1();
  chan_ text := norm(chan);
BEGIN
  INSERT INTO messages VALUES (id, NOW(), norm(poster), chan_, message); 
  PERFORM pg_notify(chan_, id::text);
  RETURN id;
END;
$$ LANGUAGE plpgsql STRICT;
COMMENT ON FUNCTION post(poster text, chan text, message text) IS
 'Creates a new thread on the message board with an initial message.';

CREATE FUNCTION reply
( poster text, chan text, message text, parent uuid, disposition disposition )
RETURNS uuid AS $$
DECLARE
  id uuid;
BEGIN
  id := post(poster, chan, message);
  INSERT INTO threads VALUES (parent, disposition, id);
  RETURN id;
END;
$$ LANGUAGE plpgsql STRICT;
COMMENT ON FUNCTION reply
(poster text, chan text, message text, parent uuid, disposition disposition) IS
 'Posts a reply in an existing thread, under the given message.';

CREATE FUNCTION posts(chans text[])
RETURNS SETOF messages AS $$
SELECT * FROM messages WHERE chan = ANY ($1);
$$ LANGUAGE sql STRICT;
COMMENT ON FUNCTION posts(chans text[]) IS
 'Searches for posts in the given channels.';

CREATE FUNCTION register(addresses text[])
RETURNS VOID AS $$
BEGIN
  PERFORM subscribe(suffixes(addresses));
END;
$$ LANGUAGE plpgsql STRICT;
COMMENT ON FUNCTION register(addresses text[]) IS
 'Create subscriptions and register client.';

CREATE FUNCTION subscribe(chans text[])
RETURNS VOID AS $$
DECLARE
  chan text;
BEGIN
  FOREACH chan IN ARRAY chans LOOP
    EXECUTE 'LISTEN ' || quote_ident(chan);
  END LOOP;
END;
$$ LANGUAGE plpgsql STRICT;
COMMENT ON FUNCTION subscribe(chans text[]) IS
 'Creates subscriptions for a list of channels.';


CREATE FUNCTION norm(address text)
RETURNS text AS $$
BEGIN
  RETURN trim(leading '.' from lower(trim(trailing '.' from address))) || '.';
END;
$$ LANGUAGE plpgsql IMMUTABLE;
COMMENT ON FUNCTION norm(address text) IS
 'Normalize an address so it is lowercase and has the final dot.';

CREATE FUNCTION suffixes(address text)
RETURNS text[] AS $$
DECLARE
  str text := norm(address);
  pos int;
  res text[];
  dot text := '.';
  at  text := '@';
BEGIN
  res := res || str;
  pos := position(at in str);      -- Clip leading local@ part.
  IF pos > 0
  THEN
    str := substring(str from pos+1);
    res := res || str;
  END IF;
  LOOP
    pos := position(dot in str);
    str := substring(str from pos+1);
    EXIT WHEN '' = str;
    res := res || str;
  END LOOP;
  res := res || dot;
  RETURN res;
END;
$$ LANGUAGE plpgsql IMMUTABLE;
COMMENT ON FUNCTION suffixes(address text) IS
 'Break an address like admin@example.com into rooted pieces like this:
  {com., example.com., admin@example.com.}';

CREATE FUNCTION suffixes(addresses text[])
RETURNS text[] AS $$
DECLARE
  acc     text[];
  address text;
BEGIN
  FOREACH address IN ARRAY addresses LOOP
    acc := acc || suffixes(address);
  END LOOP;
  RETURN uniq(acc);
END;
$$ LANGUAGE plpgsql IMMUTABLE;
COMMENT ON FUNCTION suffixes(addresses text[]) IS
 'Returns the unions of all suffixes of all the addresses.';

CREATE FUNCTION uniq(ANYARRAY)
RETURNS ANYARRAY AS $$
SELECT ARRAY( SELECT DISTINCT $1[s.i] FROM
              generate_series(array_lower($1,1), array_upper($1,1)) AS s(i) );
$$ LANGUAGE sql IMMUTABLE;
COMMENT ON FUNCTION uniq(ANYARRAY) IS
 'Ensures an array contains no duplicates.';


CREATE TABLE locks
( locked    uuid PRIMARY KEY,
  locking   uuid NOT NULL );
COMMENT ON TABLE locks IS
 'A message may "lock" another as when a message announces a node\'s intention
  to process a certain job. This is handled by a separate function and table
  and it is intended to be replaceable.'

CREATE FUNCTION locking_reply
( poster text, chan text, message text, parent uuid, disposition disposition )
RETURNS uuid AS $$
DECLARE
  id uuid;
BEGIN
  SELECT * FROM locks WHERE locked = parent;
  IF FOUND
  THEN RAISE unique_violation USING
             MESSAGE = 'This message has already been locked.';
  END IF;
  id := reply(poster, chan, message, parent, disposition);
  INSERT INTO locks VALUES (parent, id);
  RETURN id;
END;
$$ LANGUAGE plpgsql STRICT;
COMMENT ON FUNCTION locking_reply
(poster text, chan text, message text, parent uuid, disposition disposition) IS
 'Locks the given message and posts a reply in one step. To be used as a way of
  atomically accepting a job, for example.';

