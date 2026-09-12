#!/bin/bash
# ---------------------------------------------------------------------------
# sa-bootstrap — remplace la partie d'install.sh qui touche la base de donnees.
#
# Execute par le service one-shot `sentry-bootstrap`, apres `snuba-bootstrap`.
# Idempotent : rejoue a chaque demarrage de la stack sans effet de bord.
#
#   1. bucket S3 `nodestore` sur SeaweedFS + politique de retention
#   2. migrations Postgres + creation des topics Kafka
#   3. compte administrateur initial (si les variables sont fournies)
# ---------------------------------------------------------------------------
set -euo pipefail

log() { printf '\033[1;36m[bootstrap]\033[0m %s\n' "$*"; }

# --- 1. Nodestore ----------------------------------------------------------
# Sans la politique de cycle de vie, le bucket grossit indefiniment meme quand
# Sentry a oublie les evenements cote Postgres/ClickHouse.
log "Bucket nodestore sur ${SENTRY_S3_ENDPOINT:-http://seaweedfs:8333}"
python - <<'PYEOF'
import os, sys, time
import boto3
from botocore.client import Config
from botocore.exceptions import ClientError, EndpointConnectionError

ENDPOINT = os.environ.get("SENTRY_S3_ENDPOINT") or "http://seaweedfs:8333"
BUCKET = "nodestore"
RETENTION = int(os.environ.get("SENTRY_EVENT_RETENTION_DAYS") or 30)
DEADLINE = time.time() + int(os.environ.get("SENTRY_S3_WAIT_SECONDS") or 180)

s3 = boto3.client(
    "s3",
    endpoint_url=ENDPOINT,
    aws_access_key_id=os.environ.get("SENTRY_S3_ACCESS_KEY") or "sentry",
    aws_secret_access_key=os.environ.get("SENTRY_S3_SECRET_KEY") or "sentry",
    region_name="us-east-1",
    config=Config(s3={"addressing_style": "path"}, signature_version="s3v4"),
)

while True:
    try:
        buckets = {b["Name"] for b in s3.list_buckets().get("Buckets", [])}
        break
    except (EndpointConnectionError, ClientError) as exc:
        if time.time() >= DEADLINE:
            print(f"SeaweedFS injoignable sur {ENDPOINT}: {exc}", file=sys.stderr)
            sys.exit(1)
        time.sleep(3)

if BUCKET not in buckets:
    s3.create_bucket(Bucket=BUCKET)
    print(f"  bucket '{BUCKET}' cree")
else:
    print(f"  bucket '{BUCKET}' deja present")

s3.put_bucket_lifecycle_configuration(
    Bucket=BUCKET,
    LifecycleConfiguration={"Rules": [{
        "ID": "Sentry-Nodestore-Rule",
        "Status": "Enabled",
        "Filter": {"Prefix": ""},
        "Expiration": {"Days": RETENTION},
    }]},
)
print(f"  retention fixee a {RETENTION} jours")
PYEOF

# --- 2. Migrations ---------------------------------------------------------
if [ "${SKIP_SENTRY_MIGRATIONS:-0}" = "1" ]; then
  log "Migrations Sentry ignorees (SKIP_SENTRY_MIGRATIONS=1)"
else
  log "Migrations Postgres et creation des topics Kafka"
  sentry upgrade --noinput --create-kafka-topics
fi

# --- 3. Compte administrateur ---------------------------------------------
if [ -n "${SENTRY_ADMIN_EMAIL:-}" ] && [ -n "${SENTRY_ADMIN_PASSWORD:-}" ]; then
  if sentry createuser \
       --email "${SENTRY_ADMIN_EMAIL}" \
       --password "${SENTRY_ADMIN_PASSWORD}" \
       --superuser --no-input 2>/dev/null; then
    log "Compte administrateur cree : ${SENTRY_ADMIN_EMAIL}"
  else
    log "Compte ${SENTRY_ADMIN_EMAIL} deja present, rien a faire"
  fi
else
  log "Pas de compte admin a creer. Manuellement :"
  log "  docker compose run --rm sentry-bootstrap sentry createuser"
fi

log "Termine."
