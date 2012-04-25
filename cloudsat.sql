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


CREATE FUNCTION post(poster text, chan text, message text)
RETURNS uuid AS $$
DECLARE
  id uuid;
BEGIN
  SELECT uuid_generate_v1() INTO id;
  INSERT INTO messages VALUES (id, NOW(), poster, chan, message); 
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
  SELECT post(poster, chan, message) INTO id;
  INSERT INTO threads VALUES (parent, disposition, id);
  RETURN id;
END;
$$ LANGUAGE plpgsql STRICT;
COMMENT ON FUNCTION reply
(poster text, chan text, message text, parent uuid, disposition disposition) IS
 'Posts a reply in an existing thread, under the given message.';

CREATE FUNCTION posts(chans text[])
RETURNS SETOF messages AS $$
BEGIN
  RETURN QUERY SELECT * FROM messages WHERE chan = ANY (chans);
END;
$$ LANGUAGE plpgsql STRICT;
COMMENT ON FUNCTION posts(chans text[]) IS
 'Searches for posts in the given channels.';

CREATE FUNCTION norm(address text)
RETURNS text AS $$
BEGIN
  RETURN lower(trim(trailing '.' from address)) || '.';
END;
$$ LANGUAGE plpgsql STRICT;
COMMENT ON FUNCTION norm(address text) IS
 'Normalize an address so it has the final dot.';

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
$$ LANGUAGE plpgsql STRICT;
COMMENT ON FUNCTION suffixes(address text) IS
 'Break an address like admin@example.com into rooted pieces like this:
  {com., example.com., admin@example.com.}';

