# syntax=docker/dockerfile:1
# Optimized Dockerfile for Jetson Nano with Open WebUI

# Build args
ARG USE_CUDA=true
ARG USE_OLLAMA=true
ARG USE_CUDA_VER=cu128
ARG USE_EMBEDDING_MODEL=sentence-transformers/all-MiniLM-L6-v2
ARG USE_RERANKING_MODEL=""
ARG USE_TIKTOKEN_ENCODING_NAME="cl100k_base"
ARG BUILD_HASH=dev-build
ARG UID=1000
ARG GID=1000

######## WebUI frontend ########
FROM --platform=$BUILDPLATFORM node:22-alpine3.20 AS build
ARG BUILD_HASH

WORKDIR /app

# Install git for build info
RUN apk add --no-cache git

# Copy package files
COPY package.json package-lock.json ./
RUN npm ci

# Copy source and build
COPY . .
ENV APP_BUILD_HASH=${BUILD_HASH}
RUN npm run build

######## WebUI backend ########
FROM python:3.11-slim-bookworm AS base

# Use args
ARG USE_CUDA
ARG USE_OLLAMA
ARG USE_CUDA_VER
ARG USE_EMBEDDING_MODEL
ARG USE_RERANKING_MODEL
ARG UID
ARG GID

# Environment variables
ENV ENV=prod \
    PORT=8080 \
    USE_OLLAMA_DOCKER=${USE_OLLAMA} \
    USE_CUDA_DOCKER=${USE_CUDA} \
    USE_CUDA_DOCKER_VER=${USE_CUDA_VER} \
    USE_EMBEDDING_MODEL_DOCKER=${USE_EMBEDDING_MODEL} \
    USE_RERANKING_MODEL_DOCKER=${USE_RERANKING_MODEL}

# Ollama configuration - pointing to your Jetson Nano
ENV OLLAMA_BASE_URL="http://192.168.1.81:11434" \
    OPENAI_API_BASE_URL=""

# Security and API configuration
ENV OPENAI_API_KEY="" \
    WEBUI_SECRET_KEY="" \
    SCARF_NO_ANALYTICS=true \
    DO_NOT_TRACK=true \
    ANONYMIZED_TELEMETRY=false

# Model settings
ENV WHISPER_MODEL="base" \
    WHISPER_MODEL_DIR="/app/backend/data/cache/whisper/models" \
    RAG_EMBEDDING_MODEL="$USE_EMBEDDING_MODEL_DOCKER" \
    RAG_RERANKING_MODEL="$USE_RERANKING_MODEL_DOCKER" \
    SENTENCE_TRANSFORMERS_HOME="/app/backend/data/cache/embedding/models" \
    TIKTOKEN_ENCODING_NAME="cl100k_base" \
    TIKTOKEN_CACHE_DIR="/app/backend/data/cache/tiktoken" \
    HF_HOME="/app/backend/data/cache/embedding/models"

WORKDIR /app/backend

# Create non-root user
RUN groupadd -g $GID app && \
    useradd -u $UID -g $GID -m -s /bin/bash app && \
    mkdir -p /home/app/.cache/chroma && \
    echo -n 00000000-0000-0000-0000-000000000000 > /home/app/.cache/chroma/telemetry_user_id

# Install system dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    git \
    build-essential \
    pandoc \
    gcc \
    python3-dev \
    netcat-openbsd \
    curl \
    jq \
    ffmpeg \
    libsm6 \
    libxext6 && \
    rm -rf /var/lib/apt/lists/*

# Copy and install Python dependencies
COPY --chown=$UID:$GID ./backend/requirements.txt ./requirements.txt

# Install PyTorch and dependencies
RUN pip3 install --no-cache-dir uv && \
    if [ "$USE_CUDA" = "true" ]; then \
        pip3 install https://pypi.jetson-ai-lab.io/root/pypi/+f/a10/3b5d782af5bd1/torch-2.7.1-cp310-cp310-manylinux_2_28_aarch64.whl#sha256=a103b5d782af5bd119b81dbcc7ffc6fa09904c423ff8db397a1e6ea8fd71508f \
        pip3 install https://pypi.jetson-ai-lab.io/root/pypi/+f/d66/bd76b226fdd41/torchaudio-2.7.1-cp312-cp312-manylinux_2_28_aarch64.whl#sha256=d66bd76b226fdd4135c97650e1b7eb63fb7659b4ed0e3a778898e41dbba21b61 \
        pip3 install https://pypi.jetson-ai-lab.io/root/pypi/+f/964/414eef19459d5/torchvision-0.22.1-cp312-cp312-manylinux_2_28_aarch64.whl#sha256=964414eef19459d55a10e886e2fca50677550e243586d1678f65e3f6f6bac47a \
        #pip3 install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/$USE_CUDA_DOCKER_VER --no-cache-dir; \
    else \
        pip3 install torch torchvision torchaudio --extra-index-url https://pypi.jetson-ai-lab.io/jp6/cu126 --no-cache-dir; \
    fi && \
    uv pip install --system -r requirements.txt --no-cache-dir

# Pre-download models (optional - can be commented out to reduce image size)
RUN python -c "import os; from sentence_transformers import SentenceTransformer; SentenceTransformer(os.environ['RAG_EMBEDDING_MODEL'], device='cpu')" && \
    python -c "import os; from faster_whisper import WhisperModel; WhisperModel(os.environ['WHISPER_MODEL'], device='cpu', compute_type='int8', download_root=os.environ['WHISPER_MODEL_DIR'])" && \
    python -c "import os; import tiktoken; tiktoken.get_encoding(os.environ['TIKTOKEN_ENCODING_NAME'])"

# Copy frontend build
COPY --chown=$UID:$GID --from=build /app/build /app/build
COPY --chown=$UID:$GID --from=build /app/CHANGELOG.md /app/CHANGELOG.md
COPY --chown=$UID:$GID --from=build /app/package.json /app/package.json

# Copy backend
COPY --chown=$UID:$GID ./backend .

# Set ownership
RUN chown -R $UID:$GID /app /home/app

# Expose port
EXPOSE 8080

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
  CMD curl -f http://localhost:${PORT:-8080}/health || exit 1

# Switch to non-root user
USER $UID:$GID

# Build version
ARG BUILD_HASH
ENV WEBUI_BUILD_VERSION=${BUILD_HASH}
ENV DOCKER=true

# Start command
CMD ["bash", "start.sh"]
