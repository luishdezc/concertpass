"""ticket-api: POST /reserve guarda una reservación en PostgreSQL (RDS) con estado 'confirmed'.

La conexión se configura SOLO con variables de ambiente:
DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASSWORD (y opcional DB_SSLMODE, default 'require').
"""
import os
import uuid
from contextlib import asynccontextmanager
from datetime import datetime, timezone

import psycopg
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field

REQUIRED_VARS = ["DB_HOST", "DB_PORT", "DB_NAME", "DB_USER", "DB_PASSWORD"]

CREATE_TABLE_SQL = """
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
"""

INSERT_SQL = """
INSERT INTO reservations
    (reservation_id, concert_id, user_id, ticket_type, quantity, status, created_at, updated_at)
VALUES (%s, %s, %s, %s, %s, %s, %s, %s)
"""


def conninfo() -> str:
    missing = [v for v in REQUIRED_VARS if not os.environ.get(v)]
    if missing:
        raise RuntimeError(f"Faltan variables de ambiente: {', '.join(missing)}")
    return psycopg.conninfo.make_conninfo(
        host=os.environ["DB_HOST"],
        port=os.environ["DB_PORT"],
        dbname=os.environ["DB_NAME"],
        user=os.environ["DB_USER"],
        password=os.environ["DB_PASSWORD"],
        sslmode=os.environ.get("DB_SSLMODE", "require"),
        connect_timeout=10,
    )


@asynccontextmanager
async def lifespan(app: FastAPI):
    # Crea la tabla al iniciar la app (idempotente)
    with psycopg.connect(conninfo()) as conn:
        conn.execute(CREATE_TABLE_SQL)
    yield


app = FastAPI(title="ticket-api", lifespan=lifespan)


class ReservationRequest(BaseModel):
    concert_id: str = Field(min_length=1)
    user_id: str = Field(min_length=1)
    ticket_type: str = Field(min_length=1)
    quantity: int = Field(gt=0)


@app.get("/health")
def health():
    return {"status": "ok"}


@app.post("/reserve", status_code=201)
def reserve(req: ReservationRequest):
    reservation_id = uuid.uuid4()
    now = datetime.now(timezone.utc).replace(tzinfo=None)  # columna TIMESTAMP sin zona -> guardamos UTC
    status = "confirmed"
    try:
        with psycopg.connect(conninfo()) as conn:
            conn.execute(
                INSERT_SQL,
                (reservation_id, req.concert_id, req.user_id, req.ticket_type,
                 req.quantity, status, now, now),
            )
    except psycopg.Error as exc:
        raise HTTPException(status_code=503, detail=f"Error de base de datos: {exc.__class__.__name__}")

    return {
        "reservation_id": str(reservation_id),
        **req.model_dump(),
        "status": status,
        "created_at": now.isoformat(),
        "updated_at": now.isoformat(),
    }
