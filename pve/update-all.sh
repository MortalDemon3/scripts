#!/usr/bin/env bash
# DESC: Mise à jour Proxmox VE : hôte et/ou conteneurs LXC, snapshot avant chaque CT
#
# Usage :
#   curl -fsSL https://get.andries.icu/pve/update-all | bash
#   curl -fsSL https://get.andries.icu/pve/update-all | bash -s -- --mode ct --exclude 120,150
#   curl -fsSL https://get.andries.icu/pve/update-all | bash -s -- --mode all --router 140 --yes
#
# Options :
#   -m, --mode MODE           all (hôte + CT), host (hôte seul), ct (CT seuls)
#   -e, --exclude LISTE       IDs des CT à ne pas traiter (virgules ou espaces)
#   -r, --router ID           CT routeur/firewall : traité en dernier, puis contrôlé
#       --router-min-rules N  Nombre minimal de règles iptables sur le routeur (défaut : 30)
#   -k, --keep-days N         Conservation des snapshots save_<date> en jours (défaut : 7)
#   -y, --yes                 Aucune question (obligatoire sans terminal, ex. cron)
#   -h, --help                Affiche l'aide
#
# Sans option, le script demande quoi mettre à jour et quels CT éviter.
# Les CT arrêtés sont ignorés. Debian, Ubuntu, Rocky/RHEL/Alma/Fedora et Alpine sont gérés.
# Log dans /var/log/update-all/, conservé uniquement en cas d'échec.
#
# ⚠️ Restaurer un snapshot (pct rollback) ramène aussi l'ancienne configuration
#    du CT, y compris son réseau.
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

usage() {
  cat <<'EOF'
pve/update-all — Mise à jour Proxmox VE : hôte et/ou conteneurs LXC

Usage :
  curl -fsSL https://get.andries.icu/pve/update-all | bash
  curl -fsSL https://get.andries.icu/pve/update-all | bash -s -- [options]

Options :
  -m, --mode MODE           all (hôte + CT), host (hôte seul), ct (CT seuls)
  -e, --exclude LISTE       IDs des CT à ne pas traiter (virgules ou espaces)
  -r, --router ID           CT routeur/firewall : traité en dernier, puis contrôlé
      --router-min-rules N  Nombre minimal de règles iptables sur le routeur (défaut : 30)
  -k, --keep-days N         Conservation des snapshots save_<date> en jours (défaut : 7)
  -y, --yes                 Aucune question (obligatoire sans terminal, ex. cron)
  -h, --help                Affiche cette aide

Sans option, le script demande quoi mettre à jour et quels CT éviter.
EOF
}

# ---------------------------------------------------------------- Paramètres
MODE=""
EXCLUDE=""
ROUTER_CTID=""
ROUTER_MIN_RULES=30
KEEP_DAYS=7
ASSUME_YES=0

SNAP_PREFIX="save_"
SNAP_NAME="${SNAP_PREFIX}$(date +%d-%m-%y)"
LOG_DIR="/var/log/update-all"
LOG=""
TEE_PID=""

export DEBIAN_FRONTEND=noninteractive
APT_OPTS='-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold'

# Compteurs
total_running=0; total_updated=0; total_uptodate=0; total_failed=0
total_skipped=0; total_excluded=0; total_unknown=0; total_purged=0
host_status="non traité"

# ---------------------------------------------------------------- Outils
has_tty() { { : </dev/tty; } 2>/dev/null; }

ask() {  # ask "question" défaut -> réponse sur stdout
  local reponse
  read -r -p "$1" reponse </dev/tty || reponse=""
  printf '%s' "${reponse:-$2}"
}

normalize_list() { echo "$1" | tr ',;' '  ' | xargs; }

is_excluded() {
  local e
  for e in $EXCLUDE; do
    if [ "$e" = "$1" ]; then return 0; fi
  done
  return 1
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      -m|--mode)          MODE="${2:-}"; shift 2 ;;
      -e|--exclude)       EXCLUDE="${2:-}"; shift 2 ;;
      -r|--router)        ROUTER_CTID="${2:-}"; shift 2 ;;
      --router-min-rules) ROUTER_MIN_RULES="${2:-}"; shift 2 ;;
      -k|--keep-days)     KEEP_DAYS="${2:-}"; shift 2 ;;
      -y|--yes)           ASSUME_YES=1; shift ;;
      -h|--help)          usage; exit 0 ;;
      *) die "Option inconnue : $1 (voir --help)" ;;
    esac
  done
}

validate() {
  local id
  EXCLUDE="$(normalize_list "$EXCLUDE")"
  case "$MODE" in
    all|host|ct) ;;
    *) die "Mode invalide : '$MODE' (attendu : all, host ou ct)" ;;
  esac
  for id in $EXCLUDE; do
    [[ "$id" =~ ^[0-9]+$ ]] || die "ID de CT invalide dans la liste d'exclusion : '$id'"
  done
  if [ -n "$ROUTER_CTID" ]; then
    [[ "$ROUTER_CTID" =~ ^[0-9]+$ ]] || die "ID de routeur invalide : '$ROUTER_CTID'"
  fi
  [[ "$ROUTER_MIN_RULES" =~ ^[0-9]+$ ]] || die "--router-min-rules doit être un nombre"
  [[ "$KEEP_DAYS" =~ ^[0-9]+$ ]] || die "--keep-days doit être un nombre"
}

# ---------------------------------------------------------------- Questions
interactive_setup() {
  local choix ids id

  if [ -z "$MODE" ]; then
    echo ""
    echo "${C_BOLD}Que veux-tu mettre à jour ?${C_RESET}"
    echo "  1) Tout (hôte Proxmox + conteneurs)"
    echo "  2) Seulement l'hôte Proxmox"
    echo "  3) Seulement les conteneurs"
    choix="$(ask "Choix [1] : " 1)"
    case "$choix" in
      1) MODE=all ;;
      2) MODE=host ;;
      3) MODE=ct ;;
      *) die "Choix invalide : $choix" ;;
    esac
  fi

  if [ "$MODE" != "host" ]; then
    echo ""
    echo "${C_BOLD}Conteneurs présents :${C_RESET}"
    pct list
    ids="$(pct list | awk 'NR>1 {print $1}' | xargs)"

    echo ""
    EXCLUDE="$(ask "CT à NE PAS mettre à jour, ex. 120,150 (Entrée = ${EXCLUDE:-aucun}) : " "$EXCLUDE")"
    EXCLUDE="$(normalize_list "$EXCLUDE")"
    for id in $EXCLUDE; do
      if ! echo " $ids " | grep -q " $id "; then
        warn "Le CT $id n'existe pas, il sera simplement ignoré."
      fi
    done

    ROUTER_CTID="$(ask "CT routeur/firewall à traiter en dernier (Entrée = ${ROUTER_CTID:-aucun}) : " "$ROUTER_CTID")"
  fi

  validate

  echo ""
  echo "${C_BOLD}Récapitulatif${C_RESET}"
  case "$MODE" in
    all)  echo "  Mode      : hôte Proxmox + conteneurs" ;;
    host) echo "  Mode      : hôte Proxmox seulement" ;;
    ct)   echo "  Mode      : conteneurs seulement" ;;
  esac
  if [ "$MODE" != "host" ]; then
    echo "  Exclus    : ${EXCLUDE:-aucun}"
    echo "  Routeur   : ${ROUTER_CTID:-aucun}"
    echo "  Snapshots : $SNAP_NAME (anciens save_* purgés après $KEEP_DAYS j)"
  fi
  choix="$(ask "Lancer la mise à jour ? [O/n] : " O)"
  case "$choix" in
    o|O|oui|Oui|y|Y|yes) ;;
    *) die "Annulé." ;;
  esac
}

# ---------------------------------------------------------------- Journalisation
start_logging() {
  mkdir -p "$LOG_DIR"
  LOG="$LOG_DIR/$(date +%Y-%m-%d_%H%M%S).log"
  exec 3>&1 4>&2                       # garde l'écran d'origine
  exec > >(tee -a "$LOG") 2>&1
  TEE_PID=$!
  trap finish EXIT
}

finish() {
  local code=$?
  echo ""
  if [ "$code" -eq 0 ]; then
    echo "✓ Tout s'est bien passé, log supprimé."
  else
    echo "✗ Échec(s) détecté(s), log conservé : $LOG"
  fi
  # Ferme le tube vers tee et attend qu'il ait tout écrit avant de rendre la main
  exec 1>&3 2>&4 3>&- 4>&-
  wait "$TEE_PID" 2>/dev/null || true
  if [ "$code" -eq 0 ]; then rm -f "$LOG"; fi
}

# ---------------------------------------------------------------- Fonctions de mise à jour
print_section() {
  echo ""
  echo "═══════════════════════════════════════════════════════════"
  echo "  $1"
  echo "═══════════════════════════════════════════════════════════"
}

update_host() {
  local count
  print_section "Hôte Proxmox"
  apt-get update -qq >/dev/null 2>&1 || warn "apt-get update a renvoyé une erreur"
  count=$(apt list --upgradable 2>/dev/null | grep -c "upgradable" || true)
  [[ "$count" =~ ^[0-9]+$ ]] || count=0

  if [ "$count" -eq 0 ]; then
    echo "  ✓ Hôte déjà à jour"
    host_status="déjà à jour"
  else
    echo "  ↳ $count paquet(s) disponible(s)"
    # shellcheck disable=SC2086
    if apt-get -y $APT_OPTS dist-upgrade >/dev/null 2>&1 && apt-get -y autoremove >/dev/null 2>&1; then
      echo "  ✓ Hôte mis à jour ($count paquets)"
      host_status="mis à jour ($count paquets)"
      if [ -f /var/run/reboot-required ]; then
        echo "  ⚠ Redémarrage de l'hôte recommandé (nouveau noyau ou bibliothèque système)"
      fi
    else
      echo "  ✗ ÉCHEC de la mise à jour de l'hôte"
      host_status="ÉCHEC"
      total_failed=$((total_failed+1))
    fi
  fi
}

check_router() {
  local ok=1 rules
  if ! pct exec "$ROUTER_CTID" -- systemctl is-active --quiet iptables; then
    echo "  ├─ ✗ iptables inactif sur le routeur"; ok=0
  fi
  if ! pct exec "$ROUTER_CTID" -- systemctl is-active --quiet fail2ban; then
    echo "  ├─ ✗ fail2ban inactif sur le routeur"; ok=0
  fi
  rules=$(pct exec "$ROUTER_CTID" -- bash -c "iptables -S | grep -c '^-A'" 2>/dev/null || true)
  [[ "$rules" =~ ^[0-9]+$ ]] || rules=0
  if [ "$rules" -lt "$ROUTER_MIN_RULES" ]; then
    echo "  ├─ ✗ Seulement $rules règle(s) chargée(s) sur le routeur (attendu ≥ $ROUTER_MIN_RULES)"
    ok=0
  else
    echo "  ├─ Firewall routeur : $rules règles chargées"
  fi
  [ "$ok" -eq 1 ]
}

# Supprime les snapshots save_jj-mm-aa plus vieux que KEEP_DAYS (jamais celui du jour)
purge_old_snapshots() {
  local ct="$1" snap d m y snap_ts limit_ts purged=0
  limit_ts=$(date -d "-${KEEP_DAYS} days" +%s)
  for snap in $(pct listsnapshot "$ct" 2>/dev/null | grep -oE "${SNAP_PREFIX}[0-9]{2}-[0-9]{2}-[0-9]{2}" | sort -u || true); do
    if [ "$snap" = "$SNAP_NAME" ]; then continue; fi
    IFS=- read -r d m y <<< "${snap#"$SNAP_PREFIX"}"
    snap_ts=$(date -d "20${y}-${m}-${d}" +%s 2>/dev/null) || continue
    if [ "$snap_ts" -lt "$limit_ts" ]; then
      if pct delsnapshot "$ct" "$snap" >/dev/null 2>&1; then
        purged=$((purged+1))
      else
        echo "  ├─ ✗ Impossible de supprimer le snapshot $snap"
      fi
    fi
  done
  if [ "$purged" -gt 0 ]; then
    echo "  ├─ Purge : $purged ancien(s) snapshot(s) supprimé(s) (> ${KEEP_DAYS} j)"
    total_purged=$((total_purged+purged))
  fi
}

update_ct() {
  local ct="$1" status name os_id pkg_count update_cmd

  status=$(pct status "$ct" 2>/dev/null | awk '{print $2}' || true)
  name=$(pct config "$ct" 2>/dev/null | awk '/^hostname:/ {print $2}' || true)

  if is_excluded "$ct"; then
    printf "[CT %-3s] %-20s ⊗ Exclu (liste)\n" "$ct" "$name"
    total_excluded=$((total_excluded+1))
    return
  fi

  if [ "$status" != "running" ]; then
    printf "[CT %-3s] %-20s ⊘ Arrêté, ignoré\n" "$ct" "$name"
    total_skipped=$((total_skipped+1))
    return
  fi

  total_running=$((total_running+1))
  os_id=$(pct exec "$ct" -- sh -c "grep '^ID=' /etc/os-release | cut -d= -f2 | tr -d '\"'" 2>/dev/null || true)

  echo ""
  if [ "$ct" = "$ROUTER_CTID" ]; then
    echo "[CT $ct] $name ($os_id) — ROUTEUR, traité en dernier"
  else
    echo "[CT $ct] $name ($os_id)"
  fi

  # --- Snapshot (écrasé s'il existe déjà) ---
  pct delsnapshot "$ct" "$SNAP_NAME" >/dev/null 2>&1 || true
  if pct snapshot "$ct" "$SNAP_NAME" >/dev/null 2>&1; then
    echo "  ├─ Snapshot $SNAP_NAME ............. ✓ OK"
  else
    echo "  ├─ Snapshot $SNAP_NAME ............. ✗ ÉCHEC"
    echo "  └─ Mise à jour annulée par sécurité"
    total_failed=$((total_failed+1))
    return
  fi

  purge_old_snapshots "$ct"

  # --- Commande selon l'OS ---
  case "$os_id" in
    debian|ubuntu)
      pct exec "$ct" -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get update -qq" >/dev/null 2>&1 || true
      pkg_count=$(pct exec "$ct" -- bash -c "apt list --upgradable 2>/dev/null | grep -c upgradable" 2>/dev/null || true)
      update_cmd="DEBIAN_FRONTEND=noninteractive apt-get -y $APT_OPTS dist-upgrade >/dev/null 2>&1 && apt-get -y autoremove >/dev/null 2>&1"
      ;;
    rocky|rhel|centos|almalinux|fedora)
      pkg_count=$(pct exec "$ct" -- bash -c "dnf -q check-update 2>/dev/null | grep -vE '^$|^Obsoleting' | wc -l" 2>/dev/null || true)
      update_cmd="dnf -y upgrade >/dev/null 2>&1 && dnf -y autoremove >/dev/null 2>&1"
      ;;
    alpine)
      pct exec "$ct" -- apk update >/dev/null 2>&1 || true
      pkg_count=$(pct exec "$ct" -- sh -c "apk version -l '<' 2>/dev/null | tail -n +2 | wc -l" 2>/dev/null || true)
      update_cmd="apk upgrade >/dev/null 2>&1"
      ;;
    *)
      echo "  └─ ✗ OS inconnu (${os_id:-?}), mise à jour ignorée"
      total_unknown=$((total_unknown+1))
      return
      ;;
  esac

  pkg_count=$(echo "$pkg_count" | tr -dc '0-9')
  [[ "$pkg_count" =~ ^[0-9]+$ ]] || pkg_count=0
  echo "  ├─ Paquets disponibles : $pkg_count"

  if [ "$pkg_count" -eq 0 ]; then
    echo "  └─ ✓ Déjà à jour"
    total_uptodate=$((total_uptodate+1))
    return
  fi

  if pct exec "$ct" -- sh -c "$update_cmd"; then
    if [ "$ct" = "$ROUTER_CTID" ] && ! check_router; then
      echo "  └─ ✗ Routeur mis à jour MAIS firewall en défaut — retour arrière : pct rollback $ct $SNAP_NAME"
      total_failed=$((total_failed+1))
    else
      echo "  └─ ✓ Mis à jour ($pkg_count paquets installés)"
      total_updated=$((total_updated+1))
    fi
  else
    echo "  └─ ✗ ÉCHEC de la mise à jour"
    total_failed=$((total_failed+1))
  fi
}

update_containers() {
  local ct_list ct
  print_section "Conteneurs LXC (snapshot : $SNAP_NAME, conservation ${KEEP_DAYS} j)"

  ct_list="$(pct list | awk 'NR>1 {print $1}' | xargs)"
  if [ -n "$ROUTER_CTID" ]; then
    ct_list="$(echo " $ct_list " | sed "s/ $ROUTER_CTID / /" | xargs)"
    if pct status "$ROUTER_CTID" >/dev/null 2>&1; then
      ct_list="$ct_list $ROUTER_CTID"
    else
      warn "Le CT routeur $ROUTER_CTID n'existe pas : aucun traitement particulier."
    fi
  fi

  for ct in $ct_list; do
    update_ct "$ct"
  done
}

print_summary() {
  print_section "Résumé"
  if [ "$MODE" != "ct" ]; then
    echo "  Hôte Proxmox              : $host_status"
  fi
  if [ "$MODE" != "host" ]; then
    echo "  Conteneurs actifs traités : $total_running"
    echo "  ✓ Mis à jour              : $total_updated"
    echo "  ✓ Déjà à jour             : $total_uptodate"
    echo "  ? OS inconnu              : $total_unknown"
    echo "  ⊗ Exclus (liste)          : $total_excluded"
    echo "  ⊘ Arrêtés (ignorés)       : $total_skipped"
    echo "  🗑  Snapshots purgés       : $total_purged"
  fi
  echo "  ✗ En échec                : $total_failed"
}

# ---------------------------------------------------------------- Main
main() {
  parse_args "$@"

  [ "$(id -u)" -eq 0 ] || die "À lancer en root sur l'hôte Proxmox."
  command -v pct >/dev/null 2>&1 || die "Commande pct introuvable : ce n'est pas un hôte Proxmox VE."

  if [ "$ASSUME_YES" -eq 1 ]; then
    MODE="${MODE:-all}"
    validate
  elif has_tty; then
    interactive_setup
  else
    die "Pas de terminal pour poser les questions : ajoute --yes (et --mode, --exclude...)."
  fi

  start_logging
  info "Mise à jour lancée le $(date '+%d/%m/%Y à %H:%M') — mode : $MODE"

  if [ "$MODE" != "ct" ]; then update_host; fi
  if [ "$MODE" != "host" ]; then update_containers; fi

  print_summary
  [ "$total_failed" -eq 0 ]
}

main "$@"