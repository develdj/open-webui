# syntax=docker/dockerfile:1
# Jetson Orin 64 GB – fastest possible Open-WebUI image
# ------------------------------------------------------------------------------
# 1. Base with CUDA 12.x & PyTorch 2.2 already compiled for JetPack 6
FROM nvcr.io/nvidia/l4t-pytorch:r36.2.0-pth2.2-py3 AS base

# 2. Re-use wheels layer so we never reinstall unless requirements.txt changes
FROM base AS prebuilt
COPY backend/requirements.txt /tmp/requirements.txt
RUN pip install uv && \
    uv pip install --system --no-cache-dir -r /tmp/requirements.txt

# 3. Frontend build – only re-builds when package.json or source change
FROM --platform=$BUILDPLATFORM node:22-alpine3.20 AS frontend
ARG BUILD_HASH=dev
WORKDIR /app
COPY package*.json ./
RUN npm ci --prefer-offline
COPY . .
ENV APP_BUILD_HASH=$BUILD_HASH
RUN npm run build

# 4. Final runtime image
FROM base
ARG UID=1000
ARG GID=1000
ARG BUILD_HASH=dev

# Copy pre-compiled wheels & frontend artefacts
COPY --from=prebuilt /usr/local/lib/python3.10/dist-packages /usr/local/lib/python3.10/dist-packages
COPY --from=frontend /app/build /app/build
COPY --from=frontend /app/CHANGELOG.md /app/
COPY --chown=$UID:$GID backend /app/backend

# Non-root user
RUN groupadd -g $GID app && \
    useradd -u $UID -g $GID -m -s /bin/bash app && \
    mkdir -p /app/backend/data && \
    chown -R app:app /app

# Pre-warm models for offline start (optional but fast)
ENV WHISPER_MODEL="base" \
    RAG_EMBEDDING_MODEL="sentence-transformers/all-MiniLM-L6-v2" \
    HF_HOME="/app/backend/data/cache"
USER app
RUN python -c \
  "from faster_whisper import WhisperModel; WhisperModel('base', device='cpu', compute_type='int8')" && \
  python -c \
  "from sentence_transformers import SentenceTransformer; SentenceTransformer('$RAG_EMBEDDING_MODEL', device='cpu')"

WORKDIR /app/backend
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=10s --start-period=15s \
  CMD python -c "import requests; requests.get('http://localhost:8080/health', timeout=5)"
CMD ["python", "-m", "main"]
