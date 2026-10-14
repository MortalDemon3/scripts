#!/bin/bash
# DESC: Sécurisation standard Debian/Ubuntu/Rocky : pare-feu iptables (SSH seul) + fail2ban
#
# D'après tala-informatique.fr :
#   - https://tala-informatique.fr/index.php?title=Iptables
#   - https://tala-informatique.fr/index.php?title=Sécuriser_un_service_avec_Fail2ban
#
# Usage :
#   curl -fsSL https://get.andries.icu/linux/secure | bash
#   curl -fsSL https://get.andries.icu/linux/secure | bash -s -- --port 80 --port 443
#   curl -fsSL https://get.andries.icu/linux/secure | bash -s -- --iface eth0 --ignore 192.168.30.251
#
# Options :
#   -i, --iface IF     Interface à protéger (défaut : celle de la session SSH ou de la route par défaut)
#   -p, --port N       Port TCP supplémentaire à ouvrir (répétable, ou liste : 80,443)
#       --ignore IP    IP ou réseau que fail2ban ne bannira jamais (répétable)
#   -y, --yes          Non interactif (pas de questions, pas de retour arrière automatique)
#   -h, --help         Aide
#
# Sécurité anti-blocage : les nouvelles règles sont appliquées SANS être sauvegardées.
# Si tu ne confirmes pas dans les 90 s (connexion coupée, mauvaise règle...),
# les anciennes règles sont restaurées automatiquement.
set -euo pipefail

# ================================================================ Affichage
if [ -t 1 ]; then
  C_R=$'\e[0m'; C_B=$'\e[1m'; C_BLUE=$'\e[34m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_RED=$'\e[31m'
else
  C_R=''; C_B=''; C_BLUE=''; C_G=''; C_Y=''; C_RED=''
fi
info() { printf '%s[i]%s %s\n' "$C_BLUE" "$C_R" "$*"; }
ok()   { printf '%s[✓]%s %s\n' "$C_G" "$C_R" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_Y" "$C_R" "$*" >&2; }
die()  { printf '%s[✗]%s %s\n' "$C_RED" "$C_R" "$*" >&2; exit 1; }
step() { printf '\n%s==> %s%s\n' "$C_B" "$*" "$C_R"; }

# ================================================================ Variables
ASSUME_YES=0
IFACE=""
EXTRA_PORTS=()
IGNORE_IPS=()
OS_ID=""
OS_FAMILY=""      # debian | rhel
SSH_PORT=22
SSH_CLIENT_IP=""
IS_PVE=0
HAS_IPV6=0
ROLLBACK_PID=""
ROLLBACK_DELAY=90
BACKUP_DIR="/root/secure-backup-$(date +%Y%m%d-%H%M%S)"

usage() {
  cat <<'EOF2'
linux/secure — pare-feu iptables + fail2ban (Debian, Ubuntu, Rocky)

Usage :
  curl -fsSL https://get.andries.icu/linux/secure | bash
  curl -fsSL https://get.andries.icu/linux/secure | bash -s -- [options]

Options :
  -i, --iface IF     Interface à protéger (défaut : détectée automatiquement)
  -p, --port N       Port TCP supplémentaire à ouvrir (répétable, ou 80,443)
      --ignore IP    IP ou réseau que fail2ban ne bannira jamais (répétable)
  -y, --yes          Non interactif (pas de retour arrière automatique)
  -h, --help         Aide
EOF2
}

# Vrai si on peut lire le clavier (session interactive)
has_tty() { { : < /dev/tty; } 2>/dev/null; }

# Questions au clavier via /dev/tty (stdin = le script avec curl | bash)
ask() {
  local q="$1" def="${2:-n}" ans="" prompt
  if [ "$ASSUME_YES" -eq 1 ]; then [ "$def" = y ]; return; fi
  if [ "$def" = y ]; then prompt="[O/n]"; else prompt="[o/N]"; fi
  read -r -p "$q $prompt " ans < /dev/tty 2>/dev/null || ans=""
  ans="${ans:-$def}"
  case "${ans,,}" in o|oui|y|yes) return 0 ;; *) return 1 ;; esac
}

parse_args() {
  local p
  while [ $# -gt 0 ]; do
    case "$1" in
      -i|--iface)  IFACE="${2:?--iface demande une interface}"; shift ;;
      -p|--port)
        IFS=',' read -r -a p <<< "${2:?--port demande un numéro}"
        EXTRA_PORTS+=("${p[@]}"); shift ;;
      --ignore)    IGNORE_IPS+=("${2:?--ignore demande une IP}"); shift ;;
      -y|--yes)    ASSUME_YES=1 ;;
      -h|--help)   usage; exit 0 ;;
      *)           die "Option inconnue : $1 (voir --help)" ;;
    esac
    shift
  done
  for p in "${EXTRA_PORTS[@]}"; do
    [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -ge 1 ] && [ "$p" -le 65535 ] || die "Port invalide : $p"
  done
}

# ================================================================ Détection
detect_os() {
  [ -r /etc/os-release ] || die "/etc/os-release introuvable : OS non reconnu."
  # shellcheck source=/dev/null
  . /etc/os-release
  OS_ID="${ID:-}"
  case "$OS_ID" in
    debian|ubuntu) OS_FAMILY=debian ;;
    rocky)         OS_FAMILY=rhel ;;
    *) die "OS non supporté : '${PRETTY_NAME:-$OS_ID}'. Supportés : Debian, Ubuntu, Rocky Linux." ;;
  esac
  ok "OS détecté : ${PRETTY_NAME:-$OS_ID}"

  if command -v pveversion >/dev/null 2>&1; then
    IS_PVE=1
    ok "Proxmox VE détecté : le port 8006 (interface web) sera ouvert."
  fi
  if [ -f /proc/net/if_inet6 ]; then HAS_IPV6=1; fi
}

detect_ssh() {
  # Port SSH réel (si sshd n'écoute pas sur 22, on ne se bloque pas dehors)
  local p
  p="$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}' || true)"
  [ -n "$p" ] && SSH_PORT="$p"
  # IP de la personne connectée en SSH (pour ne pas se bannir soi-même)
  if [ -n "${SSH_CONNECTION:-}" ]; then
    SSH_CLIENT_IP="${SSH_CONNECTION%% *}"
  fi
}

detect_iface() {
  if [ -n "$IFACE" ]; then
    ip link show "$IFACE" >/dev/null 2>&1 || die "Interface '$IFACE' introuvable."
    return
  fi
  # 1) l'interface par laquelle arrive la session SSH actuelle
  if [ -n "$SSH_CLIENT_IP" ]; then
    IFACE="$(ip route get "$SSH_CLIENT_IP" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' || true)"
  fi
  # 2) sinon, l'interface de la route par défaut
  if [ -z "$IFACE" ]; then
    IFACE="$(ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' || true)"
  fi
  [ -n "$IFACE" ] || die "Impossible de détecter l'interface. Utilise --iface <nom> (voir 'ip -br a')."
}

# ================================================================ Conflits
check_conflicts() {
  step "Vérification des pare-feu déjà présents"

  if [ "$IS_PVE" -eq 1 ] && pve-firewall status 2>/dev/null | grep -qi 'enabled'; then
    warn "Le pare-feu intégré de Proxmox (pve-firewall) est actif : il gère lui-même iptables"
    warn "et risque d'écraser ou de contredire ces règles."
    ask "Continuer quand même ?" n || die "Arrêt. Désactive pve-firewall (Datacenter → Firewall) ou garde-le à la place."
  fi

  if command -v docker >/dev/null 2>&1; then
    warn "Docker détecté : 'FORWARD -j DROP' couperait le réseau des conteneurs Docker."
  fi
}

disable_other_firewalls() {
  step "Désactivation des autres gestionnaires de pare-feu"
  if [ "$OS_FAMILY" = rhel ] && systemctl is-enabled firewalld >/dev/null 2>&1; then
    systemctl disable --now firewalld >/dev/null 2>&1 || true
    systemctl mask firewalld >/dev/null 2>&1 || true
    ok "firewalld désactivé (remplacé par iptables)."
  fi
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
    ufw --force disable >/dev/null
    ok "ufw désactivé (remplacé par iptables)."
  fi
  # Sur Debian, nftables.service vide TOUTES les règles au démarrage (flush ruleset)
  if [ "$OS_FAMILY" = debian ] && systemctl is-enabled nftables >/dev/null 2>&1; then
    systemctl disable nftables >/dev/null 2>&1 || true
    ok "Service nftables désactivé (il effaçait les règles au démarrage)."
  fi
  info "Rien d'autre à désactiver."
}

# ================================================================ Paquets
install_packages() {
  step "Installation des paquets"
  if [ "$OS_FAMILY" = debian ]; then
    export DEBIAN_FRONTEND=noninteractive
    # Réponses automatiques aux questions d'iptables-persistent
    echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections
    echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" | debconf-set-selections
    apt-get update -qq
    apt-get -y -qq install iptables iptables-persistent fail2ban python3-systemd >/dev/null
  else
    dnf -y -q install epel-release >/dev/null
    # iptables-services : équivalent Rocky d'iptables-persistent
    # fail2ban-server : fail2ban SANS le module firewalld
    dnf -y -q install iptables-services fail2ban-server python3-systemd >/dev/null
  fi
  ok "iptables, persistance des règles et fail2ban installés."
}

# ================================================================ Règles
backup_rules() {
  mkdir -p "$BACKUP_DIR"
  iptables-save > "$BACKUP_DIR/rules.v4.avant"
  if [ "$HAS_IPV6" -eq 1 ]; then ip6tables-save > "$BACKUP_DIR/rules.v6.avant"; fi

  # Script de restauration : on ouvre tout PUIS on recharge l'ancien état.
  # (si la machine n'avait aucune règle, la sauvegarde est vide et
  #  iptables-restore seul ne retirerait pas les nouvelles règles)
  cat > "$BACKUP_DIR/restore.sh" <<EOF
#!/bin/bash
# Restaure les règles d'avant linux/secure
iptables -P INPUT ACCEPT; iptables -P FORWARD ACCEPT; iptables -P OUTPUT ACCEPT; iptables -F
iptables-restore < '$BACKUP_DIR/rules.v4.avant'
if [ -f '$BACKUP_DIR/rules.v6.avant' ]; then
  ip6tables -P INPUT ACCEPT; ip6tables -P FORWARD ACCEPT; ip6tables -P OUTPUT ACCEPT; ip6tables -F
  ip6tables-restore < '$BACKUP_DIR/rules.v6.avant'
fi
EOF
  chmod 700 "$BACKUP_DIR/restore.sh"
  ok "Règles actuelles sauvegardées dans $BACKUP_DIR"
}

start_rollback() {
  # Processus détaché : il survit même si la session SSH est coupée
  setsid bash -c "sleep $ROLLBACK_DELAY; bash '$BACKUP_DIR/restore.sh'" >/dev/null 2>&1 < /dev/null &
  ROLLBACK_PID=$!
  info "Retour arrière automatique programmé dans ${ROLLBACK_DELAY} s."
}

cancel_rollback() {
  [ -n "$ROLLBACK_PID" ] || return 0
  pkill -P "$ROLLBACK_PID" 2>/dev/null || true
  kill "$ROLLBACK_PID" 2>/dev/null || true
  ROLLBACK_PID=""
  ok "Retour arrière automatique annulé."
}

apply_rules() {
  step "Application des règles iptables (IPv4) sur $IFACE"

  # On repart de zéro pour que le script soit relançable sans doublons
  iptables -P INPUT ACCEPT
  iptables -P FORWARD ACCEPT
  iptables -F INPUT
  iptables -F FORWARD

  iptables -A INPUT -i "$IFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT
  iptables -A INPUT -i "$IFACE" -p icmp -j ACCEPT
  iptables -A INPUT -i lo -j ACCEPT
  iptables -A INPUT -i "$IFACE" -p tcp -m state --state NEW -m tcp --dport "$SSH_PORT" -j ACCEPT

  if [ "$IS_PVE" -eq 1 ]; then
    iptables -A INPUT -i "$IFACE" -p tcp -m state --state NEW -m tcp --dport 8006 -j ACCEPT
  fi
  local p
  for p in "${EXTRA_PORTS[@]}"; do
    iptables -A INPUT -i "$IFACE" -p tcp -m state --state NEW -m tcp --dport "$p" -j ACCEPT
  done

  iptables -A INPUT -j DROP

  if [ "$IS_PVE" -eq 1 ]; then
    warn "Proxmox : FORWARD laissé ouvert pour ne pas couper le réseau des VM/CT."
  elif command -v docker >/dev/null 2>&1; then
    warn "Docker : FORWARD laissé ouvert pour ne pas couper les conteneurs."
  else
    iptables -A FORWARD -j DROP
  fi
  ok "Règles IPv4 appliquées."

  if [ "$HAS_IPV6" -eq 1 ]; then
    step "Blocage d'IPv6"
    ip6tables -F INPUT
    ip6tables -F FORWARD
    ip6tables -F OUTPUT
    # Boucle locale ::1 autorisée : certains services l'utilisent en interne
    ip6tables -A INPUT -i lo -j ACCEPT
    ip6tables -A OUTPUT -o lo -j ACCEPT
    ip6tables -P INPUT DROP
    ip6tables -P FORWARD DROP
    ip6tables -P OUTPUT DROP
    ok "IPv6 bloqué (sauf ::1)."
  else
    info "IPv6 désactivé sur cette machine : rien à faire."
  fi
}

confirm_access() {
  [ "$ASSUME_YES" -eq 1 ] && return 0
  has_tty || return 0

  printf '\n%s' "$C_B"
  echo "┌──────────────────────────────────────────────────────────────┐"
  echo "│  TESTE MAINTENANT : ouvre une NOUVELLE connexion SSH (et     │"
  echo "│  l'interface web si Proxmox) SANS fermer celle-ci.           │"
  echo "│  Si ça marche, tape 'oui'. Sinon, ne fais rien : les         │"
  echo "│  anciennes règles reviennent toutes seules.                  │"
  echo "└──────────────────────────────────────────────────────────────┘"
  printf '%s' "$C_R"

  local rep=""
  read -r -t $((ROLLBACK_DELAY - 5)) -p "Accès OK ? (oui) : " rep < /dev/tty || true
  if [ "${rep,,}" = oui ]; then
    cancel_rollback
  else
    echo
    warn "Pas de confirmation : restauration des anciennes règles..."
    cancel_rollback
    bash "$BACKUP_DIR/restore.sh"
    die "Anciennes règles restaurées. Rien n'a été sauvegardé. Vérifie --iface / --port et relance."
  fi
}

save_rules() {
  step "Sauvegarde des règles (persistance au redémarrage)"
  if [ "$OS_FAMILY" = debian ]; then
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4
    if [ "$HAS_IPV6" -eq 1 ]; then ip6tables-save > /etc/iptables/rules.v6; fi
    systemctl enable netfilter-persistent >/dev/null 2>&1
    ok "Règles enregistrées dans /etc/iptables/ (netfilter-persistent activé)."
  else
    iptables-save > /etc/sysconfig/iptables
    if [ "$HAS_IPV6" -eq 1 ]; then ip6tables-save > /etc/sysconfig/ip6tables; fi
    systemctl enable iptables >/dev/null 2>&1
    if [ "$HAS_IPV6" -eq 1 ]; then systemctl enable ip6tables >/dev/null 2>&1; fi
    ok "Règles enregistrées dans /etc/sysconfig/ (services iptables activés)."
  fi
}

# ================================================================ Fail2ban
configure_fail2ban() {
  step "Configuration de fail2ban"

  # Sur Rocky, ce fichier force firewalld comme méthode de bannissement
  if [ -f /etc/fail2ban/jail.d/00-firewalld.conf ]; then
    mv /etc/fail2ban/jail.d/00-firewalld.conf /etc/fail2ban/jail.d/00-firewalld.conf.disabled
  fi
  if [ -f /etc/fail2ban/jail.local ] && [ ! -e "$BACKUP_DIR/jail.local.avant" ]; then
    cp /etc/fail2ban/jail.local "$BACKUP_DIR/jail.local.avant"
  fi

  local ignore="127.0.0.1/8 ::1"
  [ -n "$SSH_CLIENT_IP" ] && ignore="$ignore $SSH_CLIENT_IP"
  local ip
  for ip in "${IGNORE_IPS[@]}"; do ignore="$ignore $ip"; done

  # Valeurs de tala-informatique : 3 essais sur 1 jour = banni 1 semaine
  cat > /etc/fail2ban/jail.local <<EOF
# Généré par get.andries.icu/linux/secure — d'après tala-informatique.fr
[DEFAULT]
# IP jamais bannies (machine elle-même, ta session SSH, --ignore)
ignoreip  = $ignore
# 3 essais ratés...
maxretry  = 3
# ...sur 1 jour (86400 s)...
findtime  = 86400
# ...= banni 1 semaine (604800 s)
bantime   = 604800
# Lecture des logs via le journal systemd (Debian 12+, Ubuntu, Rocky)
backend   = systemd
# Bannissement via iptables
banaction = iptables-multiport
banaction_allports = iptables-allports

[sshd]
enabled = true
port    = $SSH_PORT
EOF

  if [ "$IS_PVE" -eq 1 ]; then
    cat > /etc/fail2ban/filter.d/proxmox.conf <<'EOF'
[Definition]
failregex = pvedaemon\[.*authentication (verification )?failure; rhost=<HOST> user=.* msg=.*
ignoreregex =
journalmatch = _SYSTEMD_UNIT=pvedaemon.service
EOF
    cat >> /etc/fail2ban/jail.local <<'EOF'

[proxmox]
enabled = true
port    = https,http,8006
filter  = proxmox
EOF
    ok "Jail Proxmox (interface web 8006) ajoutée."
  fi

  # Supprime l'avertissement "allowipv6 not defined" des versions récentes
  if [ ! -f /etc/fail2ban/fail2ban.local ]; then
    printf '[Definition]\nallowipv6 = auto\n' > /etc/fail2ban/fail2ban.local
  fi

  fail2ban-client -t >/dev/null || die "Configuration fail2ban invalide (voir : fail2ban-client -t)."
  systemctl enable fail2ban >/dev/null 2>&1
  systemctl restart fail2ban
  sleep 2
  ok "fail2ban actif : $(fail2ban-client status | awk -F':' '/Jail list/ {gsub(/^[ \t]+/,"",$2); print $2}')"
}

# ================================================================ Résumé
summary() {
  local ports="$SSH_PORT (SSH)"
  [ "$IS_PVE" -eq 1 ] && ports="$ports, 8006 (Proxmox)"
  [ "${#EXTRA_PORTS[@]}" -gt 0 ] && ports="$ports, ${EXTRA_PORTS[*]}"

  step "Terminé"
  echo "  OS              : $OS_ID ($OS_FAMILY)"
  echo "  Interface       : $IFACE"
  echo "  Ports ouverts   : $ports + ping"
  echo "  IPv6            : $([ "$HAS_IPV6" -eq 1 ] && echo "bloqué" || echo "désactivé sur la machine")"
  echo "  fail2ban        : 3 essais / 1 jour → banni 1 semaine"
  echo "  Sauvegarde      : $BACKUP_DIR"
  echo
  echo "  Vérifier :"
  echo "    iptables -nvL INPUT"
  echo "    fail2ban-client status sshd"
  echo "  Débannir une IP :"
  echo "    fail2ban-client set sshd unbanip <IP>"
  echo "  Tout annuler :"
  echo "    bash $BACKUP_DIR/restore.sh"
}

# ================================================================ Main
main() {
  parse_args "$@"
  printf '%s=== linux/secure — get.andries.icu ===%s\n' "$C_B" "$C_R"
  [ "$(id -u)" -eq 0 ] || die "À lancer en root."

  step "Détection"
  detect_os
  detect_ssh
  detect_iface
  ok "Interface protégée : $IFACE"
  ok "Port SSH : $SSH_PORT"
  if [ -n "$SSH_CLIENT_IP" ]; then
    ok "Ta session SSH vient de $SSH_CLIENT_IP (ne sera pas bannie)."
  fi

  check_conflicts

  echo
  warn "Ce script REMPLACE les règles INPUT/FORWARD actuelles (une sauvegarde est faite)."
  ask "Continuer avec l'interface '$IFACE' ?" y || die "Arrêt demandé. Choisis l'interface avec --iface <nom>."

  install_packages
  disable_other_firewalls
  backup_rules
  if [ "$ASSUME_YES" -eq 0 ] && has_tty; then start_rollback; fi
  apply_rules
  confirm_access
  save_rules
  configure_fail2ban
  summary
}

# Dernière ligne : si le téléchargement est coupé, rien ne s'exécute
main "$@"