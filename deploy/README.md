# Déploiement du backend Lapinou

> **Note d'architecture** : `deploy/` et `docker-compose.prod.yml` vivent à la racine du monorepo
> `lapinou/` (pas dans `backend/`), car ils ne contiennent aucun code applicatif — ils ne font que
> démarrer l'image déjà construite. Pour l'instant, seuls `backend/` et `mobile_app/` sont des
> dépôts Git poussés sur GitHub (`lapinou-backend`, `lapinou-mobile-app`) ; la racine `lapinou/`
> n'a pas encore son propre dépôt. **Tant que ce n'est pas fait, le `git clone`/`pull` fait par
> `setup-server.sh`/`deploy.sh` ne fonctionnera pas** : il faut soit créer un dépôt Git pour la
> racine `lapinou/` (et le pousser sur GitHub), soit copier `deploy/` et `docker-compose.prod.yml`
> sur le serveur par un autre moyen (scp/rsync) avant d'utiliser ces scripts.

CI/CD : un `push` sur la branche `prod` du dépôt `lapinou-backend` déclenche
`backend/.github/workflows/deploy-prod.yml`, qui construit l'image Docker, la pousse sur GHCR,
puis se connecte en SSH au serveur pour exécuter `deploy/deploy.sh`.

## 1. Secrets/variables GitHub à configurer

Dans **Settings → Secrets and variables → Actions** du dépôt `lapinou-backend` :

| Type     | Nom               | Description                                              |
|----------|-------------------|-----------------------------------------------------------|
| Secret   | `SSH_HOST`        | IP ou domaine du serveur                                   |
| Secret   | `SSH_USER`        | Utilisateur SSH (doit pouvoir lancer `docker`)             |
| Secret   | `SSH_PRIVATE_KEY` | Clé privée SSH correspondante                              |
| Secret   | `SSH_PORT`        | Port SSH (optionnel, défaut 22)                             |
| Variable | `DEPLOY_PATH`     | Chemin du dossier déployé sur le serveur (défaut `/opt/lapinou`) |

Aucun secret Docker/GHCR n'est nécessaire côté GitHub : le workflow s'authentifie avec le
`GITHUB_TOKEN` automatique.

## 2. Préparer le serveur (une seule fois)

Si le dépôt est **privé**, configure d'abord un accès Git sur le serveur (clé de déploiement SSH
GitHub, ou remplace `--repo` par une URL HTTPS contenant un token) : sans ça, le `git clone`/`pull`
échouera. `--repo` doit pointer vers le dépôt racine `lapinou/` (contenant `deploy/` et
`docker-compose.prod.yml`), pas vers `lapinou-backend` — voir la note d'architecture en haut de ce
fichier tant que ce dépôt n'existe pas.

Connecte-toi en SSH sur le serveur (Ubuntu/Debian) puis, une fois `setup-server.sh` récupéré sur le
serveur (copie manuelle, ou `curl` depuis le dépôt racine une fois qu'il existe sur GitHub) :

```bash
chmod +x setup-server.sh
./setup-server.sh \
  --domain api.lapinou.example \
  --email admin@lapinou.example \
  --ghcr-user elienoel
```

Le script va demander en entrée cachée (jamais en argument visible) :
- le mot de passe PostgreSQL,
- la `SECRET_KEY` Django (laisse vide pour en générer une automatiquement),
- un token GitHub (`read:packages`) si l'image GHCR est privée.

Il installe Docker, clone le dépôt (branche `prod`) dans `/opt/lapinou`, génère `.env` et
`deploy/nginx.conf`, obtient un certificat Let's Encrypt via Certbot, puis démarre
PostgreSQL + backend + Nginx + le renouvellement automatique du certificat.

**Pré-requis avant de lancer ce script** : au moins un push sur `prod` doit déjà avoir été fait
(pour que l'image `ghcr.io/.../lapinou-backend:latest` existe), et le DNS du domaine doit déjà
pointer vers l'IP du serveur.

## 3. Déploiements suivants

Automatique à chaque push sur `prod` (le workflow appelle `deploy/deploy.sh` en SSH).

Pour déployer manuellement une image précise depuis le serveur :

```bash
cd /opt/lapinou
./deploy/deploy.sh --image ghcr.io/elienoel/lapinou-backend:<tag>
```

## 4. Notes de sécurité

- `.env` et `deploy/nginx.conf` sont générés sur le serveur et ignorés par Git (jamais commités).
- Le renouvellement du certificat Let's Encrypt tourne en continu via le conteneur `certbot`
  (`docker-compose.prod.yml`).
- `CORS_ALLOW_ALL_ORIGINS` est actuellement à `True` dans `core/settings.py` (hérité du dev) :
  à restreindre si l'API ne doit être appelée que par l'app mobile officielle.
