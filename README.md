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
| `.env.example` | Toutes les variables, commentées : domaine, rétention, plafonds mémoire, parallélisme, SMTP. | Séparé pour être collé tel quel dans l'onglet Environment Variables de Coolify. |
| `overlays/sentry.conf.append.py` | Configuration Sentry pilotée par l'environnement : `system.url-prefix`, CSRF, TLS derrière proxy, nodestore S3, workers uwsgi, SMTP. Concaténé à `sentry.conf.example.py` au build. | Fichier Python à part entière (~110 lignes) : l'inliner dans le Dockerfile le rendrait illisible. C'est le fichier que vous éditerez le plus souvent. |
| `overlays/bootstrap.sh` | Remplace `install.sh` : crée le bucket S3 avec sa politique de rétention, joue les migrations Postgres, crée les topics Kafka et le compte admin. Idempotent. | Exécuté au runtime par le service `sentry-bootstrap`, pas au build. |
| `.github/workflows/build-images.yml` | Construit et publie les 9 images sur GHCR. Valide aussi la syntaxe du compose. | — |

### Le reste

| Fichier | Rôle |
|---|---|
| `README.md` | Ce document. |
| `sentry.yaml` | Le template pour la PR `coollabsio/coolify` : le même compose, avec l'en-tête `# documentation:` / `# slogan:` / `# port:` et sans port publié. Généré depuis `docker-compose.yaml`. |
| `CLAUDE.md` | Guide de travail dans le dépôt pour Claude Code : architecture, commandes, points de vigilance. |
| `.gitignore` | `.env` et fichiers temporaires. |

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
  - SERVICE_FQDN_SENTRY_80
```

Le `80` est le port **interne** du conteneur nginx, pas le port public — le
public reste 80/443 chez Traefik. Cette variable magique fait deux choses :
elle fait apparaître le champ *Domains* sur ce service, et elle publie
`${SERVICE_FQDN_SENTRY}` (URL complète) et `${SERVICE_URL_SENTRY}` (sans le
schéma) pour toute la stack.

Les conteneurs Sentry consomment la première via `SENTRY_SYSTEM_URL_PREFIX`,
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

La somme des `limits` du compose vaut ~16 Go, dont 1,5 Go pour les deux
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

## Déploiement sur Coolify

1. **Publier les images** — pousser ce dépôt sur `main`, le workflow construit
   et publie les 9 images sur `ghcr.io/softartisan-inc`. Rendre les packages
   publics, ou déclarer un registre privé dans Coolify.

2. **Créer la ressource** — *New Resource* → *Docker Compose*, coller le contenu
   de `docker-compose.yaml`.

3. **Variables** — coller `.env.example` dans l'onglet Environment Variables.
   Renseigner au minimum `SENTRY_ADMIN_EMAIL` et `SENTRY_MAIL_HOST`. Coolify
   génère lui-même `SERVICE_PASSWORD_SENTRYSECRET`,
   `SERVICE_PASSWORD_SENTRYADMIN` et `SERVICE_FQDN_SENTRY`.

4. **Domaine** — le renseigner sur le service `nginx`, comme pour n'importe
   quelle ressource Coolify. Voir la section « Domaine et port » plus haut.

5. **Déployer.** Le premier démarrage prend 10 à 20 minutes : migrations
   ClickHouse et Postgres, création des topics Kafka. Suivre
   `sentry-bootstrap` dans les logs.

6. **Se connecter** avec `SENTRY_ADMIN_EMAIL` et le mot de passe généré.

### Si Coolify refuse le fichier

Coolify réécrit le compose avant de le passer à Docker. Si son parseur bute sur
les ancres YAML, aplatir le fichier avant de le coller :

```bash
docker compose -f docker-compose.yaml config > docker-compose.flat.yaml
```

---

## Mise à jour

Les migrations Sentry ne supportent pas les sauts de version : il faut passer
par chaque release intermédiaire, exactement comme upstream.

```bash
# 1. Relancer le workflow avec la nouvelle version
gh workflow run build-images.yml -f self_hosted_version=26.9.0

# 2. Mettre à jour les tags d'images dans les variables Coolify, puis redéployer
```

Le service `sentry-bootstrap` rejoue les migrations à chaque démarrage : rien de
plus à faire. **Sauvegarder les volumes `sentry-postgres` et `sentry-clickhouse`
avant toute montée de version.**

---

## Contribution à Coolify

Le template prêt à soumettre est `sentry.yaml`, à la racine de ce dépôt.
Éligibilité remplie : la doc de contribution
(<https://coolify.io/docs/contribute/service>) exige 1 000 étoiles GitHub pour
le service — Sentry en a ~40 000 — et aucun template Sentry n'existe dans le
catalogue (seulement les alternatives GlitchTip et Bugsink).

La contribution demande **deux pull requests**, la PR de docs étant exigée
avant le merge du template.

**1. Template** — sur `coollabsio/coolify`, à partir de la branche `next` :

```bash
git clone git@github.com:softartisan-inc/coolify.git
cd coolify
git checkout -b feat/add-sentry-service-template origin/next
cp ../sentry-coolify/sentry.yaml templates/compose/sentry.yaml
# logo (absent du catalogue) : fichier public/svgs/sentry.svg, référencé
# `# logo: svgs/sentry.svg` dans l'en-tête du template
git add templates/compose/sentry.yaml public/svgs/sentry.svg
git commit -m "feat(templates): add Sentry self-hosted service template"
```

`templates/service-templates.json` est généré automatiquement — ne pas
l'éditer à la main.

**2. Docs** — sur `coollabsio/coolify-docs` : créer
`content/docs/services/sentry.mdx` (frontmatter `title`, `description`,
`category`) et le logo sous `public/images/services/`, puis lier cette PR
depuis la PR template. Les listings se régénèrent avec
`bun run generate:services`.

Avant de soumettre : tester le template depuis une ressource **Docker Compose
Empty** d'une instance Coolify réelle (exigence de la doc), les 9 images GHCR
étant déjà publiques.

Deux points à anticiper dans la discussion avec les mainteneurs :

- **Les images pointent vers `ghcr.io/softartisan-inc`.** C'est inévitable —
  la stack officielle a besoin de fichiers montés. Le Dockerfile qui les produit
  est public et reproductible, mais attendez-vous à ce que la question soit
  posée. Une alternative acceptable serait de proposer à `getsentry/self-hosted`
  de publier ces images « config-baked » en amont.
- **30 services, c'est de loin le plus gros template du catalogue.** Mentionner
  explicitement les prérequis matériel dans la description de la PR évitera un
  flot d'issues « Sentry ne démarre pas » venant de VPS à 2 Go.

---

## Commits sans co-auteur

Par défaut, Claude Code ajoute deux lignes à chaque commit :

```
🤖 Generated with [Claude Code](https://claude.com/claude-code)
Co-Authored-By: Claude <noreply@anthropic.com>
```

Le fichier `.claude/settings.json` de ce dépôt les désactive. **Attention à la
clé** : `includeCoAuthoredBy` est déprécié depuis Claude Code v2.0.62, remplacé
par un bloc `attribution`. Le fichier contient les deux, pour couvrir les
versions anciennes et récentes :

```json
{
  "attribution": { "commits": false, "pullRequests": false },
  "includeCoAuthoredBy": false
}
```

Ce fichier est versionné volontairement : `.claude/settings.json` est le niveau
« projet », partagé avec l'équipe, à la différence de `~/.claude/settings.json`
(personnel, tous projets) et de `.claude/settings.local.json` (personnel,
non versionné).

### Le filet de sécurité

Plusieurs bugs ouverts montrent que le réglage n'est pas toujours respecté quand
Claude construit le message de commit à la main via la commande `git`. Ce dépôt
ne fournit volontairement aucun hook git : le filet est une vérification
manuelle avant de pousser :

```bash
git log --format='%B' origin/main..HEAD | grep -i 'co-authored-by\|Generated with' \
  && echo "A NETTOYER"
```

Nettoyage si un commit est déjà passé :

```bash
git rebase -i origin/main   # reword, ou :
git filter-branch -f --msg-filter \
  "grep -viE '^(Co-Authored-By: Claude|.*Generated with)'" origin/main..HEAD
```

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