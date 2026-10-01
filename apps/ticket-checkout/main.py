"""ticket-checkout: API sencillo con un solo endpoint POST /checkout que siempre responde 200."""
from fastapi import FastAPI

app = FastAPI(title="ticket-checkout")


@app.get("/health")
def health():
    return {"status": "ok"}


@app.post("/checkout", status_code=200)
def checkout():
    return {"status": "success", "message": "Checkout completed"}
