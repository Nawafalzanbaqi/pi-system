-- ===========================================================================
-- pi-system module: bookings — schema for "__PROJECT_NAME__" (PostgreSQL).
-- ---------------------------------------------------------------------------
-- Applied IDEMPOTENTLY on startup by Bookings/BookingsMigrator.cs against the
-- project's OWN database (ConnectionStrings__Default -> postgres:5432, built by
-- the generator from the shared .env credentials — no secrets in this file, the
-- connection is by service name). Every statement is guarded (IF NOT EXISTS /
-- ON CONFLICT), so re-running it on every boot is safe.
--
-- Tables are namespaced with a "bookings_" prefix so they never collide with the
-- project's other tables in the shared database.
-- ===========================================================================

-- Bookable services / resources (a consultation, a property viewing, a
-- treatment, ...). Bilingual names so the UI can show ar or en directly.
CREATE TABLE IF NOT EXISTS bookings_services (
    id               BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    slug             TEXT        NOT NULL UNIQUE,
    name_en          TEXT        NOT NULL,
    name_ar          TEXT        NOT NULL,
    description_en   TEXT        NOT NULL DEFAULT '',
    description_ar   TEXT        NOT NULL DEFAULT '',
    duration_minutes INTEGER     NOT NULL DEFAULT 30 CHECK (duration_minutes > 0),
    active           BOOLEAN     NOT NULL DEFAULT TRUE,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Available time slots a customer can book against a service. A slot has a
-- capacity (default 1 = a single appointment); see the anti-double-booking index
-- below. (service_id, starts_at) is unique so the same service can't have two
-- slots at the exact same instant.
CREATE TABLE IF NOT EXISTS bookings_slots (
    id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    service_id  BIGINT      NOT NULL REFERENCES bookings_services(id) ON DELETE CASCADE,
    starts_at   TIMESTAMPTZ NOT NULL,
    ends_at     TIMESTAMPTZ NOT NULL,
    capacity    INTEGER     NOT NULL DEFAULT 1 CHECK (capacity > 0),
    active      BOOLEAN     NOT NULL DEFAULT TRUE,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT bookings_slots_time_ck CHECK (ends_at > starts_at),
    CONSTRAINT bookings_slots_uniq    UNIQUE (service_id, starts_at)
);
-- Fast lookup of a service's upcoming, active slots.
CREATE INDEX IF NOT EXISTS bookings_slots_lookup_idx
    ON bookings_slots (service_id, starts_at)
    WHERE active;

-- Bookings placed against a slot, with their lifecycle status + customer info.
-- `reference` is a short public token returned to the customer (so internal ids
-- are never exposed in confirmations).
CREATE TABLE IF NOT EXISTS bookings_bookings (
    id             BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    reference      TEXT        NOT NULL UNIQUE,
    slot_id        BIGINT      NOT NULL REFERENCES bookings_slots(id)    ON DELETE RESTRICT,
    service_id     BIGINT      NOT NULL REFERENCES bookings_services(id) ON DELETE RESTRICT,
    customer_name  TEXT        NOT NULL,
    customer_email TEXT        NOT NULL,
    customer_phone TEXT        NOT NULL DEFAULT '',
    notes          TEXT        NOT NULL DEFAULT '',
    status         TEXT        NOT NULL DEFAULT 'pending'
                   CHECK (status IN ('pending', 'confirmed', 'cancelled')),
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS bookings_bookings_slot_idx ON bookings_bookings (slot_id);

-- ---------------------------------------------------------------------------
-- Anti-double-booking, enforced by the DATABASE itself (not just the UI or app).
-- This PARTIAL UNIQUE index makes it impossible to have more than one active
-- (non-cancelled) booking on a single-capacity slot, even under concurrent
-- requests — it is the hard backstop behind the application's row-locked
-- capacity check in BookingsRepository.CreateBookingAsync.
--
-- It assumes the default capacity of 1 (the safe default for appointments). If
-- you DELIBERATELY set a slot's `capacity` > 1, drop this index and rely on the
-- application's capacity check, which honours any capacity under a row lock:
--     DROP INDEX IF EXISTS bookings_one_active_per_slot;
-- ---------------------------------------------------------------------------
CREATE UNIQUE INDEX IF NOT EXISTS bookings_one_active_per_slot
    ON bookings_bookings (slot_id)
    WHERE status <> 'cancelled';
