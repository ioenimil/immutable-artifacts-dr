FROM python:3.12-slim AS builder

WORKDIR /build

# PIP_INDEX_URL is injected at build time by CI (CodeArtifact token URL).
# It is never baked into the final image.
ARG PIP_INDEX_URL
ENV PIP_INDEX_URL=${PIP_INDEX_URL}

COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt


FROM python:3.12-slim AS runtime

WORKDIR /app

RUN groupadd --gid 1001 appgroup && \
    useradd --uid 1001 --gid appgroup --no-create-home appuser

COPY --from=builder /install /usr/local
COPY main.py .

ARG APP_VERSION=unknown
ENV APP_VERSION=${APP_VERSION}

USER appuser

EXPOSE 8080

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]
