FROM python:3.12-slim AS builder
ARG TARGETARCH=amd64
ARG ENGINE_COMMIT=5313d53165d64207e44be533358f2334c0657ee8
ARG LUNE_VERSION=0.10.5
ARG LUAU_VERSION=0.739
ARG STYLUA_VERSION=2.5.2
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl git unzip && rm -rf /var/lib/apt/lists/*
COPY requirements.txt /build/requirements.txt
RUN python -m pip wheel --wheel-dir /wheels -r /build/requirements.txt && python -m pip wheel --no-deps --wheel-dir /wheels "git+https://github.com/binxgtl/luau-vmp-deobf.git@${ENGINE_COMMIT}"
RUN test "${TARGETARCH}" = amd64 \
 && curl --fail --location --retry 3 --max-time 120 "https://github.com/lune-org/lune/releases/download/v${LUNE_VERSION}/lune-${LUNE_VERSION}-linux-x86_64.zip" -o /tmp/lune.zip \
 && echo '1fb5dee6a1afa1d300092805c6e660fe06144d29dd68c45cf6956f040667f791  /tmp/lune.zip' | sha256sum --check --strict \
 && unzip /tmp/lune.zip -d /tmp/lune && install -m 0755 /tmp/lune/lune /usr/local/bin/lune
RUN curl --fail --location --retry 3 --max-time 120 "https://github.com/luau-lang/luau/releases/download/${LUAU_VERSION}/luau-ubuntu.zip" -o /tmp/luau.zip \
 && echo '8a9b4b381021722c82d6e6cda0964b5c9e7f354ec1035fcd8b657acc22e49247  /tmp/luau.zip' | sha256sum --check --strict \
 && unzip /tmp/luau.zip -d /tmp/luau \
 && install -m 0755 /tmp/luau/luau /tmp/luau/luau-compile /tmp/luau/luau-ast /usr/local/bin/
RUN curl --fail --location --retry 3 --max-time 120 "https://github.com/JohnnyMorganz/StyLua/releases/download/v${STYLUA_VERSION}/stylua-linux-x86_64.zip" -o /tmp/stylua.zip \
 && echo 'bcb0d855e91f102f28a370e850f8566b3b44b79e6274d806ea5246837c0fd5ab  /tmp/stylua.zip' | sha256sum --check --strict \
 && unzip /tmp/stylua.zip -d /tmp/stylua && install -m 0755 /tmp/stylua/stylua /usr/local/bin/stylua
RUN curl --fail --location --max-time 30 "https://raw.githubusercontent.com/luau-lang/luau/${LUAU_VERSION}/LICENSE.txt" -o /build/LUAU-LICENSE \
 && curl --fail --location --max-time 30 "https://raw.githubusercontent.com/binxgtl/luau-vmp-deobf/${ENGINE_COMMIT}/LICENSE" -o /build/ENGINE-LICENSE \
 && curl --fail --location --max-time 30 "https://raw.githubusercontent.com/JohnnyMorganz/StyLua/v${STYLUA_VERSION}/LICENSE.md" -o /build/STYLUA-LICENSE
FROM python:3.12-slim AS runtime
RUN useradd --create-home --uid 10001 app
COPY --from=builder /wheels /wheels
RUN python -m pip install --no-cache-dir /wheels/* && rm -rf /wheels
COPY --from=builder /usr/local/bin/lune /usr/local/bin/lune
COPY --from=builder /usr/local/bin/luau /usr/local/bin/luau
COPY --from=builder /usr/local/bin/luau-compile /usr/local/bin/luau-compile
COPY --from=builder /usr/local/bin/luau-ast /usr/local/bin/luau-ast
COPY --from=builder /usr/local/bin/stylua /usr/local/bin/stylua
WORKDIR /app
COPY --from=builder /build/ENGINE-LICENSE /build/LUAU-LICENSE /build/STYLUA-LICENSE /app/
COPY --chown=app:app *.py ./
COPY --chown=app:app tests ./tests
COPY --chown=app:app static ./static
ENV PORT=8080 PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
USER app
EXPOSE 8080
CMD ["python", "server.py"]
FROM runtime AS validation
USER root
RUN python -m pip install --no-cache-dir httpx==0.28.1
USER app
RUN python -m luauvmp --help >/dev/null && lune --version && luau --help >/dev/null && stylua --version && python smoke.py && python -m unittest discover -s tests -v && touch /tmp/validation-passed
FROM runtime AS final
COPY --from=validation /tmp/validation-passed /app/validation-passed
