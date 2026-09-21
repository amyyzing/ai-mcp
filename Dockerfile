FROM python:3.12-slim AS builder
ARG TARGETARCH=amd64
ARG ENGINE_COMMIT=5313d53165d64207e44be533358f2334c0657ee8
ARG LUNE_VERSION=0.10.5
ARG LUAU_VERSION=0.739
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl git unzip && rm -rf /var/lib/apt/lists/*
COPY requirements.txt /build/requirements.txt
RUN python -m pip wheel --wheel-dir /wheels -r /build/requirements.txt && python -m pip wheel --no-deps --wheel-dir /wheels "git+https://github.com/binxgtl/luau-vmp-deobf.git@${ENGINE_COMMIT}"
RUN case "${TARGETARCH}" in \
 amd64) arch=x86_64; sha=1fb5dee6a1afa1d300092805c6e660fe06144d29dd68c45cf6956f040667f791 ;; \
 arm64) arch=aarch64; sha=176e1272d41ba3d9ea30087b528048a4a97e3d74cfa0eaa5d35d9e0d4122caa6 ;; \
 *) exit 1 ;; esac \
 && curl --fail --location --retry 3 --max-time 120 "https://github.com/lune-org/lune/releases/download/v${LUNE_VERSION}/lune-${LUNE_VERSION}-linux-${arch}.zip" -o /tmp/lune.zip \
 && echo "${sha}  /tmp/lune.zip" | sha256sum --check --strict \
 && unzip /tmp/lune.zip -d /tmp/lune && install -m 0755 /tmp/lune/lune /usr/local/bin/lune
# Official release archive, pinned and hash-verified; Ubuntu asset is x86_64.
RUN test "${TARGETARCH}" = amd64 \
 && curl --fail --location --retry 3 --max-time 120 "https://github.com/luau-lang/luau/releases/download/${LUAU_VERSION}/luau-ubuntu.zip" -o /tmp/luau.zip \
 && echo "8a9b4b381021722c82d6e6cda0964b5c9e7f354ec1035fcd8b657acc22e49247  /tmp/luau.zip" | sha256sum --check --strict \
 && unzip /tmp/luau.zip -d /tmp/luau \
 && install -m 0755 /tmp/luau/luau /usr/local/bin/luau \
 && install -m 0755 /tmp/luau/luau-compile /usr/local/bin/luau-compile \
 && install -m 0755 /tmp/luau/luau-ast /usr/local/bin/luau-ast
RUN curl --fail --location --max-time 30 "https://raw.githubusercontent.com/luau-lang/luau/${LUAU_VERSION}/LICENSE.txt" -o /build/LUAU-LICENSE
RUN curl --fail --location --max-time 30 "https://raw.githubusercontent.com/binxgtl/luau-vmp-deobf/${ENGINE_COMMIT}/LICENSE" -o /build/ENGINE-LICENSE
FROM python:3.12-slim
RUN useradd --create-home --uid 10001 app
COPY --from=builder /wheels /wheels
RUN python -m pip install --no-cache-dir /wheels/* && rm -rf /wheels
COPY --from=builder /usr/local/bin/lune /usr/local/bin/lune
COPY --from=builder /usr/local/bin/luau /usr/local/bin/luau
COPY --from=builder /usr/local/bin/luau-compile /usr/local/bin/luau-compile
COPY --from=builder /usr/local/bin/luau-ast /usr/local/bin/luau-ast
WORKDIR /app
COPY --from=builder /build/ENGINE-LICENSE /app/ENGINE-LICENSE
COPY --from=builder /build/LUAU-LICENSE /app/LUAU-LICENSE
COPY --chown=app:app *.py ./
COPY --chown=app:app tests ./tests
COPY --chown=app:app static ./static
RUN python -m luauvmp --help >/dev/null && lune --version && luau --help >/dev/null && luau-compile --help >/dev/null && python smoke.py && python -m unittest discover -s tests -p test_recovery.py && python -m unittest discover -s tests -p test_official_language.py -v
ENV PORT=8080 PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
USER app
EXPOSE 8080
CMD ["python", "server.py"]
