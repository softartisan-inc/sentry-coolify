# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

> Le dépôt est rédigé en français (README, commentaires, messages de log). Conserver
> cette langue dans toute modification de documentation ou de commentaire.

## Ce qu'est ce dépôt

Un packaging de `getsentry/self-hosted` **26.8.0** déployable sous Coolify. Il n'y a
pas de code applicatif : uniquement une chaîne de build d'images et un fichier
compose. Le README explique le *pourquoi* en détail ; ce fichier documente le
*comment travailler dedans*.

Trois contraintes structurent tout le dépôt, et expliquent des choix qui paraîtraient
sinon arbitraires :

1. **Coolify ne déploie qu'un seul fichier compose.** Aucun bind mount de fichier
   voisin n'est possible. Toute la configuration qu'upstream monte depuis l'hôte
   (`sentry.conf.py`, `nginx.conf`, `clickhouse/config.xml`, `relay/config.yml`,
   `symbolicator/config.yml`, `taskbroker/config.yml`, `redis.conf`) est donc
   **bakée dans 9 images publiées sur GHCR**.
2. **Pas de `docker compose build` sur l'hôte.** Les images sont construites et
   publiées par GitHub Actions, puis référencées par tag épinglé.
3. **Pas d'`install.sh`.** Deux services one-shot idempotents (`snuba-bootstrap`,
   `sentry-bootstrap`) rejouent son travail au runtime, à chaque démarrage.

Toute modification doit préserver ces trois invariants. En particulier : **ne jamais
introduire de `build:`, de `volumes:` pointant vers un chemin hôte, ni de
`pull_policy: never`** dans le compose.

## Architecture

### La chaîne : overlays → Dockerfile → GHCR → compose

```
overlays/*.py|.sh ─┐
                   ├─> Dockerfile (stage `upstream`) ─> 9 stages ─> ghcr.io/softartisan-inc/*-sa:VERSION
release upstream ──┘                                                              │
   (téléchargée par curl,                                                          v
    tag SELF_HOSTED_VERSION)                              docker-compose.yaml (${*_SA_IMAGE})
```

Le stage `upstream` (`alpine`) télécharge la release GitHub épinglée, applique les
overlays sur les fichiers `*.example.*`, et sert de source de `COPY --from=upstream`
à tous les stages suivants. **C'est le seul endroit qui connaît la structure du dépôt
upstream** — un changement de nom de fichier en amont se corrige uniquement là.

Les 9 cibles publiées, plus le stage intermédiaire :

| Stage | Image publiée | Ce que le stage ajoute |
|---|---|---|
| `upstream` | *(non publié)* | Release upstream + overlays appliqués |
| `sentry` | `sentry-sa` | `sentry_nodestore_s3` (pip), `/etc/sentry/`, `sa-bootstrap`, entrypoint avec support CA |
| `sentry-cleanup` | `sentry-cleanup-sa` | Dérive de `sentry` + `cron` |
| `snuba` | `snuba-sa` | `api_healthcheck.py` |
| `clickhouse` | `clickhouse-sa` | `config.d/sentry.xml`, `users.d/default-password.xml` |
| `nginx` | `nginx-sa` | `nginx.conf` upstream |
| `relay` | `relay-sa` | `config.yml` + busybox statique + entrypoint qui génère `credentials.json` au premier boot |
| `symbolicator` | `symbolicator-sa` | `config.yml` |
| `taskbroker` | `taskbroker-sa` | `config.yml` |
| `valkey` | `valkey-sa` | `redis.conf` upstream (`maxmemory-policy volatile-lru`) |

### Où éditer quoi

- **Comportement de Sentry (URL, CSRF, nodestore, uwsgi, SMTP, inscriptions)** →
  `overlays/sentry.conf.append.py`. C'est le fichier le plus souvent modifié. Il est
  **concaténé** à `sentry.conf.example.py` au build : il s'exécute donc dans un
  namespace où `SENTRY_OPTIONS`, `SENTRY_FEATURES`, `SENTRY_WEB_OPTIONS` existent
  déjà. Toujours *muter* ces dicts (`.update()`, affectation de clé), jamais les
  réassigner. Tout y est piloté par variable d'environnement via les helpers
  `_envstr` / `_envint` / `_envbool` — une image unique doit servir tous les
  environnements, donc **aucune valeur d'environnement en dur**.
- **Initialisation base de données / bucket / admin** → `overlays/bootstrap.sh`
  (`sa-bootstrap` dans l'image). Doit rester idempotent : il est rejoué à chaque
  démarrage de la stack.
- **Ajout/retrait de service, mémoire, dépendances** → `docker-compose.yaml`.
- **Config triviale (5–20 lignes)** → heredoc inline dans le `Dockerfile`
  (entrypoints Sentry et Relay, overlay `config.yml`). Choix assumé : ne pas créer
  de fichier pour ce qui ne s'édite jamais.

### Le compose

30 services au sens de `docker compose config --services` : 28 services pérennes
plus les deux one-shot `snuba-bootstrap` / `sentry-bootstrap` (convention reprise
dans les en-têtes du compose et le README). Fortement factorisé par ancres YAML —
**c'est la partie fragile du fichier** :

- `*restart`, `*healthy`, `*started`, `*bootstrapped`, `*hc`, `*hc-file`
- `&sentry` / `&snuba` : blocs de base (image, `depends_on`, `environment`, volumes)
  fusionnés dans chaque service dérivé
- `&lim-xs` … `&lim-xl` : plafonds mémoire (128M / 384M / 512M / 768M / 1G)

Un service typique tient donc en deux lignes : `<<: [*sentry, *lim-s]` plus sa
`command`. Modifier une ancre affecte tous ses consommateurs — vérifier avec
`docker compose config` avant de conclure.

Ordre de démarrage : infrastructure (`postgres` → `pgbouncer`, `kafka`,
`clickhouse`, `redis`, `seaweedfs`) → `snuba-bootstrap` → `sentry-bootstrap`
(`service_completed_successfully`) → services applicatifs → `relay` → `nginx`.

Le domaine passe par la variable magique Coolify `SERVICE_FQDN_SENTRY_80` sur le
service `nginx` ; elle publie `${SERVICE_FQDN_SENTRY}`, consommée comme
`SENTRY_SYSTEM_URL_PREFIX` par toute la stack. **Un changement de domaine exige un
redéploiement**, pas un restart : Sentry lit l'URL au démarrage du process.

### Deux artefacts compose, pas un

- `docker-compose.yaml` — usage interne. Publie un port (`SENTRY_BIND`, loopback par
  défaut), et rend les secrets obligatoires (`${SERVICE_PASSWORD_SENTRYSECRET:?}`).
- `sentry.yaml` — template destiné à une PR sur `coollabsio/coolify`. Même contenu,
  plus l'en-tête de métadonnées (`# documentation:`, `# slogan:`, `# category:`,
  `# port: 80`), sans bloc `ports:` et sans les `:?` bloquants.

**Ils doivent rester synchronisés.** Après toute modification de
`docker-compose.yaml`, reporter le changement dans `sentry.yaml` et vérifier que le
diff se limite aux différences attendues :

```bash
diff docker-compose.yaml sentry.yaml
```

Différences attendues, et rien d'autre (~65 lignes de diff) : l'en-tête
(métadonnées Coolify vs commentaire interne), la suppression des `:?` sur
`SERVICE_PASSWORD_SENTRYSECRET`, la suppression du défaut `http://localhost:9000`
sur `SERVICE_FQDN_SENTRY`, le défaut `admin@example.com` sur `SENTRY_ADMIN_EMAIL`,
le défaut vide (`:-`) retiré sur `SERVICE_PASSWORD_SENTRYADMIN`, et l'absence du
bloc `ports:` de `nginx`.


## Commandes

Il n'y a ni test unitaire ni linter dans ce dépôt. La seule validation est celle du
compose, telle que la CI l'exécute :

```bash
cp .env.example .env
echo "SERVICE_PASSWORD_SENTRYSECRET=ci-placeholder" >> .env
docker compose config --quiet          # syntaxe + résolution des ancres
docker compose config --services | wc -l   # doit donner 30
docker compose -f sentry.yaml config --quiet   # le template (workflow validate-compose)
```

Construire une cible localement :

```bash
docker buildx build --target sentry \
  -t ghcr.io/softartisan-inc/sentry-sa:26.8.0 .
```

Publier les 9 images / changer de version upstream sans toucher au code :

```bash
gh workflow run build-images.yml -f self_hosted_version=26.9.0
```

Aplatir le compose si le parseur Coolify bute sur les ancres YAML :

```bash
docker compose -f docker-compose.yaml config > docker-compose.flat.yaml
```

Attention : l'aplati rend `- SERVICE_FQDN_SENTRY_80` (forme liste) comme
`SERVICE_FQDN_SENTRY_80: null` — si le champ Domains n'apparaît pas sur `nginx`
sous Coolify avec ce fichier, rétablir la forme liste à la main.

Créer un compte admin a posteriori, ou exporter les données :

```bash
docker compose run --rm sentry-bootstrap sentry createuser
docker compose run --rm -v /backup:/backup sentry-bootstrap \
  sentry export global /backup/sentry-$(date +%F).json
```

## Points de vigilance

- **Une montée de version se fait release par release.** Les migrations Sentry ne
  supportent pas les sauts. Un bump touche : `ARG SELF_HOSTED_VERSION` et les `ARG
  *_IMAGE` du Dockerfile, `DEFAULT_VERSION` et le `default:` du workflow, les neuf
  `*_SA_IMAGE` du tableau « Variables d'environnement » du README (elles ne sont
  plus dans `.env.example`, réduit au strict minimum — les surcharges se font
  par variable Coolify), les valeurs par défaut `:-ghcr.io/...` du compose
  **et** de `sentry.yaml`, et les mentions de version dans les en-têtes. Sauvegarder
  `sentry-postgres` et `sentry-clickhouse` avant.
- **`KAFKA_HEAP_OPTS` doit toujours accompagner `KAFKA_MEM_LIMIT`.** Sans plafond
  explicite, la JVM ignore la limite du conteneur et réserve 25 % de la RAM hôte :
  cause n°1 d'OOM sur les instances Sentry auto-hébergées.
- **Images amd64 uniquement.** Les images amont Sentry ne sont pas publiées en
  arm64 ; le workflow force `platforms: linux/amd64`.
- **Deux images amont ont des particularités de build** (découvertes au premier
  build CI, à revérifier à chaque montée de version) : `relay` est distroless
  (User 65532, ni shell ni coreutils) — son stage n'a aucun `RUN` et embarque
  busybox statique (`/busybox/sh`) pour l'entrypoint ; `sentry` est gérée par
  uv (Python système verrouillé PEP 668) — installer les paquets via `uv pip
  install` avec `VIRTUAL_ENV=/.venv` exporté (`uv pip` ignore
  `UV_PROJECT_ENVIRONMENT`), et ne jamais vérifier par un import réel au build :
  importer `sentry_nodestore_s3` lit les settings Django à l'import →
  `find_spec` uniquement.
- **Les `deploy.resources.limits` sont des plafonds anti-fuite, pas des
  réservations.** Leur somme (~16 Go, dont 1,5 Go pour les deux one-shot d'init)
  dépasse volontairement la RAM cible (12 Go).
- **Sortie du profil errors-only.** Réintroduire tracing / metrics / replays /
  profiling / crons / uptime demande ~29 services de plus et environ le double de
  RAM. Ne pas ajouter un service isolé de ces familles sans réintroduire ses
  consumers Snuba et ses topics Kafka.
- **Commits sans lignes d'attribution.** Politique du dépôt : n'ajouter
  **aucune** ligne `Co-Authored-By` ni `Generated with [Claude Code]` aux
  commits et PR (détaillée dans `NOTES.md`, non versionné). Deux verrous : cette
  consigne et le bloc `attribution` de `.claude/settings.json`. Aucun hook git,
  par choix assumé — ne pas en recréer. L'identité de commit est portée par le
  `git config` local : la vérifier avec `git var GIT_AUTHOR_IDENT` avant de
  committer.
- **`NOTES.md` (non versionné) porte les procédures internes** retirées du
  README public : déploiement sur Coolify, mise à jour, contribution à Coolify
  (template + PR docs), politique de commits. Ce fichier n'existe que
  localement — un clone neuf ne l'a pas. Ne pas réintroduire ces sections dans
  le README.
