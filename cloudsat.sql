DROP SCHEMA cloudsat CASCADE;
CREATE EXTENSION "uuid-ossp"; -- Needed for stored procedure. Loaded here so
                              -- we fail before making any changes to the
                              -- database if it's not available.
CREATE SCHEMA cloudsat;
SET search_path TO cloudsat,public;


 ------------------------------------------------------------------------------
 -------------------------- Core Types & Functions ----------------------------
 ------------------------------------------------------------------------------

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

CREATE TYPE disposition AS ENUM
( 'ignored', 'acknowledged', 'info', 'problem', 'done' );

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
( nick          text NOT NULL,
  procpid       integer NOT NULL,
  backend_start timestamp with time zone NOT NULL,
  timestamp     timestamp with time zone NOT NULL,
  chans         text[] NOT NULL );
CREATE INDEX ON registered (name);
CREATE INDEX ON registered (procpid);
CREATE INDEX ON registered (backend_start);
CREATE INDEX ON registered (timestamp);
CREATE INDEX ON registered (chans);
COMMENT ON TABLE registered IS
 'Explicit information about connected clients and their subscriptions.';

CREATE VIEW recent AS
SELECT nick, procpid, backend_start, timestamp, chans FROM
( SELECT registered.*, rank()
    OVER (PARTITION BY nick ORDER BY timestamp DESC) FROM registered
) AS intermediate WHERE rank = 1;
COMMENT ON VIEW recent IS
 'Most up to date record for each registered (or unregistered) client.';

CREATE VIEW connections AS
WITH r AS
( SELECT nick, procpid, backend_start, timestamp, chans FROM
  ( SELECT recent.*, rank()
      OVER (PARTITION BY procpid ORDER BY timestamp DESC) FROM recent
  ) AS intermediate WHERE rank = 1 )
SELECT * FROM r NATURAL JOIN pg_stat_activity;
COMMENT ON VIEW connections IS
 'Connection info for every active client.';

CREATE FUNCTION post(poster text, address text, message text)
RETURNS uuid AS $$
DECLARE
  id    uuid := uuid_generate_v1();
  chan  text := norm(nonlocal(address));
BEGIN
  INSERT INTO messages VALUES (id, now(), norm(poster), chan, message);
  PERFORM pg_notify(chan, id::text||' '||address);
  RETURN id;
END;
$$ LANGUAGE plpgsql STRICT;
COMMENT ON FUNCTION post(poster text, address text, message text) IS
 'Creates a new thread on the message board with an initial message.';

CREATE FUNCTION reply
(poster text, address text, message text, parent uuid, disposition disposition)
RETURNS uuid AS $$
DECLARE
  id uuid;
BEGIN
  id := post(poster, address, message);
  INSERT INTO threads VALUES (parent, disposition, id);
  RETURN id;
END;
$$ LANGUAGE plpgsql STRICT;
COMMENT ON FUNCTION reply
(poster text, address text, message text, parent uuid, disposition disposition)
IS 'Posts a reply in an existing thread, under the given message.';

CREATE FUNCTION posts()
RETURNS SETOF messages AS $$
SELECT messages.*
  FROM messages, pg_listening_channels()
 WHERE chan = pg_listening_channels;
$$ LANGUAGE sql STRICT;
COMMENT ON FUNCTION posts(chans text[]) IS
 'Searches for posts which match the present connections subscriptions.';

CREATE FUNCTION posts(text[])
RETURNS SETOF messages AS $$
SELECT * FROM messages WHERE chan = ANY ($1);
$$ LANGUAGE sql STRICT;
COMMENT ON FUNCTION posts(text[]) IS
 'Searches for posts in the given channels.';

CREATE FUNCTION messages(uuid[])
RETURNS SETOF messages AS $$
SELECT * FROM messages WHERE uuid = ANY ($1);
$$ LANGUAGE sql STRICT;
COMMENT ON FUNCTION messages(uuid[]) IS
 'Retrieve messages by UUID.';

CREATE FUNCTION register(addresses text[])
RETURNS text[] AS $$
DECLARE
  empty    text[] := ARRAY[]::text[];
  nick     text   := addresses[1];
  suffixes text[] := suffixes(addresses);
  pid      integer;
  t        timestamp with time zone;
  stale    text[];
  chan     text;
BEGIN
  SELECT procpid, backend_start
    FROM pg_stat_activity
   WHERE procpid = pg_backend_pid()
    INTO STRICT pid, t;
  SELECT array_agg(pg_listening_channels)
    FROM pg_listening_channels()
   WHERE NOT pg_listening_channels = ANY (suffixes)
    INTO STRICT stale;
  IF NOT stale = empty THEN
    FOREACH chan IN ARRAY stale LOOP
      EXECUTE 'UNLISTEN ' || quote_ident(chan);
    END LOOP;
  END IF;
  IF NOT addresses = empty THEN
    PERFORM subscribe(suffixes);
    INSERT INTO registered VALUES (nick, pid, t, now(), suffixes);
  END IF;
  RETURN suffixes;
END;
$$ LANGUAGE plpgsql STRICT;
COMMENT ON FUNCTION register(addresses text[]) IS
 'Create subscriptions and register client. The first address shall be taken to
  to be the "name" of the client.';

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
 'Create subscriptions for a list of channels.';


 ------------------------------------------------------------------------------
 ------------------------- Utilities for Addresses ----------------------------
 ------------------------------------------------------------------------------

CREATE FUNCTION norm(address text)
RETURNS text AS $$
BEGIN
  RETURN trim(leading '.' from lower(trim(trailing '.' from address))) || '.';
END;
$$ LANGUAGE plpgsql IMMUTABLE;
COMMENT ON FUNCTION norm(address text) IS
 'Normalize an address so it is lowercase and has the final dot.';

CREATE FUNCTION nonlocal(address text)
RETURNS text AS $$
BEGIN
  RETURN substring(address from position('@' in address)+1);
END;
$$ LANGUAGE plpgsql IMMUTABLE;
COMMENT ON FUNCTION nonlocal(address text) IS
 'Remove the local part of an address.';

CREATE FUNCTION suffixes(address text)
RETURNS text[] AS $$
DECLARE
  str text := norm(nonlocal(address));
  pos int;
  res text[];
  dot text := '.';
BEGIN
  res := res || str;
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


 ------------------------------------------------------------------------------
 ----------------------- Advisory Locks for Messages --------------------------
 ------------------------------------------------------------------------------

CREATE TABLE lock_log
( locked    uuid NOT NULL,
  locking   uuid NOT NULL,
  timestamp timestamp with time zone NOT NULL,
  sets_lock bool NOT NULL );
CREATE INDEX ON lock_log (timestamp);
CREATE INDEX ON lock_log USING hash(locked);
CREATE INDEX ON lock_log USING hash(locking);
COMMENT ON TABLE lock_log IS
 'Audit log of successful locks and unlocks of messages.';

CREATE VIEW locks AS SELECT locked, locking, timestamp FROM
( SELECT lock_log.*, rank()
    OVER (PARTITION BY locked ORDER BY timestamp DESC) FROM lock_log
) AS intermediate WHERE sets_lock AND rank = 1;
COMMENT ON VIEW locks IS 'Messages with active locks.';

CREATE FUNCTION locking
( poster text, chan text, message text, parent uuid, disposition disposition )
RETURNS uuid AS $$
BEGIN
  RETURN set_or_unset_lock(poster, chan, message, parent, disposition, TRUE);
END;
$$ LANGUAGE plpgsql STRICT;
COMMENT ON FUNCTION locking
(poster text, chan text, message text, parent uuid, disposition disposition) IS
 'Try to lock a message and reply to it. If a lock is possible, the UUID of
  the stored reply is returned. If not, the null UUID is returned and nothing
  is stored.';

CREATE FUNCTION unlocking
( poster text, chan text, message text, parent uuid, disposition disposition )
RETURNS uuid AS $$
BEGIN
  RETURN set_or_unset_lock(poster, chan, message, parent, disposition, FALSE);
END;
$$ LANGUAGE plpgsql STRICT;
COMMENT ON FUNCTION unlocking
(poster text, chan text, message text, parent uuid, disposition disposition) IS
 'Try to unlock a message and reply to it. If it is locked, then the lock is
  unset, a new reply is stored and its UUID is returned. If the message is
  already unlocked, then the null UUID is returned.';

CREATE FUNCTION set_or_unset_lock
( poster text, chan text, message text, parent uuid, disposition disposition,
  setting bool )
RETURNS uuid AS $$
DECLARE
  id uuid;
BEGIN
  CASE EXISTS ( SELECT * FROM locks WHERE locked = parent )
  WHEN setting THEN
    -- We are trying lock a locked lock or unlock and unlocked lock.
    RETURN '00000000-0000-0000-0000-000000000000';
  ELSE
    id := reply(poster, chan, message, parent, disposition);
    INSERT INTO locks VALUES (parent, id, now(), setting);
    RETURN id;
  END CASE;
END;
$$ LANGUAGE plpgsql STRICT;
COMMENT ON FUNCTION set_or_unset_lock
( poster text, chan text, message text, parent uuid, disposition disposition,
  setting bool ) IS 'Implementation behind locking() and unlocking().';

