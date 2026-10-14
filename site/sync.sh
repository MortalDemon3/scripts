#!/usr/bin/env bash
# Synchronise le site avec GitHub puis régénère l'index.
# Lancé par le timer systemd get-sync.timer.
set -euo pipefail

REPO_DIR="${REPO_DIR:-/opt/scripts}"
OUT_DIR="${OUT_DIR:-/var/lib/get-site}"
BRANCH="${BRANCH:-main}"
BASE_URL="${BASE_URL:-https://get.andries.icu}"

main() {
  git -C "$REPO_DIR" fetch --quiet origin "$BRANCH"

  local local_rev remote_rev
  local_rev="$(git -C "$REPO_DIR" rev-parse HEAD)"
  remote_rev="$(git -C "$REPO_DIR" rev-parse "origin/$BRANCH")"

  if [ "$local_rev" != "$remote_rev" ] || [ ! -f "$OUT_DIR/index.txt" ]; then
    # reset --hard : le serveur est un miroir, aucune modif locale ne doit y vivre
    git -C "$REPO_DIR" reset --quiet --hard "origin/$BRANCH"
    bash "$REPO_DIR/site/build-index.sh" "$REPO_DIR" "$OUT_DIR" "$BASE_URL"
    echo "Mis à jour : ${local_rev:0:7} -> ${remote_rev:0:7}"
  fi
}

main "$@"
