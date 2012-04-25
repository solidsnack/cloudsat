CREATE EXTENSION "uuid-ossp"; -- Needed for stored procedure. Loaded here so
                              -- we fail before making any changes to the
                              -- database if it's not available.
CREATE SCHEMA cloudsat;
SET search_path TO cloudsat,public;


CREATE TABLE messages
( uuid      uuid PRIMARY KEY,
  timestamp timestamp with time zone NOT NULL,
  chan      text NOT NULL,
  poster    text NOT NULL,
  message   text NOT NULL );
CREATE INDEX ON messages (timestamp);
CREATE INDEX ON messages USING gist(to_tsvector('simple', chan));
CREATE INDEX ON messages USING gist(to_tsvector('simple', poster));
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
COMMENT ON FUNCTION post(poster text, chan text, message text)
     IS 'Creates a new thread on the message board with an initial message.';

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
( poster text, chan text, message text, parent uuid, disposition disposition )
     IS 'Posts a reply in an existing thread, under the given message.';

