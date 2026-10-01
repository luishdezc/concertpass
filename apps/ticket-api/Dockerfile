FROM python:3.13-slim
WORKDIR /usr/local/app

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

# Dependencias (psycopg[binary] trae libpq incluida, no hace falta apt-get)
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

# Código fuente
COPY main.py ./
EXPOSE 8080

# Sin credenciales en la imagen: las DB_* se pasan con -e / --env-file en docker run

# Usuario no-root por seguridad
RUN useradd --no-create-home app
USER app

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]
