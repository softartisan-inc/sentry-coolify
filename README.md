# sentry-coolify

Sentry self-hosted **26.8.0**, packagé pour un déploiement Coolify en un seul
fichier compose, avec une empreinte mémoire tenue.

---

## Pourquoi ce dépôt existe

La stack officielle (`getsentry/self-hosted`) n'est pas déployable telle quelle
sous Coolify, pour trois raisons :

1. **Elle monte une dizaine de fichiers depuis l'hôte** — `sentry/sentry.conf.py`,
   `nginx.conf`, `clickhouse/config.xml`, `relay/config.yml`,
   `symbolicator/config.yml`, `taskbroker/config.yml`, `redis.conf`. Coolify ne
   déploie qu'un fichier compose : ces bind mounts n'ont aucune source.
2. **Elle construit trois images en local** avec `pull_policy: never`, ce qui
   suppose un `docker compose build` préalable sur l'hôte.
3. **Elle dépend de `install.sh`** pour générer les secrets, créer les volumes,
   jouer les migrations Postgres et ClickHouse, créer les topics Kafka, le
   bucket S3 et les credentials Relay. Coolify se contente d'un `up`.

Ce dépôt règle les trois :

| Problème | Solution ici |
|---|---|
| Fichiers montés | Configuration bakée dans 9 images publiées sur GHCR |
| Build local | Workflow GitHub Actions, images versionnées et épinglées |
| `install.sh` | Services one-shot `snuba-bootstrap` et `sentry-bootstrap`, idempotents |

---

## À quoi sert chaque fichier

Six fichiers de code, quatre de documentation ou d'hygiène de dépôt.

### Le code

| Fichier | Rôle | Pourquoi il est séparé |
|---|---|---|
| `Dockerfile` | Construit les 9 images (une cible par service qui a besoin d'un fichier de config). Télécharge la release upstream épinglée, applique les overlays. | C'est ce qui remplace les bind mounts impossibles sous Coolify. |
| `docker-compose.yaml` | La stack : 30 services, leurs dépendances, plafonds mémoire, healthchecks, volumes. C'est le seul fichier que Coolify voit. | — |
| `.env.example` | Le strict minimum à coller dans Coolify (`SENTRY_ADMIN_EMAIL`, `SENTRY_MAIL_HOST` + les `SERVICE_*` hors Coolify). Toutes les autres variables sont documentées dans la section « Variables d'environnement ». | Séparé pour être collé tel quel dans l'onglet Environment Variables de Coolify. |
| `overlays/sentry.conf.append.py` | Configuration Sentry pilotée par l'environnement : `system.url-prefix`, CSRF, TLS derrière proxy, nodestore S3, workers uwsgi, SMTP. Concaténé à `sentry.conf.example.py` au build. | Fichier Python à part entière (~110 lignes) : l'inliner dans le Dockerfile le rendrait illisible. C'est le fichier que vous éditerez le plus souvent. |
| `overlays/bootstrap.sh` | Remplace `install.sh` : crée le bucket S3 avec sa politique de rétention, joue les migrations Postgres, crée les topics Kafka et le compte admin. Idempotent. | Exécuté au runtime par le service `sentry-bootstrap`, pas au build. |
| `.github/workflows/build-images.yml` | Construit et publie les 9 images sur GHCR. Valide aussi la syntaxe du compose. | — |

### Le reste

| Fichier | Rôle |
|---|---|
| `README.md` | Ce document. |
| `sentry.yaml` | Le template pour la PR `coollabsio/coolify` : le même compose, avec l'en-tête `# documentation:` / `# slogan:` / `# port:` et sans port publié. Généré depuis `docker-compose.yaml`. |
| `CLAUDE.md` | Guide de travail dans le dépôt pour Claude Code : architecture, commandes, points de vigilance. |
| `.gitignore` | `.env`, notes internes et fichiers temporaires. |

### Ce qui a été volontairement inliné

Quatre bouts de configuration triviaux vivent directement dans le `Dockerfile`
sous forme de heredocs plutôt que dans des fichiers séparés : l'entrypoint
Sentry, l'entrypoint Relay, l'overlay `config.yml`, et le script de création du
bucket (dans `bootstrap.sh`). Ils font 5 à 20 lignes chacun et ne s'éditent
quasiment jamais.

---

## Domaine et port

Le fonctionnement est celui de n'importe quelle ressource Coolify.

**Dans l'UI :** ouvrez la ressource, service `nginx`, champ *Domains*, saisissez
`https://sentry.votre-domaine.com`. Coolify génère le certificat Let's Encrypt
et pose les labels Traefik.

**Ce qui le rend possible**, côté compose, c'est une seule ligne sur le service
`nginx` :

```yaml
environment:
  - SERVICE_URL_SENTRY_80
```

Le `80` est le port **interne** du conteneur nginx, pas le port public — le
public reste 80/443 chez Traefik. Cette variable magique fait deux choses :
elle fait apparaître le champ *Domains* sur ce service, et elle publie
`${SERVICE_URL_SENTRY}` (URL complète avec schéma) et `${SERVICE_FQDN_SENTRY}`
(hôte nu, sans schéma) pour toute la stack.

Les conteneurs Sentry consomment `${SERVICE_URL_SENTRY}` via `SENTRY_SYSTEM_URL_PREFIX`,
qui alimente `system.url-prefix`. C'est ce qui fait que les liens dans les
e-mails d'alerte pointent vers le bon domaine, et que le CSRF ne rejette pas
vos connexions.

> **Après un changement de domaine, redéployez.** Sentry lit l'URL au démarrage
> du process : un simple restart des conteneurs ne suffit pas à propager la
> nouvelle valeur.

**Accès direct sans Traefik** (dev local, tunnel SSH, debug) : la variable
`SENTRY_BIND` contrôle le port publié sur l'hôte, `127.0.0.1:9000` par défaut.
Elle ne bind que la loopback, donc sous Coolify elle n'interfère pas avec le
routage. Mettez `0.0.0.0:9000` pour ouvrir sur le réseau, ou supprimez le bloc
`ports:` du service `nginx` pour ne rien publier.

Le template `sentry.yaml` n'a volontairement aucun `ports:` : dans un
template public, publier un port sur l'hôte est un mauvais défaut.

---

## Profil « errors-only »

Le compose déploie **30 services au lieu de 57** — 28 services pérennes, plus
les deux one-shot d'initialisation (`snuba-bootstrap`, `sentry-bootstrap`).
Ce qui est retiré :

- tracing de performance et spans (`transactions-consumer`, `process-spans`,
  `process-segments`, forwarders associés) ;
- métriques et métriques génériques ;
- session replay ;
- profiling (`vroom` et ses trois consumers Snuba) ;
- cron monitors et uptime monitoring ;
- `launchpad`.

Ce qui reste complet : ingestion et déduplication des erreurs, alertes et
règles, sourcemaps et symbolication, intégrations (GitHub, Slack, Discord,
SSO), API, recherche, rétention.

Repasser en `feature-complete` demande de réintroduire les 29 services et
d'environ doubler la RAM. Sur une instance interne d'agence, l'arbitrage penche
nettement du côté `errors-only`.

---

## Dimensionnement

Officiellement, Sentry demande 4 vCPU / 16 Go RAM + 16 Go swap. Le profil
errors-only avec le réglage ci-dessous tourne sur **6 vCPU / 12 Go RAM + 8 Go de
swap / NVMe**. Descendre sous 8 Go de RAM n'est pas raisonnable : ClickHouse et
Kafka finiront par se faire tuer par l'OOM killer pendant les merges.

La somme des `limits` du compose vaut ~16,5 Go, dont 2 Go pour les deux
one-shot d'initialisation. Ce sont des plafonds anti-fuite,
pas des réservations : la consommation observée au repos est de 7 à 9 Go.

Les quatre leviers qui comptent, dans l'ordre :

| Levier | Variable | Gain |
|---|---|---|
| Profil errors-only | — | ~6 Go |
| Heap JVM Kafka plafonné | `KAFKA_HEAP_OPTS` | ~1 Go, et surtout évite l'OOM |
| Budget ClickHouse | `CLICKHOUSE_MEMORY_RATIO` × `CLICKHOUSE_MEM_LIMIT` | ~1,5 Go |
| Workers uwsgi et taskworker | `SENTRY_WEB_WORKERS`, `SENTRY_TASKWORKER_CONCURRENCY` | ~600 Mo |

Sans `KAFKA_HEAP_OPTS`, la JVM ignore la limite du conteneur et réserve 25 % de
la RAM de l'hôte. C'est la cause la plus fréquente d'OOM sur les instances
Sentry auto-hébergées.

Côté disque, `SENTRY_EVENT_RETENTION_DAYS=30` au lieu de 90 divise par trois le
volume ClickHouse et le bucket nodestore.

---

## Variables d'environnement

`.env.example` ne contient volontairement que le strict minimum. Toutes les
autres variables ont un défaut sain directement dans le compose (`${VAR:-…}`) :
ajoutez dans Coolify uniquement celles que vous voulez changer, elles prennent
effet au redéploiement suivant.

**Générées par Coolify** (leur simple présence dans le compose les déclenche,
ne rien saisir) : `SERVICE_PASSWORD_64_SENTRYSECRET` (clé de signature des
sessions et du CSRF, 64 caractères — la changer invalide toutes les sessions),
`SERVICE_PASSWORD_SENTRYADMIN` (mot de passe du compte admin) et
`SERVICE_URL_SENTRY` (URL complète avec schéma, publiée quand le domaine est
posé sur le service `nginx` ; sa jumelle `SERVICE_FQDN_SENTRY` est l'hôte nu).

**À renseigner** : `SENTRY_ADMIN_EMAIL` et `SENTRY_MAIL_HOST` — voir
`.env.example`.

**Optionnelles :**

| Variable | Défaut | Rôle |
|---|---|---|
| `SENTRY_EVENT_RETENTION_DAYS` | `30` | Rétention des événements — le poste d'économie disque n°1 (défaut upstream : 90) |
| `KAFKA_LOG_RETENTION_HOURS` | `3` | Durée de vie des messages Kafka (simple tampon ici) |
| `SENTRY_KAFKA_MEM_LIMIT` | `1536M` | Plafond mémoire du conteneur Kafka — **toujours ajuster `KAFKA_HEAP_OPTS` avec** (préfixe `SENTRY_` : cp-kafka mappe les env `KAFKA_*` en propriétés de broker) |
| `KAFKA_HEAP_OPTS` | `-Xmx768m -Xms768m` | Heap JVM explicite — sans lui, la JVM prend 25 % de la RAM de l'hôte |
| `CLICKHOUSE_MEM_LIMIT` | `2G` | Plafond mémoire du conteneur ClickHouse |
| `CLICKHOUSE_MEMORY_RATIO` | `0.6` | Part du plafond utilisable par le serveur ClickHouse |
| `REDIS_MAXMEMORY` | `384mb` | Plafond mémoire Valkey/Redis |
| `SENTRY_WEB_WORKERS` | `2` | Workers uwsgi (~300 Mo chacun) |
| `SENTRY_WEB_THREADS` | `4` | Threads par worker uwsgi |
| `SENTRY_TASKWORKER_CONCURRENCY` | `2` | Process du taskworker (~300 Mo chacun) |
| `SNUBA_UWSGI_PROCESSES` | `2` | Process uwsgi de l'API Snuba |
| `SNUBA_UWSGI_THREADS` | `2` | Threads uwsgi de l'API Snuba |
| `SENTRY_BIND` | `127.0.0.1:9000` | Port publié pour l'accès direct sans Traefik (loopback par défaut) |
| `SENTRY_ALLOW_REGISTRATION` | `false` | Ouverture des inscriptions |
| `SENTRY_CSRF_TRUSTED_ORIGINS` | *(vide)* | Origines CSRF supplémentaires, séparées par des virgules |
| `SENTRY_SMTP_HOST` | *(vide)* | Relais SMTP externe — le renseigner bypasse le conteneur exim interne |
| `SENTRY_SMTP_PORT` | `587` | Port du relais externe |
| `SENTRY_SMTP_USERNAME` | *(vide)* | Identifiant du relais externe |
| `SENTRY_SMTP_PASSWORD` | *(vide)* | Mot de passe du relais externe |
| `SENTRY_SMTP_FROM` | *(vide)* | Adresse expéditrice |
| `SENTRY_SMTP_USE_TLS` | `true` | STARTTLS vers le relais externe |
| `SENTRY_SMTP_USE_SSL` | `false` | SSL implicite vers le relais externe |
| `SENTRY_S3_ACCESS_KEY` / `SENTRY_S3_SECRET_KEY` | `sentry` / `sentry` | Credentials du stockage objet interne (SeaweedFS, jamais exposé) |
| `SENTRY_MAX_EXTERNAL_SOURCEMAP_SIZE` | `1M` | Taille max des sourcemaps externes (memcached `-I`) |
| `SENTRY_KAFKA_MAX_POLL_INTERVAL_MS` | `300000` | À augmenter si des consumers sont expulsés du groupe sous charge |
| `SENTRY_SA_IMAGE` … `VALKEY_SA_IMAGE` | tags GHCR `26.8.0` épinglés | Les 9 images de la stack — c'est par elles que passe une montée de version |

---

## Sauvegarde

`sentry-postgres` (métadonnées : projets, utilisateurs, règles d'alerte) est le
volume dont la perte fait le plus mal ; `sentry-clickhouse` (les événements) est
volumineux et régénérable au prix de l'historique. Les autres volumes sont
jetables.

```bash
docker compose run --rm -v /backup:/backup sentry-bootstrap \
  sentry export global /backup/sentry-$(date +%F).json
```

Voir aussi <https://develop.sentry.dev/self-hosted/backup/>.

---

## Licence

Sentry est distribué sous **FSL-1.1-ALv2** (Functional Source License) : usage
interne libre, y compris en entreprise, mais interdiction de revendre une
instance hébergée comme offre commerciale. Le passage sous Apache 2.0 intervient
deux ans après chaque release. Le contenu de ce dépôt (Dockerfile, overlays,
compose) est sous MIT ; il ne modifie pas la licence de Sentry.