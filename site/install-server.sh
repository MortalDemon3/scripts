#!/usr/bin/env bash
# Installe le serveur get.andries.icu dans un LXC Debian 12/13 vierge.
#
# Usage (dans le LXC, en root) :
#   curl -fsSL https://raw.githubusercontent.com/MortalDemon3/scripts/main/site/install-server.sh | bash
#
# Variables optionnelles :
#   REPO_URL  (défaut : https://github.com/MortalDemon3/scripts.git)
#   BRANCH    (défaut : main)
#   BASE_URL  (défaut : https://get.andries.icu)
set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/MortalDemon3/scripts.git}"
BRANCH="${BRANCH:-main}"
BASE_URL="${BASE_URL:-https://get.andries.icu}"
REPO_DIR=/opt/scripts
OUT_DIR=/var/lib/get-site
SVC_USER=getsync

ok()   { printf '\e[32m[✓]\e[0m %s\n' "$*"; }
info() { printf '\e[34m[i]\e[0m %s\n' "$*"; }
die()  { printf '\e[31m[✗]\e[0m %s\n' "$*" >&2; exit 1; }

main() {
  [ "$(id -u)" -eq 0 ] || die "À lancer en root."
  command -v apt-get >/dev/null || die "Debian/Ubuntu requis."

  info "Installation des paquets (nginx, git)..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq nginx git ca-certificates >/dev/null
  ok "Paquets installés."

  # Utilisateur système dédié à la synchro (pas de shell, pas de login)
  if ! id "$SVC_USER" >/dev/null 2>&1; then
    useradd --system --home-dir /nonexistent --shell /usr/sbin/nologin "$SVC_USER"
    ok "Utilisateur $SVC_USER créé."
  fi

  # Clone (ou reclone propre) du repo
  if [ -d "$REPO_DIR/.git" ]; then
    info "Repo déjà présent, mise à jour..."
    chown -R "$SVC_USER:$SVC_USER" "$REPO_DIR"
    runuser -u "$SVC_USER" -- git -C "$REPO_DIR" fetch --quiet origin "$BRANCH"
    runuser -u "$SVC_USER" -- git -C "$REPO_DIR" reset --quiet --hard "origin/$BRANCH"
  else
    rm -rf "$REPO_DIR"
    install -d -o "$SVC_USER" -g "$SVC_USER" -m 755 "$REPO_DIR"
    runuser -u "$SVC_USER" -- git clone --quiet --branch "$BRANCH" "$REPO_URL" "$REPO_DIR"
  fi
  chmod 755 "$REPO_DIR"
  ok "Repo cloné dans $REPO_DIR."

  install -d -o "$SVC_USER" -g "$SVC_USER" -m 755 "$OUT_DIR"
  runuser -u "$SVC_USER" -- bash "$REPO_DIR/site/build-index.sh" "$REPO_DIR" "$OUT_DIR" "$BASE_URL"

  # nginx
  install -m 644 "$REPO_DIR/site/nginx-get.conf" /etc/nginx/sites-available/get
  ln -sf /etc/nginx/sites-available/get /etc/nginx/sites-enabled/get
  rm -f /etc/nginx/sites-enabled/default
  nginx -t -q || die "Configuration nginx invalide."
  systemctl enable --now nginx >/dev/null 2>&1
  systemctl reload nginx
  ok "nginx configuré."

  # Timer de synchronisation
  install -m 644 "$REPO_DIR/site/get-sync.service" /etc/systemd/system/get-sync.service
  install -m 644 "$REPO_DIR/site/get-sync.timer"   /etc/systemd/system/get-sync.timer
  if [ "$BRANCH" != main ] || [ "$BASE_URL" != https://get.andries.icu ]; then
    install -d /etc/systemd/system/get-sync.service.d
    printf '[Service]\nEnvironment=BRANCH=%s\nEnvironment=BASE_URL=%s\n' "$BRANCH" "$BASE_URL" \
      > /etc/systemd/system/get-sync.service.d/override.conf
  fi
  systemctl daemon-reload
  systemctl enable --now get-sync.timer >/dev/null 2>&1
  systemctl start get-sync.service
  ok "Synchronisation automatique active (toutes les 2 min)."

  echo
  ok "Terminé. Tests locaux :"
  echo "    curl -s http://127.0.0.1/            # index texte"
  echo "    curl -s http://127.0.0.1/pve/first-start | head"
  echo "    curl -s http://127.0.0.1/health"
}

main "$@"
