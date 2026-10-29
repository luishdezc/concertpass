"""ticket-checkout: simula un procesador de pagos externo (Stripe, PayPal).

POST /checkout  body {"reservation_id": "<uuid>", "quantity": 2}  -> 200 OK autorizando la compra.

En un sistema real esta llamada iría al procesador de pagos y la confirmación llegaría por webhook;
aquí la respuesta es inmediata para simplificar.
"""
import logging
import uuid
from datetime import datetime, timezone

from fastapi import FastAPI
from pydantic import BaseModel, Field

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("ticket-checkout")

app = FastAPI(title="ticket-checkout")


class CheckoutRequest(BaseModel):
    reservation_id: uuid.UUID
    quantity: int = Field(gt=0)


@app.get("/health")
def health():
    return {"status": "ok"}


@app.post("/checkout", status_code=200)
def checkout(req: CheckoutRequest):
    payment_id = f"pay_{uuid.uuid4().hex[:16]}"
    log.info("pago autorizado %s: reserva=%s cantidad=%s", payment_id, req.reservation_id, req.quantity)
    return {
        "status": "authorized",
        "payment_id": payment_id,
        "reservation_id": str(req.reservation_id),
        "quantity": req.quantity,
        "authorized_at": datetime.now(timezone.utc).isoformat(),
    }
