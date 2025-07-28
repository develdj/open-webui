# syntax=docker/dockerfile:1
# Initialize device type args
# use build args in the docker build command with --build-arg="BUILDARG=true"
ARG USE_CUDA=true
ARG USE_OLLAMA=true
# Tested with cu117 for CUDA 11 and cu121 for CUDA 12 (default)
ARG USE_CUDA_VER=cu126
# any sentence transformer model; models to use can be found at https://huggingface.co/models?library=sentence-transformers
# Leaderboard: https://huggingface.co/spaces/mteb/leaderboard 
# for better performance and multilangauge support use "intfloat/multilingual-e5-large" (~2.5GB) or "intfloat/multilingual-e5-base" (~1.5GB)
# IMPORTANT: If you change the embedding model (sentence-transformers/all-MiniLM-L6-v2) and vice versa, you aren't able to use RAG Chat with your previous documents loaded in the WebUI! You need to re-embed them.
ARG USE_EMBEDDING_MODEL=sentence-transformers/all-MiniLM-L6-v2
ARG USE_RERANKING_MODEL=""

# Tiktoken encoding name; models to use can be found at https://huggingface.co/models?library=tiktoken
ARG USE_TIKTOKEN_ENCODING_NAME="cl100k_base"

ARG BUILD_HASH=dev-build
# Override at your own risk - non-root configurations are untested
ARG UID=0
ARG GID=0

######## WebUI frontend ########
FROM --platform=$BUILDPLATFORM node:22-alpine3.20 AS build
ARG BUILD_HASH

WORKDIR /app

# to store git revision in build
RUN apk add --no-cache git

COPY package.json package-lock.json ./
RUN npm ci --force

COPY . .
ENV APP_BUILD_HASH=${BUILD_HASH}
RUN npm run build

######## WebUI backend ########
FROM python:3.10-slim-bookworm AS base

# Use args
ARG USE_CUDA
ARG USE_OLLAMA
ARG USE_CUDA_VER
ARG USE_EMBEDDING_MODEL
ARG USE_RERANKING_MODEL
ARG UID
ARG GID

## Basis ##
ENV ENV=prod \
    PORT=8080 \
    # pass build args to the build
    USE_OLLAMA_DOCKER=${USE_OLLAMA} \
    USE_CUDA_DOCKER=${USE_CUDA} \
    USE_CUDA_DOCKER_VER=${USE_CUDA_VER} \
    USE_EMBEDDING_MODEL_DOCKER=${USE_EMBEDDING_MODEL} \
    USE_RERANKING_MODEL_DOCKER=${USE_RERANKING_MODEL}

## Basis URL Config ##
ENV OLLAMA_BASE_URL="/ollama" \
    OPENAI_API_BASE_URL=""

## API Key and Security Config ##
ENV OPENAI_API_KEY="" \
    WEBUI_SECRET_KEY="" \
    SCARF_NO_ANALYTICS=true \
    DO_NOT_TRACK=true \
    ANONYMIZED_TELEMETRY=false

#### Other models #########################################################
## whisper TTS model settings ##
ENV WHISPER_MODEL="base" \
    WHISPER_MODEL_DIR="/app/backend/data/cache/whisper/models"

## RAG Embedding model settings ##
ENV RAG_EMBEDDING_MODEL="$USE_EMBEDDING_MODEL_DOCKER" \
    RAG_RERANKING_MODEL="$USE_RERANKING_MODEL_DOCKER" \
    SENTENCE_TRANSFORMERS_HOME="/app/backend/data/cache/embedding/models"

## Tiktoken model settings ##
ENV TIKTOKEN_ENCODING_NAME="cl100k_base" \
    TIKTOKEN_CACHE_DIR="/app/backend/data/cache/tiktoken"

## Hugging Face download cache ##
ENV HF_HOME="/app/backend/data/cache/embedding/models"

## Torch Extensions ##
# ENV TORCH_EXTENSIONS_DIR="/.cache/torch_extensions"

#### Other models ##########################################################

WORKDIR /app/backend

ENV HOME=/root
# Create user and group if not root
RUN if [ $UID -ne 0 ]; then \
    if [ $GID -ne 0 ]; then \
    addgroup --gid $GID app; \
    fi; \
    adduser --uid $UID --gid $GID --home $HOME --disabled-password --no-create-home app; \
    fi

RUN mkdir -p $HOME/.cache/chroma
RUN echo -n 00000000-0000-0000-0000-000000000000 > $HOME/.cache/chroma/telemetry_user_id

# Make sure the user has access to the app and root directory
RUN chown -R $UID:$GID /app $HOME

RUN if [ "$USE_OLLAMA" = "true" ]; then \
    apt-get update && \
    # Install pandoc and netcat
    apt-get install -y --no-install-recommends git build-essential pandoc netcat-openbsd curl && \
    apt-get install -y --no-install-recommends gcc python3-dev && \
    # for RAG OCR
    apt-get install -y --no-install-recommends ffmpeg libsm6 libxext6 && \
    # install helper tools
    apt-get install -y --no-install-recommends curl jq && \
    # install ollama
    curl -fsSL https://ollama.com/install.sh | sh && \
    # cleanup
    rm -rf /var/lib/apt/lists/*; \
    else \
    apt-get update && \
    # Install pandoc, netcat and gcc
    apt-get install -y --no-install-recommends git build-essential pandoc gcc netcat-openbsd curl jq && \
    apt-get install -y --no-install-recommends gcc python3-dev && \
    # for RAG OCR
    apt-get install -y --no-install-recommends ffmpeg libsm6 libxext6 && \
    # cleanup
    rm -rf /var/lib/apt/lists/*; \
    fi

# install python dependencies
COPY --chown=$UID:$GID ./backend/requirements.txt ./requirements.txt

# Copy PyTorch wheels from ComfyUI (exact filenames)
COPY --chown=$UID:$GID torch-2.7.1-cp310-cp310-manylinux_2_28_aarch64.whl /tmp/
COPY --chown=$UID:$GID torchaudio-2.7.1-cp310-cp310-manylinux_2_28_aarch64.whl /tmp/
COPY --chown=$UID:$GID torchvision-0.22.1-cp310-cp310-manylinux_2_28_aarch64.whl /tmp/

# Copy performance optimization packages
COPY --chown=$UID:$GID bitsandbytes-0.46.1-py3-none-manylinux_2_24_aarch64.whl /tmp/
COPY --chown=$UID:$GID xformers-0.0.31.post1-cp39-abi3-linux_aarch64.whl /tmp/

# Copy essential AI/ML packages
COPY --chown=$UID:$GID transformers-4.52.4-py3-none-any.whl /tmp/
COPY --chown=$UID:$GID tokenizers-0.21.1-cp39-abi3-manylinux_2_17_aarch64.manylinux2014_aarch64.whl /tmp/
COPY --chown=$UID:$GID safetensors-0.5.3-cp38-abi3-manylinux_2_17_aarch64.manylinux2014_aarch64.whl /tmp/
COPY --chown=$UID:$GID accelerate-1.1.1-py3-none-any.whl /tmp/
COPY --chown=$UID:$GID diffusers-0.34.0-py3-none-any.whl /tmp/
COPY --chown=$UID:$GID huggingface_hub-0.33.0-py3-none-any.whl /tmp/

# Copy additional performance packages
COPY --chown=$UID:$GID numpy-2.2.6-cp310-cp310-manylinux_2_17_aarch64.manylinux2014_aarch64.whl /tmp/
COPY --chown=$UID:$GID scipy-1.15.3-cp310-cp310-manylinux_2_17_aarch64.manylinux2014_aarch64.whl /tmp/
COPY --chown=$UID:$GID tiktoken-0.9.0-cp310-cp310-manylinux_2_17_aarch64.manylinux2014_aarch64.whl /tmp/
COPY --chown=$UID:$GID einops-0.8.1-py3-none-any.whl /tmp/
COPY --chown=$UID:$GID pydantic-2.11.5-py3-none-any.whl /tmp/
COPY --chown=$UID:$GID pillow-11.2.1-cp310-cp310-manylinux_2_28_aarch64.whl /tmp/
COPY --chown=$UID:$GID opencv_python-4.11.0.86-cp37-abi3-manylinux_2_17_aarch64.manylinux2014_aarch64.whl /tmp/
COPY --chown=$UID:$GID aiohttp-3.12.12-cp310-cp310-manylinux_2_17_aarch64.manylinux2014_aarch64.whl /tmp/
COPY --chown=$UID:$GID httpx-0.28.1-py3-none-any.whl /tmp/
COPY --chown=$UID:$GID requests-2.32.4-py3-none-any.whl /tmp/

RUN python3 -m pip install --upgrade pip

# Install PyTorch and dependencies
# Install PyTorch stack (optimized for Jetson Orin / CUDA 12.6 / Python 3.10)
RUN pip3 install --no-cache-dir uv

# Install PyTorch and optimized packages from local wheels
RUN if [ "$USE_CUDA" = "true" ]; then \
        # Core PyTorch stack (ComfyUI versions - proven compatibility)
        pip3 install --force-reinstall --no-deps /tmp/torch-2.7.1-cp310-cp310-manylinux_2_28_aarch64.whl && \
        pip3 install --force-reinstall --no-deps /tmp/torchaudio-2.7.1-cp310-cp310-manylinux_2_28_aarch64.whl && \
        pip3 install --force-reinstall --no-deps /tmp/torchvision-0.22.1-cp310-cp310-manylinux_2_28_aarch64.whl && \
        # Performance optimization packages
        pip3 install --force-reinstall --no-deps /tmp/bitsandbytes-0.46.1-py3-none-manylinux_2_24_aarch64.whl && \
        pip3 install --force-reinstall --no-deps /tmp/xformers-0.0.31.post1-cp39-abi3-linux_aarch64.whl && \
        # Essential AI/ML packages
        pip3 install --force-reinstall --no-deps /tmp/transformers-4.52.4-py3-none-any.whl && \
        pip3 install --force-reinstall --no-deps /tmp/tokenizers-0.21.1-cp39-abi3-manylinux_2_17_aarch64.manylinux2014_aarch64.whl && \
        pip3 install --force-reinstall --no-deps /tmp/safetensors-0.5.3-cp38-abi3-manylinux_2_17_aarch64.manylinux2014_aarch64.whl && \
        pip3 install --force-reinstall --no-deps /tmp/accelerate-1.1.1-py3-none-any.whl && \
        pip3 install --force-reinstall --no-deps /tmp/diffusers-0.34.0-py3-none-any.whl && \
        pip3 install --force-reinstall --no-deps /tmp/huggingface_hub-0.33.0-py3-none-any.whl && \
        # Additional performance packages
        pip3 install --force-reinstall --no-deps /tmp/numpy-2.2.6-cp310-cp310-manylinux_2_17_aarch64.manylinux2014_aarch64.whl && \
        pip3 install --force-reinstall --no-deps /tmp/scipy-1.15.3-cp310-cp310-manylinux_2_17_aarch64.manylinux2014_aarch64.whl && \
        pip3 install --force-reinstall --no-deps /tmp/tiktoken-0.9.0-cp310-cp310-manylinux_2_17_aarch64.manylinux2014_aarch64.whl && \
        pip3 install --force-reinstall --no-deps /tmp/einops-0.8.1-py3-none-any.whl && \
        pip3 install --force-reinstall --no-deps /tmp/pydantic-2.11.5-py3-none-any.whl && \
        pip3 install --force-reinstall --no-deps /tmp/pillow-11.2.1-cp310-cp310-manylinux_2_28_aarch64.whl && \
        pip3 install --force-reinstall --no-deps /tmp/opencv_python-4.11.0.86-cp37-abi3-manylinux_2_17_aarch64.manylinux2014_aarch64.whl && \
        pip3 install --force-reinstall --no-deps /tmp/aiohttp-3.12.12-cp310-cp310-manylinux_2_17_aarch64.manylinux2014_aarch64.whl && \
        pip3 install --force-reinstall --no-deps /tmp/httpx-0.28.1-py3-none-any.whl && \
        pip3 install --force-reinstall --no-deps /tmp/requests-2.32.4-py3-none-any.whl && \
        rm -f /tmp/*.whl; \
    else \
        pip3 install --retries 5 --timeout 300 \
            torch==2.8.0 \
            torchaudio==2.8.0 \
            torchvision==0.23.0 \
            --extra-index-url https://pypi.org/simple; \
    fi

# Install remaining requirements
RUN uv pip install --system -r requirements.txt --no-cache-dir

# copy embedding weight from build
# RUN mkdir -p /root/.cache/chroma/onnx_models/all-MiniLM-L6-v2
# COPY --from=build /app/onnx /root/.cache/chroma/onnx_models/all-MiniLM-L6-v2/onnx

# copy built frontend files
COPY --chown=$UID:$GID --from=build /app/build /app/build
COPY --chown=$UID:$GID --from=build /app/CHANGELOG.md /app/CHANGELOG.md
COPY --chown=$UID:$GID --from=build /app/package.json /app/package.json

# copy backend files
COPY --chown=$UID:$GID ./backend .

EXPOSE 8080

HEALTHCHECK CMD curl --silent --fail http://localhost:${PORT:-8080}/health | jq -ne 'input.status == true' || exit 1

USER $UID:$GID

ARG BUILD_HASH
ENV WEBUI_BUILD_VERSION=${BUILD_HASH}
ENV DOCKER=true

CMD [ "bash", "start.sh"]
