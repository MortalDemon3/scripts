# scripts

Mes scripts d'administration (Proxmox, Debian, Docker...), exécutables sur n'importe quelle machine avec une seule commande.

```bash
curl -fsSL https://get.andries.icu/<script> | bash
```

Liste des scripts : `curl https://get.andries.icu` ou [get.andries.icu](https://get.andries.icu) dans un navigateur.

## Scripts disponibles

| Script | Description | Commande |
|---|---|---|
| `pve/first-start` | Post-install Proxmox VE 8/9 : dépôts no-subscription, popup, MAJ, outils | `curl -fsSL https://get.andries.icu/pve/first-start \| bash` |

### Passer des options

```bash
curl -fsSL https://get.andries.icu/pve/first-start | bash -s -- --yes
```

### Secours (si get.andries.icu est hors ligne)

Le même script directement depuis GitHub :

```bash
curl -fsSL https://raw.githubusercontent.com/MortalDemon3/scripts/main/pve/first-start.sh | bash
```

### Version figée

Pour exécuter exactement une version précise (tag ou commit) :

```bash
curl -fsSL https://raw.githubusercontent.com/MortalDemon3/scripts/v1.0.0/pve/first-start.sh | bash
```

## Ajouter un script

1. Copier `templates/script-template.sh` dans le bon dossier (`pve/`, `debian/`, `docker/`...).
2. Remplir la ligne `# DESC:` : c'est elle qui apparaît sur le site.
3. `git add`, `git commit`, `git push` : le site se met à jour tout seul en moins de 2 minutes.

Règles :
- Script **autonome** (pas de `source` d'un autre fichier).
- Tout le code dans `main()`, appelé à la dernière ligne.
- `set -euo pipefail` en tête.
- **Aucun secret** (mot de passe, token, IP privée sensible) : le repo est public.

## Fonctionnement du site

```
git push ──> GitHub ──(git fetch toutes les 2 min)──> LXC "get" (nginx) ──> NPM ──> Cloudflare ──> curl
```

- `site/install-server.sh` : installe le serveur dans un LXC Debian vierge.
- `site/sync.sh` + `get-sync.timer` : synchronisation avec GitHub.
- `site/build-index.sh` : génère la page d'accueil depuis les lignes `# DESC:`.
- `site/nginx-get.conf` : `/pve/first-start` sert `pve/first-start.sh` en texte brut.

## Sécurité

`curl | bash` exécute du code sans le relire. Avant de lancer un script, on peut le lire :

```bash
curl -fsSL https://get.andries.icu/pve/first-start | less
```
