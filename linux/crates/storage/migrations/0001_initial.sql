CREATE TABLE IF NOT EXISTS sessions (
    id UUID PRIMARY KEY,
    started_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    ended_at TIMESTAMPTZ,
    feed_session TEXT NOT NULL,
    build_id TEXT NOT NULL,
    schema_version INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS instruments (
    symbol CHAR(8) PRIMARY KEY,
    enabled BOOLEAN NOT NULL DEFAULT FALSE,
    price_scale INTEGER NOT NULL DEFAULT 4,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS order_events (
    session_id UUID NOT NULL REFERENCES sessions(id),
    user_ref BIGINT NOT NULL,
    source_sequence BIGINT NOT NULL,
    event_type TEXT NOT NULL,
    side CHAR(1) NOT NULL,
    symbol CHAR(8) NOT NULL,
    price BIGINT NOT NULL,
    quantity BIGINT NOT NULL,
    risk_revision INTEGER NOT NULL,
    occurred_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (session_id, user_ref, event_type, occurred_at)
);

CREATE TABLE IF NOT EXISTS latency_summaries (
    session_id UUID NOT NULL REFERENCES sessions(id),
    domain TEXT NOT NULL,
    samples BIGINT NOT NULL,
    minimum_ns BIGINT NOT NULL,
    p50_ns BIGINT NOT NULL,
    p99_ns BIGINT NOT NULL,
    p999_ns BIGINT NOT NULL,
    maximum_ns BIGINT NOT NULL,
    recorded_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS health_events (
    session_id UUID REFERENCES sessions(id),
    component TEXT NOT NULL,
    severity TEXT NOT NULL,
    message TEXT NOT NULL,
    occurred_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS order_events_sequence_idx
    ON order_events (session_id, source_sequence);
