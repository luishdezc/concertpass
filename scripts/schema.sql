-- Tabla principal (también la crea ticket-api al arrancar)
CREATE TABLE IF NOT EXISTS reservations (
    reservation_id UUID PRIMARY KEY,
    concert_id     VARCHAR   NOT NULL,
    user_id        VARCHAR   NOT NULL,
    ticket_type    VARCHAR   NOT NULL,
    quantity       INTEGER   NOT NULL,
    status         VARCHAR   NOT NULL,
    created_at     TIMESTAMP NOT NULL,
    updated_at     TIMESTAMP NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_reservations_section ON reservations (concert_id, ticket_type, status);

-- Candado por sección para el SELECT ... FOR UPDATE de ticket-worker (también lo crea el worker)
CREATE TABLE IF NOT EXISTS inventory_locks (
    concert_id  VARCHAR NOT NULL,
    ticket_type VARCHAR NOT NULL,
    PRIMARY KEY (concert_id, ticket_type)
);
