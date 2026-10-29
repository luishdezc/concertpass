#!/usr/bin/env python3
"""Prueba de concurrencia de la lógica de inventario (evidencia para el reporte).

Crea N reservaciones 'pending' de un concierto de prueba y lanza N hilos que deciden al MISMO tiempo,
como si hubiera N réplicas de ticket-worker. Compara dos estrategias:

  enunciado  SELECT SUM(quantity) FROM (SELECT ... FOR UPDATE) -- bloquea solo filas ya vendidas
  worker     SELECT ... FROM inventory_locks ... FOR UPDATE     -- candado por sección (lo que usa ticket-worker)

Se agrega un pg_sleep entre leer y escribir para ensanchar la ventana de carrera (igual en ambas).

Uso:  python3 scripts/race_test.py                # lee DB_* de .env
      RESERVATIONS=40 CAPACITY=10 python3 scripts/race_test.py
Solo toca filas del concierto 'race-test' y las borra al terminar.
"""
import os
import sys
import threading
import uuid
from pathlib import Path

import psycopg

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "ticket-worker" / "src"))
import main as worker  # noqa: E402  (decide() y el SQL reales de ticket-worker)

CONCERT = "race-test"
TICKET = "vip"
N = int(os.environ.get("RESERVATIONS", "30"))
CAPACITY = int(os.environ.get("CAPACITY", "10"))
SLEEP = float(os.environ.get("RACE_SLEEP", "0.05"))


def load_env():
    env_file = ROOT / ".env"
    if env_file.exists():
        for line in env_file.read_text().splitlines():
            if "=" in line and not line.lstrip().startswith("#"):
                k, v = line.split("=", 1)
                os.environ.setdefault(k.strip(), v.strip().strip("\x27\""))


def conninfo():
    return psycopg.conninfo.make_conninfo(
        host=os.environ["DB_HOST"], port=os.environ["DB_PORT"], dbname=os.environ["DB_NAME"],
        user=os.environ["DB_USER"], password=os.environ["DB_PASSWORD"],
        sslmode=os.environ.get("DB_SSLMODE", "require"),
    )


def naive_decide(conn, rid, qty, capacity):
    """El SQL del enunciado, reescrito para que PostgreSQL lo acepte."""
    with conn.transaction():
        conn.execute("SELECT status FROM reservations WHERE reservation_id = %s FOR UPDATE", (rid,))
        sold = conn.execute(
            """SELECT COALESCE(SUM(quantity), 0) FROM (
                   SELECT quantity FROM reservations
                   WHERE concert_id = %s AND ticket_type = %s AND status IN ('booked','confirmed')
                   FOR UPDATE) t""", (CONCERT, TICKET)).fetchone()[0]
        conn.execute("SELECT pg_sleep(%s)", (SLEEP,))
        if sold + qty <= capacity:
            conn.execute(worker.BOOK_SQL, (rid,))
            return "booked"
        raise psycopg.Rollback()
    conn.execute(worker.REJECT_SQL, (rid,))
    return "rejected"


def worker_decide(conn, rid, qty, capacity):
    """El decide() REAL de ticket-worker, sin cambios en su lógica."""
    status, _ = worker.decide(conn, rid, CONCERT, TICKET, qty, capacity)
    return status


def widen_race_window():
    """Mete un pg_sleep en la consulta de vendidos de ticket-worker (misma ventana que 'enunciado')."""
    worker.SOLD_SQL = f"SELECT sold FROM ({worker.SOLD_SQL}) AS q(sold) CROSS JOIN pg_sleep({SLEEP})"


def run(strategy, decide_fn):
    with psycopg.connect(conninfo(), autocommit=True) as conn:
        conn.execute(worker.CREATE_LOCKS_SQL)
        conn.execute("DELETE FROM reservations WHERE concert_id = %s", (CONCERT,))
        ids = [str(uuid.uuid4()) for _ in range(N)]
        with conn.cursor() as cur:
            cur.executemany(
                """INSERT INTO reservations VALUES (%s,%s,%s,%s,1,'pending',
                   NOW() AT TIME ZONE 'UTC', NOW() AT TIME ZONE 'UTC')""",
                [(rid, CONCERT, f"usr_{i}", TICKET) for i, rid in enumerate(ids)])

    barrier = threading.Barrier(N)
    errors = []

    def go(rid):
        try:
            with psycopg.connect(conninfo(), autocommit=True) as c:
                barrier.wait()  # todos arrancan al mismo tiempo
                decide_fn(c, rid, 1, CAPACITY)
        except Exception as exc:  # noqa: BLE001
            errors.append(exc)

    threads = [threading.Thread(target=go, args=(rid,)) for rid in ids]
    for t in threads:
        t.start()
    for t in threads:
        t.join()

    with psycopg.connect(conninfo(), autocommit=True) as conn:
        counts = dict(conn.execute(
            "SELECT status, COUNT(*) FROM reservations WHERE concert_id = %s GROUP BY status",
            (CONCERT,)).fetchall())
        conn.execute("DELETE FROM reservations WHERE concert_id = %s", (CONCERT,))
        conn.execute("DELETE FROM inventory_locks WHERE concert_id = %s", (CONCERT,))

    sold = counts.get("booked", 0)
    verdict = "OK, sin sobreventa" if sold <= CAPACITY else f"SOBREVENTA: {sold - CAPACITY} boletos de más"
    print(f"{strategy:<10} capacidad={CAPACITY} solicitudes={N} -> booked={sold} "
          f"rejected={counts.get('rejected', 0)} pending={counts.get('pending', 0)}  [{verdict}]")
    if errors:
        print(f"           errores: {len(errors)} ({errors[0]!r})")
    return sold <= CAPACITY


if __name__ == "__main__":
    load_env()
    print(f"{N} workers concurrentes, 1 boleto cada uno\n")
    run("enunciado", naive_decide)
    widen_race_window()
    ok = run("worker", worker_decide)
    sys.exit(0 if ok else 1)
