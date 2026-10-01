FROM python:3.13-slim
WORKDIR /usr/local/app

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

# Dependencias (capa separada para aprovechar la caché)
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

# Código fuente
COPY main.py ./
EXPOSE 8080

# Usuario no-root por seguridad
RUN useradd --no-create-home app
USER app

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]
