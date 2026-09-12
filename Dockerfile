# syntax=docker/dockerfile:1.9
#
# Sentry self-hosted — images "config-baked" pour Coolify
# https://github.com/softartisan-inc/sentry-coolify
#
# Coolify ne deploie qu'UN fichier compose : aucun bind mount de fichiers
# voisins n'est possible. Toute la configuration doit donc vivre dans les
# images. Ce Dockerfile telecharge la release upstream epinglee, applique nos
# overlays, et produit 9 images derivees des images officielles Sentry.
#
#   docker buildx build --target sentry -t ghcr.io/softartisan-inc/sentry-sa:26.8.0 .
#
# Cibles : upstream · sentry · sentry-cleanup · snuba · clickhouse · nginx
#          relay · symbolicator · taskbroker · valkey

ARG SELF_HOSTED_VERSION=26.8.0
ARG SENTRY_IMAGE=ghcr.io/getsentry/sentry:26.8.0
ARG SNUBA_IMAGE=ghcr.io/getsentry/snuba:26.8.0
ARG RELAY_IMAGE=ghcr.io/getsentry/relay:26.8.0
ARG SYMBOLICATOR_IMAGE=ghcr.io/getsentry/symbolicator:26.8.0
ARG TASKBROKER_IMAGE=ghcr.io/getsentry/taskbroker:26.8.0
ARG CLICKHOUSE_IMAGE=altinity/clickhouse-server:25.3.6.10034.altinitystable
ARG NGINX_IMAGE=nginx:1.31.3-alpine
ARG VALKEY_IMAGE=valkey/valkey:8.1.9-alpine
# Shell statique pour l'image relay, qui est distroless (voir stage relay).
ARG BUSYBOX_IMAGE=busybox:1.37.0-musl
# sentry-nodestore-s3 ne publie ni tag ni release PyPI : epingle par SHA de
# commit pour garder le build reproductible.
ARG NODESTORE_S3_REF=a1457f93d266485d101ae3b29fa03028bb3d63c2

# ---------------------------------------------------------------------------
# Stage 0 — release upstream + overlays
# ---------------------------------------------------------------------------
FROM alpine:3.22 AS upstream

ARG SELF_HOSTED_VERSION
WORKDIR /src

RUN apk add --no-cache curl tar

RUN curl -fsSL "https://codeload.github.com/getsentry/self-hosted/tar.gz/refs/tags/${SELF_HOSTED_VERSION}" \
    | tar -xz --strip-components=1

COPY overlays/sentry.conf.append.py /overlays/sentry.conf.append.py

# Overlay config.yml : en profil errors-only, vroom n'est pas demarre, il ne
# faut donc pas que Sentry tente de joindre un bucket de profils.
COPY <<'EOF' /overlays/config.append.yml

# --- Overlay SoftArtisan ---------------------------------------------------
# `system.secret-key` reste a '!!changeme!!' plus haut : il est ecrase au
# demarrage par la variable d'environnement SENTRY_SYSTEM_SECRET_KEY. C'est ce
# qui permet a Coolify de gerer le secret sans rebuild d'image.
filestore.profiles-backend: 'filesystem'
filestore.profiles-options:
  location: '/data/profiles'
EOF

# Reproduit la partie "fichiers" d'install.sh, sans interaction.
RUN set -eux; \
    cp sentry/sentry.conf.example.py sentry/sentry.conf.py; \
    cat /overlays/sentry.conf.append.py >> sentry/sentry.conf.py; \
    cp sentry/config.example.yml sentry/config.yml; \
    cat /overlays/config.append.yml >> sentry/config.yml; \
    cp relay/config.example.yml relay/config.yml; \
    cp symbolicator/config.example.yml symbolicator/config.yml; \
    cp geoip/GeoLite2-City.mmdb.empty geoip/GeoLite2-City.mmdb; \
    rm -f sentry/requirements.txt sentry/Dockerfile sentry/enhance-image.sh

# ---------------------------------------------------------------------------
# Stage 1 — Sentry (web, consumers, taskworker, bootstrap)
# ---------------------------------------------------------------------------
FROM ${SENTRY_IMAGE} AS sentry

LABEL org.opencontainers.image.source="https://github.com/softartisan-inc/sentry-coolify" \
      org.opencontainers.image.title="sentry-sa" \
      org.opencontainers.image.licenses="FSL-1.1-ALv2"

USER 0

# Nodestore S3 : sans lui, le corps des evenements est stocke dans Postgres,
# qui grossit de plusieurs Go par semaine.
# L'image sentry 26.x est geree par uv : le venv /.venv (premier du PATH) ne
# contient pas pip, et le Python systeme est verrouille (PEP 668). `uv pip`
# ignore UV_PROJECT_ENVIRONMENT et exige un venv decouvrable, d'ou le
# VIRTUAL_ENV explicite ; repli ensurepip + pip du venv si uv ne suffit pas.
# L'import final fait foi.
ARG NODESTORE_S3_REF
RUN set -e; \
    url="https://github.com/getsentry/sentry-nodestore-s3/archive/${NODESTORE_S3_REF}.zip"; \
    export VIRTUAL_ENV=/.venv; \
    if command -v uv >/dev/null 2>&1; then \
        uv pip install --no-cache "$url" || echo "uv a echoue, repli sur pip"; \
    fi; \
    if ! python -c "import sentry_nodestore_s3" 2>/dev/null; then \
        python -m ensurepip --upgrade >/dev/null 2>&1 || true; \
        python -m pip install --no-cache-dir --disable-pip-version-check "$url"; \
    fi; \
    python -c "import sentry_nodestore_s3"

COPY --from=upstream /src/sentry/ /etc/sentry/
COPY --from=upstream /src/geoip/ /geoip/
COPY --chmod=755 overlays/bootstrap.sh /usr/local/bin/sa-bootstrap

# Entrypoint : celui d'upstream, plus la prise en charge des CA personnalisees
# montees sur /usr/local/share/ca-certificates.
COPY --chmod=755 <<'EOF' /etc/sentry/entrypoint.sh
#!/bin/bash
set -e
if [ -d /usr/local/share/ca-certificates ] && [ -n "$(ls -A /usr/local/share/ca-certificates/ 2>/dev/null)" ]; then
  update-ca-certificates
fi
source /docker-entrypoint.sh
EOF

ENV SENTRY_CONF=/etc/sentry \
    PYTHONUSERBASE=/data/custom-packages \
    SNUBA=http://snuba-api:1218 \
    DEFAULT_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt \
    REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt \
    GRPC_DEFAULT_SSL_ROOTS_FILE_PATH_ENV_VAR=/etc/ssl/certs/ca-certificates.crt

ENTRYPOINT ["/etc/sentry/entrypoint.sh"]
CMD ["run", "web"]

# ---------------------------------------------------------------------------
# Stage 2 — cron de purge (sentry cleanup)
# ---------------------------------------------------------------------------
FROM sentry AS sentry-cleanup

RUN apt-get update \
    && apt-get install -y --no-install-recommends cron \
    && rm -rf /var/lib/apt/lists/*

COPY --chmod=755 --from=upstream /src/cron/entrypoint.sh /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]

# ---------------------------------------------------------------------------
# Stage 3 — Snuba (ajoute uniquement le script de healthcheck)
# ---------------------------------------------------------------------------
FROM ${SNUBA_IMAGE} AS snuba
LABEL org.opencontainers.image.source="https://github.com/softartisan-inc/sentry-coolify"
COPY --from=upstream /src/snuba/api_healthcheck.py /usr/src/snuba/api_healthcheck.py

# ---------------------------------------------------------------------------
# Stage 4 — ClickHouse (logs systeme desactives + plafond memoire)
# ---------------------------------------------------------------------------
FROM ${CLICKHOUSE_IMAGE} AS clickhouse
LABEL org.opencontainers.image.source="https://github.com/softartisan-inc/sentry-coolify"
COPY --from=upstream /src/clickhouse/config.xml /etc/clickhouse-server/config.d/sentry.xml
COPY --from=upstream /src/clickhouse/default-password.xml /etc/clickhouse-server/users.d/default-password.xml

# ---------------------------------------------------------------------------
# Stage 5 — Nginx (routage interne : /api/store et DSN vers relay, reste vers web)
# ---------------------------------------------------------------------------
FROM ${NGINX_IMAGE} AS nginx
LABEL org.opencontainers.image.source="https://github.com/softartisan-inc/sentry-coolify"
COPY --from=upstream /src/nginx.conf /etc/nginx/nginx.conf

# ---------------------------------------------------------------------------
# Stage 6 — Relay (config + credentials generes au premier demarrage)
#
# L'image relay 26.x est distroless (User 65532, entrypoint /bin/relay, ni
# shell ni coreutils) : le stage n'a aucun RUN, et busybox statique fournit le
# sh minimal dont l'entrypoint de generation des credentials a besoin.
# ---------------------------------------------------------------------------
FROM ${BUSYBOX_IMAGE} AS busybox

FROM ${RELAY_IMAGE} AS relay
LABEL org.opencontainers.image.source="https://github.com/softartisan-inc/sentry-coolify"
USER 0
COPY --from=busybox /bin/ /busybox/
COPY --from=upstream /src/relay/config.yml /etc/relay/config.yml
COPY --from=upstream /src/geoip/ /geoip/

# Relay a besoin d'un couple de cles persistant. Upstream le genere depuis
# l'hote via install.sh ; ici le service se debrouille seul.
COPY --chmod=755 <<'EOF' /usr/local/bin/sa-relay-entrypoint
#!/busybox/sh
set -e
export PATH="/busybox:$PATH"
RELAY_HOME="${RELAY_HOME:-/work/.relay}"
mkdir -p "$RELAY_HOME"
[ -f "$RELAY_HOME/config.yml" ] || cp /etc/relay/config.yml "$RELAY_HOME/config.yml"
if [ ! -s "$RELAY_HOME/credentials.json" ]; then
  echo "[relay] generation des credentials dans $RELAY_HOME"
  relay credentials generate --stdout > "$RELAY_HOME/credentials.json.tmp"
  mv "$RELAY_HOME/credentials.json.tmp" "$RELAY_HOME/credentials.json"
fi
exec relay "$@"
EOF

ENTRYPOINT ["/busybox/sh", "/usr/local/bin/sa-relay-entrypoint"]
CMD ["run"]

# ---------------------------------------------------------------------------
# Stage 7 — Symbolicator
# ---------------------------------------------------------------------------
FROM ${SYMBOLICATOR_IMAGE} AS symbolicator
LABEL org.opencontainers.image.source="https://github.com/softartisan-inc/sentry-coolify"
COPY --from=upstream /src/symbolicator/config.yml /etc/symbolicator/config.yml

# ---------------------------------------------------------------------------
# Stage 8 — Taskbroker
# ---------------------------------------------------------------------------
FROM ${TASKBROKER_IMAGE} AS taskbroker
LABEL org.opencontainers.image.source="https://github.com/softartisan-inc/sentry-coolify"
COPY --from=upstream /src/taskbroker/config.yml /etc/taskbroker/config.yml

# ---------------------------------------------------------------------------
# Stage 9 — Valkey (redis.conf upstream : maxmemory-policy volatile-lru)
# ---------------------------------------------------------------------------
FROM ${VALKEY_IMAGE} AS valkey
LABEL org.opencontainers.image.source="https://github.com/softartisan-inc/sentry-coolify"
COPY --from=upstream /src/redis.conf /usr/local/etc/redis/redis.conf
CMD ["valkey-server", "/usr/local/etc/redis/redis.conf"]
