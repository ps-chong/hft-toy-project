-- Give every journal row its own key.
--
-- The key from 0001, (session_id, user_ref, event_type, occurred_at), was not
-- unique in practice: occurred_at defaults to now(), the start of the
-- transaction, so all rows of one batch share it, and two rows of a batch with
-- the same user_ref and event_type collided. store_orders hid that with
-- ON CONFLICT DO NOTHING, which dropped the second row without an error.
--
-- This migration only expands the schema (a new column with a default and a
-- different key), so an older build that omits event_id and still writes
-- ON CONFLICT DO NOTHING keeps working after a rollback to the other slot.
-- It is written to be safe to apply twice.

ALTER TABLE order_events
    ADD COLUMN IF NOT EXISTS event_id BIGINT GENERATED ALWAYS AS IDENTITY;

ALTER TABLE order_events
    DROP CONSTRAINT IF EXISTS order_events_pkey;

ALTER TABLE order_events
    ADD CONSTRAINT order_events_pkey PRIMARY KEY (session_id, event_id);
