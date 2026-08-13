
BEGIN;

CREATE TABLE IF NOT EXISTS items (
    id           BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name         TEXT        NOT NULL CHECK (length(trim(name)) > 0),
    description  TEXT,
    price_cents  INTEGER     NOT NULL DEFAULT 0 CHECK (price_cents >= 0),
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);


CREATE INDEX IF NOT EXISTS items_created_at_idx ON items (created_at DESC);

CREATE TABLE IF NOT EXISTS request_audit (
    id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    action      TEXT        NOT NULL,
    detail      TEXT,
    occurred_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMIT;
