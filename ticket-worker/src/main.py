"""ticket-worker (consumidor).

Hace polling a la cola SQS FIFO y, por cada reservación:
  1. Lee la capacidad de la sección en DynamoDB (tabla de eventos, solo lectura).
  2. En una transacción de PostgreSQL con FOR UPDATE calcula cuántos boletos de ese tipo ya están
     vendidos (booked + confirmed) y decide:
        vendidos + quantity <= capacity  -> booked   (COMMIT)
        si no                            -> ROLLBACK y rejected en una transacción separada
  3. Si quedó booked, llama POST /checkout de ticket-checkout; con 200 OK actualiza a confirmed.
  4. Borra el mensaje de SQS solo después de procesarlo.

Variables de ambiente (requeridas):
  SQS_QUEUE_URL, AWS_REGION, DYNAMODB_TABLE, CHECKOUT_URL,
  DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASSWORD  (DB_SSLMODE opcional, default 'require')
Opcionales:
  MAX_MESSAGES (10), WAIT_TIME_SECONDS (10), POLL_INTERVAL_SECONDS (2, solo cuando la cola está vacía),
  CAPACITY_CACHE_SECONDS (30), CHECKOUT_TIMEOUT_SECONDS (5)
"""
import json
import logging
import os
import signal
import sys
import time
from pathlib import Path

import boto3
import httpx
import psycopg
from botocore.exceptions import BotoCoreError, ClientError
from psycopg_pool import ConnectionPool

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s", stream=sys.stdout)
log = logging.getLogger("ticket-worker")

REQUIRED_VARS = ["SQS_QUEUE_URL", "AWS_REGION", "DYNAMODB_TABLE", "CHECKOUT_URL",
                 "DB_HOST", "DB_PORT", "DB_NAME", "DB_USER", "DB_PASSWORD"]
HEARTBEAT = Path("/tmp/heartbeat")  # lo revisa el livenessProbe del Deployment

# ---------------------------------------------------------------------------
# SQL
# ---------------------------------------------------------------------------
# Una fila por (concierto, tipo de boleto). Es el "candado" de la sección: todos los workers que
# quieran vender boletos de esa sección hacen SELECT ... FOR UPDATE sobre ESTA fila, así que se
# forman en fila y solo uno a la vez lee y modifica el inventario.
#
# ¿Por qué no poner FOR UPDATE directo en el SELECT SUM(...) como en el enunciado?
#   1. PostgreSQL lo rechaza: "FOR UPDATE is not allowed with aggregate functions".
#   2. Aunque se reescriba como subconsulta, solo bloquea las filas booked/confirmed que YA existen.
#      Con el concierto vacío no bloquea nada, y dos workers pueden ver "0 vendidos" a la vez y
#      sobrevender (lo demostramos en scripts/race_test.py).
CREATE_LOCKS_SQL = """
CREATE TABLE IF NOT EXISTS inventory_locks (
    concert_id  VARCHAR NOT NULL,
    ticket_type VARCHAR NOT NULL,
    PRIMARY KEY (concert_id, ticket_type)
);
"""
ENSURE_LOCK_ROW_SQL = """
INSERT INTO inventory_locks (concert_id, ticket_type) VALUES (%s, %s) ON CONFLICT DO NOTHING
"""
LOCK_SECTION_SQL = """
SELECT 1 FROM inventory_locks WHERE concert_id = %s AND ticket_type = %s FOR UPDATE
"""
LOCK_RESERVATION_SQL = """
SELECT status FROM reservations WHERE reservation_id = %s FOR UPDATE
"""
SOLD_SQL = """
SELECT COALESCE(SUM(quantity), 0)
FROM   reservations
WHERE  concert_id  = %s
AND    ticket_type = %s
AND    status IN ('booked', 'confirmed')
"""
BOOK_SQL = """
UPDATE reservations SET status = 'booked', updated_at = NOW() AT TIME ZONE 'UTC'
WHERE reservation_id = %s
"""
# "sin modificar otras filas": filtra por id y solo si sigue pending
REJECT_SQL = """
UPDATE reservations SET status = 'rejected', updated_at = NOW() AT TIME ZONE 'UTC'
WHERE reservation_id = %s AND status = 'pending'
"""
CONFIRM_SQL = """
UPDATE reservations SET status = 'confirmed', updated_at = NOW() AT TIME ZONE 'UTC'
WHERE reservation_id = %s AND status = 'booked'
"""


class InvalidMessage(Exception):
    """El body no es una reservación válida; reintentar no lo va a arreglar."""


# ---------------------------------------------------------------------------
# DynamoDB: capacidad por sección (solo lectura en runtime, con caché corto)
# ---------------------------------------------------------------------------
class CapacityReader:
    def __init__(self, table, ttl_seconds: int):
        self.table = table
        self.ttl = ttl_seconds
        self._cache: dict[str, tuple[float, dict | None]] = {}

    def capacity(self, concert_id: str, ticket_type: str) -> int | None:
        """Capacidad de la sección, o None si el concierto o la sección no existen."""
        cached = self._cache.get(concert_id)
        if cached and time.monotonic() - cached[0] < self.ttl:
            item = cached[1]
        else:
            item = self.table.get_item(Key={"concert_id": concert_id}).get("Item")
            self._cache[concert_id] = (time.monotonic(), item)
        if not item:
            return None
        value = item.get("capacity", {}).get(ticket_type)
        return int(value) if value is not None else None  # DynamoDB regresa Decimal


# ---------------------------------------------------------------------------
# Decisión de inventario
# ---------------------------------------------------------------------------
def decide(conn: psycopg.Connection, reservation_id: str, concert_id: str, ticket_type: str,
           quantity: int, capacity: int | None) -> tuple[str, str]:
    """Regresa (estado, motivo). La conexión debe estar en autocommit para que cada
    conn.transaction() sea un BEGIN/COMMIT real."""
    conn.execute(ENSURE_LOCK_ROW_SQL, (concert_id, ticket_type))

    reason = ""
    with conn.transaction():                                    # BEGIN
        conn.execute(LOCK_SECTION_SQL, (concert_id, ticket_type))  # FOR UPDATE: candado de la sección

        row = conn.execute(LOCK_RESERVATION_SQL, (reservation_id,)).fetchone()
        if row is None:
            return "missing", "no existe en RDS"
        if row[0] != "pending":
            # SQS puede reentregar un mensaje: no volver a contar una reservación ya decidida
            return row[0], "ya estaba procesada (reentrega)"

        if capacity is None:
            reason = "concierto o sección inexistente en DynamoDB"
            raise psycopg.Rollback()

        sold = conn.execute(SOLD_SQL, (concert_id, ticket_type)).fetchone()[0]
        if sold + quantity <= capacity:
            conn.execute(BOOK_SQL, (reservation_id,))
            return "booked", f"vendidos {sold} + {quantity} <= {capacity}"   # COMMIT al salir del with

        reason = f"vendidos {sold} + {quantity} > {capacity}"
        raise psycopg.Rollback()                                # ROLLBACK: libera el candado sin cambios

    # Sin espacio: rejected en una transacción separada, como pide el enunciado
    conn.execute(REJECT_SQL, (reservation_id,))
    return "rejected", reason


# ---------------------------------------------------------------------------
# Worker
# ---------------------------------------------------------------------------
class Worker:
    def __init__(self):
        missing = [v for v in REQUIRED_VARS if not os.environ.get(v)]
        if missing:
            raise RuntimeError(f"Faltan variables de ambiente: {', '.join(missing)}")

        region = os.environ["AWS_REGION"]
        self.queue_url = os.environ["SQS_QUEUE_URL"]
        self.max_messages = int(os.environ.get("MAX_MESSAGES", "10"))
        self.wait_time = int(os.environ.get("WAIT_TIME_SECONDS", "10"))
        self.poll_interval = float(os.environ.get("POLL_INTERVAL_SECONDS", "2"))
        self.checkout_url = os.environ["CHECKOUT_URL"].rstrip("/") + "/checkout"

        self.sqs = boto3.client("sqs", region_name=region)
        table = boto3.resource("dynamodb", region_name=region).Table(os.environ["DYNAMODB_TABLE"])
        self.capacity = CapacityReader(table, int(os.environ.get("CAPACITY_CACHE_SECONDS", "30")))
        self.http = httpx.Client(timeout=float(os.environ.get("CHECKOUT_TIMEOUT_SECONDS", "5")))

        conninfo = psycopg.conninfo.make_conninfo(
            host=os.environ["DB_HOST"], port=os.environ["DB_PORT"], dbname=os.environ["DB_NAME"],
            user=os.environ["DB_USER"], password=os.environ["DB_PASSWORD"],
            sslmode=os.environ.get("DB_SSLMODE", "require"), connect_timeout=10,
        )
        self.pool = ConnectionPool(conninfo, min_size=1, max_size=2, kwargs={"autocommit": True},
                                   check=ConnectionPool.check_connection, open=True)
        with self.pool.connection() as conn:
            conn.execute(CREATE_LOCKS_SQL)

        self.running = True

    def stop(self, signum, _frame):
        log.info("Señal %s recibida, terminando después del mensaje actual...", signal.Signals(signum).name)
        self.running = False

    def checkout(self, reservation_id: str, quantity: int) -> None:
        resp = self.http.post(self.checkout_url, json={"reservation_id": reservation_id, "quantity": quantity})
        resp.raise_for_status()  # cualquier cosa distinta de 2xx -> excepción -> se reintenta

    def process(self, body: dict) -> None:
        try:
            rid = str(body["reservation_id"])
            concert_id = str(body["concert_id"])
            ticket_type = str(body["ticket_type"])
            quantity = int(body["quantity"])
        except (KeyError, TypeError, ValueError) as exc:
            raise InvalidMessage(f"campo faltante o inválido: {exc}") from exc

        capacity = self.capacity.capacity(concert_id, ticket_type)

        with self.pool.connection() as conn:
            status, reason = decide(conn, rid, concert_id, ticket_type, quantity, capacity)
        log.info("reserva %s [%s/%s x%s] -> %s (%s)", rid, concert_id, ticket_type, quantity, status, reason)

        if status == "missing":
            return  # nada que actualizar; el mensaje se borra
        if status == "booked":
            # Si checkout falla, la excepción evita borrar el mensaje: SQS lo reentrega,
            # decide() ve 'booked' y se reintenta solo el checkout.
            self.checkout(rid, quantity)
            with self.pool.connection() as conn:
                conn.execute(CONFIRM_SQL, (rid,))
            log.info("reserva %s -> confirmed (checkout 200 OK)", rid)

    def run(self) -> int:
        signal.signal(signal.SIGINT, self.stop)
        signal.signal(signal.SIGTERM, self.stop)  # kubectl delete / rollout
        log.info("ticket-worker escuchando %s", self.queue_url)

        while self.running:
            HEARTBEAT.touch()
            try:
                resp = self.sqs.receive_message(
                    QueueUrl=self.queue_url,
                    MaxNumberOfMessages=self.max_messages,
                    WaitTimeSeconds=self.wait_time,
                    MessageSystemAttributeNames=["ApproximateReceiveCount", "MessageGroupId"],
                )
            except (BotoCoreError, ClientError) as exc:
                log.error("Error al leer de SQS: %s", exc)
                time.sleep(self.poll_interval)
                continue

            messages = resp.get("Messages", [])
            if not messages:
                time.sleep(self.poll_interval)
                continue

            for msg in messages:
                if not self.running:
                    break  # los no procesados vuelven a la cola al expirar el visibility timeout
                attrs = msg.get("Attributes", {})
                try:
                    self.process(json.loads(msg["Body"]))
                except (json.JSONDecodeError, InvalidMessage) as exc:
                    # Reintentar no lo arregla: se borra para no bloquear el MessageGroup
                    log.error("Mensaje %s inválido, se descarta: %s", msg["MessageId"], exc)
                except Exception:
                    log.exception("Error procesando mensaje %s (grupo=%s, intento %s); se reintentará",
                                  msg["MessageId"], attrs.get("MessageGroupId"),
                                  attrs.get("ApproximateReceiveCount"))
                    # FIFO: no seguir con el resto del lote para no romper el orden del grupo
                    break
                self.sqs.delete_message(QueueUrl=self.queue_url, ReceiptHandle=msg["ReceiptHandle"])

        self.pool.close()
        log.info("ticket-worker detenido")
        return 0


if __name__ == "__main__":
    try:
        sys.exit(Worker().run())
    except RuntimeError as exc:
        log.error("%s", exc)
        sys.exit(1)
