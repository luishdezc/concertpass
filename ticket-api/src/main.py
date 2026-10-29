"""ticket-api (productor).

POST /reserve            -> guarda la reservación en RDS con status 'pending', la encola en SQS FIFO
                            (MessageGroupId = concert_id) y regresa el reservation_id.
GET  /reservation/{id}   -> estado actual: pending, booked, confirmed o rejected.

Configuración SOLO por variables de ambiente (en EKS: DB_* vienen de Secrets Manager, el resto del ConfigMap):
  DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASSWORD, DB_SSLMODE (opcional, default 'require')
  SQS_QUEUE_URL, AWS_REGION
  DB_POOL_MAX (opcional, default 10)
Las credenciales de AWS las resuelve boto3 (EKS Pod Identity en el cluster, ~/.aws o AWS_* en local).
"""
import json
import logging
import os
import uuid
from contextlib import asynccontextmanager
from datetime import datetime, timezone

import boto3
import psycopg
from botocore.exceptions import BotoCoreError, ClientError
from fastapi import FastAPI, HTTPException
from psycopg.rows import dict_row
from psycopg_pool import ConnectionPool
from pydantic import BaseModel, Field

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("ticket-api")

REQUIRED_VARS = ["DB_HOST", "DB_PORT", "DB_NAME", "DB_USER", "DB_PASSWORD", "SQS_QUEUE_URL", "AWS_REGION"]

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
CREATE INDEX IF NOT EXISTS idx_reservations_section
    ON reservations (concert_id, ticket_type, status);
"""

INSERT_SQL = """
INSERT INTO reservations
    (reservation_id, concert_id, user_id, ticket_type, quantity, status, created_at, updated_at)
VALUES (%s, %s, %s, %s, %s, %s, %s, %s)
"""

DELETE_PENDING_SQL = "DELETE FROM reservations WHERE reservation_id = %s AND status = 'pending'"

SELECT_SQL = """
SELECT reservation_id, concert_id, user_id, ticket_type, quantity, status, created_at, updated_at
FROM reservations WHERE reservation_id = %s
"""


def check_env() -> None:
    missing = [v for v in REQUIRED_VARS if not os.environ.get(v)]
    if missing:
        raise RuntimeError(f"Faltan variables de ambiente: {', '.join(missing)}")


def conninfo() -> str:
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
    check_env()
    app.state.queue_url = os.environ["SQS_QUEUE_URL"]
    app.state.sqs = boto3.client("sqs", region_name=os.environ["AWS_REGION"])
    # Pool de conexiones: abrir una conexión TLS a RDS por request es caro bajo carga
    app.state.pool = ConnectionPool(
        conninfo(),
        min_size=1,
        max_size=int(os.environ.get("DB_POOL_MAX", "10")),
        check=ConnectionPool.check_connection,  # descarta conexiones muertas
        open=True,
    )
    with app.state.pool.connection() as conn:
        conn.execute(CREATE_TABLE_SQL)  # idempotente
    log.info("ticket-api listo")
    yield
    app.state.pool.close()


app = FastAPI(title="ticket-api", lifespan=lifespan)


class ReservationRequest(BaseModel):
    concert_id: str = Field(min_length=1)
    user_id: str = Field(min_length=1)
    ticket_type: str = Field(min_length=1)
    quantity: int = Field(gt=0)


@app.get("/health")
def health():
    return {"status": "ok"}


@app.post("/reserve", status_code=202)
def reserve(req: ReservationRequest):
    reservation_id = str(uuid.uuid4())
    now = datetime.now(timezone.utc).replace(tzinfo=None)  # columna TIMESTAMP sin zona -> UTC
    status = "pending"

    # Payload de POST /reserve + reservation_id, para que el worker sepa qué fila actualizar
    payload = {"reservation_id": reservation_id, **req.model_dump()}

    # 1. INSERT con COMMIT antes de encolar. Si se encolara dentro de la transacción, el worker
    #    podría recibir el mensaje antes del COMMIT y no encontrar la fila.
    try:
        with app.state.pool.connection() as conn:
            with conn.transaction():
                conn.execute(
                    INSERT_SQL,
                    (reservation_id, req.concert_id, req.user_id, req.ticket_type,
                     req.quantity, status, now, now),
                )
    except psycopg.Error as exc:
        log.exception("Error de base de datos")
        raise HTTPException(status_code=503, detail=f"Error de base de datos: {exc.__class__.__name__}")

    # 2. Encolar. Si SQS falla, se borra la fila para no dejar una 'pending' que nadie va a procesar.
    try:
        resp = app.state.sqs.send_message(
            QueueUrl=app.state.queue_url,
            MessageBody=json.dumps(payload),
            MessageGroupId=req.concert_id,          # orden FIFO por concierto
            MessageDeduplicationId=reservation_id,  # cada reservación es un mensaje distinto
        )
    except (BotoCoreError, ClientError) as exc:
        log.exception("Error al encolar en SQS; se descarta la reservación %s", reservation_id)
        try:
            with app.state.pool.connection() as conn:
                conn.execute(DELETE_PENDING_SQL, (reservation_id,))
        except psycopg.Error:
            log.exception("No se pudo borrar la reservación %s", reservation_id)
        raise HTTPException(status_code=503, detail=f"Error al encolar en SQS: {exc.__class__.__name__}")

    log.info("reserva %s encolada (concierto=%s tipo=%s cantidad=%s sqs_message_id=%s)",
             reservation_id, req.concert_id, req.ticket_type, req.quantity, resp.get("MessageId"))

    # 202 Accepted: se recibió, pero el resultado final lo decide ticket-worker (asíncrono)
    return {
        **payload,
        "status": status,
        "sqs_message_id": resp.get("MessageId"),
        "created_at": now.isoformat(),
        "updated_at": now.isoformat(),
    }


@app.get("/reservation/{reservation_id}")
def get_reservation(reservation_id: uuid.UUID):  # FastAPI responde 422 si no es un UUID válido
    try:
        with app.state.pool.connection() as conn:
            row = conn.cursor(row_factory=dict_row).execute(SELECT_SQL, (reservation_id,)).fetchone()
    except psycopg.Error as exc:
        raise HTTPException(status_code=503, detail=f"Error de base de datos: {exc.__class__.__name__}")

    if row is None:
        raise HTTPException(status_code=404, detail="Reservación no encontrada")

    row["reservation_id"] = str(row["reservation_id"])
    row["created_at"] = row["created_at"].isoformat()
    row["updated_at"] = row["updated_at"].isoformat()
    return row
