# ---------------------------------------------------------------------------
# Overlay SoftArtisan — concatene a sentry.conf.example.py au build.
#
# Tout est pilote par variables d'environnement pour qu'une seule image serve
# tous les environnements (Coolify injecte les valeurs au deploiement).
# ---------------------------------------------------------------------------

import os as _os


def _envstr(key, default=""):
    return (_os.environ.get(key) or default).strip()


def _envint(key, default):
    try:
        return int(_os.environ.get(key) or default)
    except ValueError:
        return default


def _envbool(key, default=False):
    val = _envstr(key)
    if not val:
        return default
    return val.lower() in ("1", "true", "yes", "on")


# --- URL publique, CSRF et terminaison TLS en amont ------------------------
# Coolify/Traefik termine le TLS : Sentry ne voit que du HTTP en interne, il
# faut donc lui dire explicitement quel est le schema d'origine.
_url_prefix = _envstr("SENTRY_SYSTEM_URL_PREFIX").rstrip("/")

if _url_prefix:
    SENTRY_OPTIONS["system.url-prefix"] = _url_prefix

    _origins = {_url_prefix}
    for _extra in _envstr("SENTRY_CSRF_TRUSTED_ORIGINS").split(","):
        _extra = _extra.strip().rstrip("/")
        if _extra:
            _origins.add(_extra)
    CSRF_TRUSTED_ORIGINS = sorted(_origins)

    if _url_prefix.startswith("https://"):
        SECURE_PROXY_SSL_HEADER = ("HTTP_X_FORWARDED_PROTO", "https")
        USE_X_FORWARDED_HOST = True
        SESSION_COOKIE_SECURE = True
        CSRF_COOKIE_SECURE = True
        SOCIAL_AUTH_REDIRECT_IS_HTTPS = True

# Le proxy interne (nginx) et Traefik sont les seuls a parler a uwsgi.
ALLOWED_HOSTS = ["*"]


# --- Nodestore sur SeaweedFS (S3) -----------------------------------------
# Sans ceci, le corps des evenements est stocke dans Postgres et la base
# grossit de plusieurs Go par semaine. C'est le premier poste d'economie.
SENTRY_NODESTORE = "sentry_nodestore_s3.S3PassthroughDjangoNodeStorage"
SENTRY_NODESTORE_OPTIONS = {
    "compression": True,
    "endpoint_url": _envstr("SENTRY_S3_ENDPOINT", "http://seaweedfs:8333"),
    "bucket_path": "nodestore",
    "bucket_name": "nodestore",
    "region_name": "us-east-1",
    "aws_access_key_id": _envstr("SENTRY_S3_ACCESS_KEY", "sentry"),
    "aws_secret_access_key": _envstr("SENTRY_S3_SECRET_KEY", "sentry"),
    "read_through": True,
    "delete_through": True,
}


# --- Dimensionnement du serveur web ---------------------------------------
# Chaque worker uwsgi coute ~250-350 Mo RSS. 3 workers x 4 threads (defaut
# upstream) est genereux pour une instance interne : 2 x 4 suffit largement
# et economise ~300 Mo. `reload-on-rss` recycle les workers qui derivent.
SENTRY_WEB_OPTIONS.update(
    {
        "workers": _envint("SENTRY_WEB_WORKERS", 2),
        "threads": _envint("SENTRY_WEB_THREADS", 4),
        "harakiri": _envint("SENTRY_WEB_HARAKIRI", 85),
        "reload-on-rss": _envint("SENTRY_WEB_RELOAD_ON_RSS", 500),
    }
)


# --- Telemetrie sortante ---------------------------------------------------
# Coupe le beacon et l'auto-reporting : aucun appel sortant non sollicite.
SENTRY_BEACON = _envbool("SENTRY_BEACON", False)


# --- Ouverture des inscriptions -------------------------------------------
SENTRY_FEATURES["auth:register"] = _envbool("SENTRY_ALLOW_REGISTRATION", False)
SENTRY_OPTIONS["auth.allow-registration"] = _envbool("SENTRY_ALLOW_REGISTRATION", False)


# --- Filet : namespace e-mail jamais vide ----------------------------------
# sentry.conf.example.py derive mail.list-namespace de SENTRY_MAIL_HOST ; une
# valeur vide fait planter l'import du module e-mail au demarrage (IndexError
# dans is_valid_dot_atom). Reparer ici, quel que soit l'environnement.
if not (SENTRY_OPTIONS.get("mail.list-namespace") or "").strip():
    SENTRY_OPTIONS["mail.list-namespace"] = "localhost"
    SENTRY_OPTIONS["mail.from"] = "sentry@localhost"


# --- SMTP ------------------------------------------------------------------
# Si SENTRY_SMTP_HOST est fourni, on bypasse le conteneur `smtp` interne
# (exim) au profit d'un relais externe : un service de moins a faire tourner.
_smtp_host = _envstr("SENTRY_SMTP_HOST")
if _smtp_host:
    SENTRY_OPTIONS["mail.backend"] = "smtp"
    SENTRY_OPTIONS["mail.host"] = _smtp_host
    SENTRY_OPTIONS["mail.port"] = _envint("SENTRY_SMTP_PORT", 587)
    SENTRY_OPTIONS["mail.username"] = _envstr("SENTRY_SMTP_USERNAME")
    SENTRY_OPTIONS["mail.password"] = _envstr("SENTRY_SMTP_PASSWORD")
    SENTRY_OPTIONS["mail.use-tls"] = _envbool("SENTRY_SMTP_USE_TLS", True)
    SENTRY_OPTIONS["mail.use-ssl"] = _envbool("SENTRY_SMTP_USE_SSL", False)
    if _envstr("SENTRY_SMTP_FROM"):
        SENTRY_OPTIONS["mail.from"] = _envstr("SENTRY_SMTP_FROM")
