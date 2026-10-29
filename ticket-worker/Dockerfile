FROM python:3.13-slim
WORKDIR /usr/local/app

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY src/ ./

# Sin credenciales en la imagen: toda la configuración llega por variables de ambiente

# Usuario no-root por seguridad
RUN useradd --no-create-home app
USER app

# No expone puertos: es un proceso de fondo que consume la cola
CMD ["python", "main.py"]
