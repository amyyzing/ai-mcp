FROM python:3.12-slim AS builder

ARG TARGETARCH
ARG LURAPH_DEOBF_COMMIT=5313d53165d64207e44be533358f2334c0657ee8
ARG LUNE_VERSION=0.10.5
ARG ZSTANDARD_VERSION=0.25.0

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl git unzip \
    && rm -rf /var/lib/apt/lists/*

RUN python -m pip wheel --wheel-dir /wheels "zstandard==${ZSTANDARD_VERSION}" \
    && python -m pip wheel --no-deps --wheel-dir /wheels \
      "git+https://github.com/binxgtl/luau-vmp-deobf.git@${LURAPH_DEOBF_COMMIT}"

RUN case "${TARGETARCH}" in \
      amd64) lune_arch="x86_64"; lune_sha="1fb5dee6a1afa1d300092805c6e660fe06144d29dd68c45cf6956f040667f791" ;; \
      arm64) lune_arch="aarch64"; lune_sha="176e1272d41ba3d9ea30087b528048a4a97e3d74cfa0eaa5d35d9e0d4122caa6" ;; \
      *) echo "Unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
    && curl --fail --location --retry 3 \
      "https://github.com/lune-org/lune/releases/download/v${LUNE_VERSION}/lune-${LUNE_VERSION}-linux-${lune_arch}.zip" \
      --output /tmp/lune.zip \
    && echo "${lune_sha}  /tmp/lune.zip" | sha256sum --check --strict \
    && unzip /tmp/lune.zip -d /tmp/lune \
    && install -m 0755 /tmp/lune/lune /usr/local/bin/lune

FROM python:3.12-slim

RUN useradd --create-home --uid 10001 worker
COPY --from=builder /wheels /wheels
RUN python -m pip install --no-cache-dir /wheels/* \
    && rm -rf /wheels
COPY --from=builder /usr/local/bin/lune /usr/local/bin/lune

WORKDIR /app
COPY services/luraph-worker/server.py /app/server.py

ENV PORT=8080 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

USER worker
EXPOSE 8080
CMD ["python", "/app/server.py"]
