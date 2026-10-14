#!/usr/bin/env bash
# DESC: Post-installation Proxmox VE 8/9 (dépôts no-subscription, popup, MAJ, outils)
#
# Usage :
#   curl -fsSL https://get.andries.icu/pve/first-start | bash
#   curl -fsSL https://get.andries.icu/pve/first-start | bash -s -- --yes
#
# Options :
#   -y, --yes           Non interactif : applique les choix par défaut
#       --skip-upgrade  Ne fait pas la mise à jour complète (dist-upgrade)
#   -h, --help          Affiche l'aide
#
# Le script est idempotent : on peut le relancer sans risque.
set -euo pipefail

# ---------------------------------------------------------------- Affichage
if [ -t 1 ]; then
  C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'; C_BLUE=$'\e[34m'
  C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_RED=$'\e[31m'
else
  C_RESET=''; C_BOLD=''; C_BLUE=''; C_GREEN=''; C_YELLOW=''; C_RED=''
fi
info() { printf '%s[i]%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
ok()   { printf '%s[✓]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()  { printf '%s[✗]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }
step() { printf '\n%s==> %s%s\n' "$C_BOLD" "$*" "$C_RESET"; }

# ---------------------------------------------------------------- Variables
ASSUME_YES=0
SKIP_UPGRADE=0
SRC_DIR=/etc/apt/sources.list.d
BACKUP_DIR="/root/pve-first-start-backup-$(date +%Y%m%d-%H%M%S)"
CODENAME=""
PVE_MAJOR=""

usage() {
  cat <<'EOF'
pve/first-start — Post-installation Proxmox VE 8/9

Usage :
  curl -fsSL https://get.andries.icu/pve/first-start | bash
  curl -fsSL https://get.andries.icu/pve/first-start | bash -s -- [options]

Options :
  -y, --yes           Non interactif : applique les choix par défaut
      --skip-upgrade  Ne fait pas la mise à jour complète (dist-upgrade)
  -h, --help          Affiche cette aide
EOF
}

# ask "Question ?" [y|n]  -> 0 = oui, 1 = non
# Lit depuis /dev/tty car stdin est occupé par le script (curl | bash).
ask() {
  local q="$1" def="${2:-y}" ans="" prompt
  if [ "$ASSUME_YES" -eq 1 ]; then
    [ "$def" = y ] && return 0 || return 1
  fi
  if [ "$def" = y ]; then prompt="[O/n]"; else prompt="[o/N]"; fi
  read -r -p "$q $prompt " ans < /dev/tty 2>/dev/null || ans=""
  ans="${ans:-$def}"
  case "${ans,,}" in
    o|oui|y|yes) return 0 ;;
    *)           return 1 ;;
  esac
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      -y|--yes)       ASSUME_YES=1 ;;
      --skip-upgrade) SKIP_UPGRADE=1 ;;
      -h|--help)      usage; exit 0 ;;
      *)              die "Option inconnue : $1 (voir --help)" ;;
    esac
    shift
  done
}

# ---------------------------------------------------------------- Vérifications
preflight() {
  [ "$(id -u)" -eq 0 ] || die "À lancer en root."
  command -v pveversion >/dev/null 2>&1 || die "Proxmox VE non détecté (pveversion introuvable)."
  # shellcheck source=/dev/null
  . /etc/os-release
  CODENAME="${VERSION_CODENAME:-}"
  case "$CODENAME" in
    bookworm) PVE_MAJOR=8 ;;
    trixie)   PVE_MAJOR=9 ;;
    *) die "Version non supportée (Debian '$CODENAME'). Supporté : PVE 8 (bookworm) et PVE 9 (trixie)." ;;
  esac
  info "Détecté : $(pveversion | head -n1) — Debian $CODENAME"
}

# ---------------------------------------------------------------- Dépôts
# Désactive un fichier de dépôt, au format .list ou .sources (deb822)
disable_repo_file() {
  local f="$1"
  case "$f" in
    *.list)
      sed -i -E 's/^([[:space:]]*)deb/\1# deb/' "$f"
      ;;
    *.sources)
      if grep -qi '^Enabled:' "$f"; then
        sed -i -E 's/^Enabled:.*/Enabled: no/I' "$f"
      else
        sed -i '/^Types:/a Enabled: no' "$f"
      fi
      ;;
  esac
}

setup_repos() {
  step "Dépôts APT"

  mkdir -p "$BACKUP_DIR"
  cp -a /etc/apt/sources.list "$BACKUP_DIR/" 2>/dev/null || true
  cp -a "$SRC_DIR" "$BACKUP_DIR/" 2>/dev/null || true
  ok "Sauvegarde des dépôts : $BACKUP_DIR"

  local f
  # 1. Dépôt enterprise PVE -> désactivé
  for f in "$SRC_DIR/pve-enterprise.list" "$SRC_DIR/pve-enterprise.sources"; do
    if [ -f "$f" ]; then
      disable_repo_file "$f"
      ok "Désactivé : $(basename "$f")"
    fi
  done

  # 2. Dépôt no-subscription PVE -> ajouté (si absent)
  local target
  if [ "$PVE_MAJOR" -eq 8 ]; then
    target="$SRC_DIR/pve-no-subscription.list"
  else
    target="$SRC_DIR/proxmox.sources"
  fi
  if grep -rqs --exclude="$(basename "$target")" 'pve-no-subscription' /etc/apt/sources.list "$SRC_DIR"; then
    info "Dépôt pve-no-subscription déjà présent ailleurs, rien à ajouter."
  elif [ "$PVE_MAJOR" -eq 8 ]; then
    echo "deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription" > "$target"
    ok "Ajouté : $(basename "$target")"
  else
    cat > "$target" <<EOF
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: $CODENAME
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
    ok "Ajouté : $(basename "$target")"
  fi

  # 3. Ceph enterprise -> no-subscription
  for f in "$SRC_DIR/ceph.list" "$SRC_DIR/ceph.sources"; do
    if [ -f "$f" ] && grep -q 'enterprise\.proxmox\.com' "$f"; then
      sed -i -E \
        -e 's#https?://enterprise\.proxmox\.com#http://download.proxmox.com#' \
        -e 's#(^|[[:space:]])enterprise([[:space:]]*)$#\1no-subscription\2#' "$f"
      ok "Ceph basculé en no-subscription : $(basename "$f")"
    fi
  done

  info "apt-get update..."
  apt-get update -qq || die "apt-get update a échoué. Restaure avec : cp -a $BACKUP_DIR/* /etc/apt/"
  ok "Dépôts OK."
}

# ---------------------------------------------------------------- Popup abonnement
remove_nag() {
  step "Popup « No valid subscription »"
  if ! ask "Supprimer le popup d'abonnement de l'interface web ?" y; then
    info "Ignoré."
    return 0
  fi
  # Hook APT : réapplique le patch à chaque mise à jour de proxmox-widget-toolkit
  cat > /etc/apt/apt.conf.d/no-nag-script <<'EOF'
DPkg::Post-Invoke { "dpkg -V proxmox-widget-toolkit | grep -q '/proxmoxlib\.js$'; if [ $? -eq 1 ]; then { echo 'Suppression du popup abonnement...'; sed -i '/.*data\.status.*{/{s/\!//;s/active/NoMoreNagging/}' /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js; }; fi"; };
EOF
  if apt-get install --reinstall -y -qq proxmox-widget-toolkit >/dev/null 2>&1; then
    ok "Popup supprimé (recharge l'interface avec Ctrl+Shift+R)."
  else
    warn "Réinstallation de proxmox-widget-toolkit échouée (sans gravité, c'est cosmétique)."
  fi
}

# ---------------------------------------------------------------- HA
disable_ha() {
  step "Haute disponibilité (HA)"
  if [ -f /etc/pve/corosync.conf ]; then
    info "Cluster détecté : HA laissé actif."
    return 0
  fi
  if ask "Nœud seul : désactiver pve-ha-lrm et pve-ha-crm (moins d'écritures disque) ?" n; then
    systemctl disable --now pve-ha-lrm pve-ha-crm >/dev/null 2>&1 || true
    ok "Services HA désactivés."
  else
    info "Ignoré."
  fi
}

# ---------------------------------------------------------------- Mise à jour
upgrade_system() {
  step "Mise à jour du système"
  if [ "$SKIP_UPGRADE" -eq 1 ]; then
    info "Ignoré (--skip-upgrade)."
    return 0
  fi
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get -y \
    -o Dpkg::Options::=--force-confdef \
    -o Dpkg::Options::=--force-confold \
    dist-upgrade
  ok "Système à jour."
}

# ---------------------------------------------------------------- Outils
install_tools() {
  step "Outils de base"
  local pkgs=(curl wget git vim htop btop tmux ncdu iotop iftop dnsutils net-tools lsof)
  if ask "Installer : ${pkgs[*]} ?" y; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${pkgs[@]}" >/dev/null
    ok "Outils installés."
  else
    info "Ignoré."
  fi
}

# ---------------------------------------------------------------- Fin
finish() {
  step "Terminé"
  local running latest
  running="$(uname -r)"
  latest="$(find /boot -maxdepth 1 -name 'vmlinuz-*' -printf '%f\n' 2>/dev/null | sed 's/^vmlinuz-//' | sort -V | tail -n1)"
  ok "Post-installation terminée. Sauvegarde des dépôts : $BACKUP_DIR"
  if [ -n "$latest" ] && [ "$latest" != "$running" ]; then
    warn "Nouveau noyau installé ($latest, actuel : $running) : redémarrage conseillé."
    if ask "Redémarrer maintenant ?" n; then
      reboot
    fi
  fi
}

main() {
  parse_args "$@"
  printf '%s\n' "${C_BOLD}=== pve/first-start — get.andries.icu ===${C_RESET}"
  preflight
  setup_repos
  remove_nag
  disable_ha
  upgrade_system
  install_tools
  finish
}

main "$@"
