FROM python:3.12-bookworm
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PADDLE_PDX_CACHE_HOME=/app/models
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl libgl1 libglib2.0-0 libgomp1 \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py ./
RUN mkdir -p /app/models \
    && groupadd -r appuser \
    && useradd -r -g appuser -u 1000 appuser \
    && chown -R appuser:appuser /app
EXPOSE 5110
USER appuser
HEALTHCHECK --interval=15s --timeout=5s --start-period=30s --retries=6 \
  CMD curl --fail --silent http://127.0.0.1:5110/healthz > /dev/null || exit 1
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "5110"]
