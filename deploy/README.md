# Déploiement du backend Lapinou

> **Note d'architecture** : `deploy/` et `docker-compose.prod.yml` vivent à la racine du monorepo
> `lapinou/` (pas dans `backend/`), car ils ne contiennent aucun code applicatif. Cette racine a
> son propre dépôt Git, poussé sur `https://github.com/elienoel/lapinou-archi.git` (remote déjà
> configuré en local sous le nom `origin`) — pense à committer/pousser avant de t'en servir sur le
> serveur. `backend/` reste un dépôt séparé (`lapinou-backend`).

Aucun registre Docker (GHCR ou autre) n'est utilisé : les deux dépôts (`lapinou-archi` et
`lapinou-backend`) sont **privés**, donc le serveur clone directement le code source du backend et
build l'image Docker lui-même à chaque déploiement, plutôt que de tirer une image déjà construite.
Le serveur a donc besoin de ses propres identifiants Git pour cloner/pull **les deux** dépôts (clé
de déploiement SSH GitHub, ou URL HTTPS contenant un token) — sans ça, `setup-server.sh`/`deploy.sh`
échoueront sur le `git clone`/`pull`.

CI/CD : un `push` sur la branche `prod` du dépôt `lapinou-backend` déclenche
`backend/.github/workflows/deploy-prod.yml`, qui se connecte en SSH au serveur et exécute
`deploy/deploy.sh` (celui-ci pull les deux dépôts et rebuild l'image sur place).

## 1. Secrets/variables GitHub à configurer

Dans **Settings → Secrets and variables → Actions** du dépôt `lapinou-backend` :

| Type     | Nom               | Description                                              |
|----------|-------------------|-----------------------------------------------------------|
| Secret   | `SSH_HOST`        | IP ou domaine du serveur                                   |
| Secret   | `SSH_USER`        | Utilisateur SSH (doit pouvoir lancer `docker`)             |
| Secret   | `SSH_PRIVATE_KEY` | Clé privée SSH correspondante                              |
| Secret   | `SSH_PORT`        | Port SSH (optionnel, défaut 22)                             |
| Variable | `DEPLOY_PATH`     | Chemin du dossier déployé sur le serveur (défaut `/opt/lapinou`) |

## 2. Préparer le serveur (une seule fois)

Le serveur doit pouvoir cloner/pull **`lapinou-archi`** (racine, pour `docker-compose.prod.yml` +
`deploy/`) et **`lapinou-backend`** (pour le code source + `Dockerfile`) — les deux étant privés,
configure d'abord un accès Git sur le serveur (clé de déploiement SSH GitHub sur les deux dépôts,
ou remplace `--repo`/`--backend-repo` par des URLs HTTPS contenant un token).

Connecte-toi en SSH sur le serveur (Ubuntu/Debian) puis, une fois `setup-server.sh` récupéré sur le
serveur (copie manuelle, ou `curl` depuis `lapinou-archi` une fois le premier push fait) :

```bash
chmod +x setup-server.sh
./setup-server.sh \
  --domain api.lapinou.example \
  --email admin@lapinou.example
```

Le script va demander en entrée cachée (jamais en argument visible) :
- le mot de passe PostgreSQL,
- la `SECRET_KEY` Django (laisse vide pour en générer une automatiquement).

Il installe Docker, clone `lapinou-archi` (branche `prod`) dans `/opt/lapinou` et `lapinou-backend`
dans `/opt/lapinou/backend`, génère `.env` et `deploy/nginx.conf`, build l'image backend, obtient un
certificat Let's Encrypt via Certbot, puis démarre PostgreSQL + backend + Nginx + le renouvellement
automatique du certificat.

**Pré-requis avant de lancer ce script** : le DNS du domaine doit déjà pointer vers l'IP du serveur.

## 3. Déploiements suivants

Automatique à chaque push sur `prod` (le workflow appelle `deploy/deploy.sh` en SSH) : il pull les
deux dépôts et rebuild l'image backend sur le serveur.

Pour déployer manuellement depuis le serveur :

```bash
cd /opt/lapinou
./deploy/deploy.sh
```

## 4. Notes de sécurité

- `.env` et `deploy/nginx.conf` sont générés sur le serveur et ignorés par Git (jamais commités).
- Le renouvellement du certificat Let's Encrypt tourne en continu via le conteneur `certbot`
  (`docker-compose.prod.yml`).
- `CORS_ALLOW_ALL_ORIGINS` est actuellement à `True` dans `core/settings.py` (hérité du dev) :
  à restreindre si l'API ne doit être appelée que par l'app mobile officielle.
