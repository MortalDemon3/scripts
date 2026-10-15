#!/bin/bash
# DESC: Sécurisation Proxmox VE : iptables (SSH + 8006) + fail2ban (SSH + interface web) derrière le reverse-proxy de l'école
#
# D'après tala-informatique.fr :
#   - https://tala-informatique.fr/index.php?title=Proxmox_iptables
#   - https://tala-informatique.fr/index.php?title=Proxmox_fail2ban
#
# Usage :
#   curl -fsSL https://get.andries.icu/proxmox/secure | bash
#   curl -fsSL https://get.andries.icu/proxmox/secure | bash -s -- --f2b-api
#   curl -fsSL https://get.andries.icu/proxmox/secure | bash -s -- --allow-iface wg0
#   curl -fsSL https://get.andries.icu/proxmox/secure | bash -s -- --no-proxy
#
# Options :
#   -i, --iface IF        Interface de management (défaut : route par défaut, sinon vmbr0)
#   -a, --allow-iface IF  Autre interface où SSH, 8006 et ping sont autorisés (ex. wg0) — répétable
#   -p, --port N          Port TCP supplémentaire sur l'interface de management (répétable, ou 80,443)
#       --proxy IP        IP du reverse-proxy (défaut : 192.168.30.251, proxy de l'école)
#       --no-proxy        Le PVE n'est PAS derrière un reverse-proxy (pas de correctif IP réelle)
#       --f2b-api         Bannir les attaques web via l'API fail2ban du proxy (http://PROXY:8080)
#       --ignore IP       IP ou réseau que fail2ban ne bannira jamais (répétable)
#       --keep-ipv6       Ne pas bloquer IPv6
#   -y, --yes             Non interactif (pas de questions, pas de retour arrière automatique)
#   -h, --help            Aide
#
# Ce que fait le script :
#   1. iptables (tuto Proxmox_iptables) : sur l'interface de management, on accepte
#      sessions établies, loopback, ping, SSH et 8006 ; on DROP le reste (et FORWARD si
#      les VM ne passent pas par iptables) ; IPv6 bloqué ; persistance netfilter-persistent.
#   2. Correctif reverse-proxy (tuto Proxmox_fail2ban) : /etc/default/pveproxy + patch
#      AnyEvent.pm pour que les logs montrent la vraie IP du client et pas celle du proxy,
#      réappliqué automatiquement après chaque mise à jour (hook apt).
#   3. fail2ban : jail sshd + jail proxmox (interface web), le proxy n'est jamais banni.
#
# Sécurité anti-blocage : les nouvelles règles iptables sont appliquées SANS être
# sauvegardées. Sans confirmation dans les 90 s, les anciennes reviennent toutes seules.
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
DEFAULT_PROXY="192.168.30.251"   # reverse-proxy de l'école
PROXY_IP="$DEFAULT_PROXY"
ASSUME_YES=0
MGMT_IFACE=""
ALLOW_IFACES=()
EXTRA_PORTS=()
IGNORE_IPS=()
USE_F2B_API=0
F2B_API_FOUND=0
KEEP_IPV6=0
PVE_VERSION=""
SSH_PORT=22
SSH_CLIENT_IP=""
SSH_IFACE=""
HAS_IPV6=0
HAS_V6_GLOBAL=0
BLOCK_V6=0
FORWARD_DROP=1
FORWARD_REASON=""
CLUSTER_IPS=()
WG_PORTS=()
F2B_WAS_ACTIVE=0
ROLLBACK_ON=0
ROLLBACK_DELAY=90
ROLLBACK_UNIT="pve-secure-rollback"
BACKUP_DIR="/root/pve-secure-backup-$(date +%Y%m%d-%H%M%S)"
FIX_SCRIPT="/usr/local/sbin/pve-remoteip-fix"
APT_HOOK="/etc/apt/apt.conf.d/99pve-remoteip-fix"

usage() {
  cat <<'EOF2'
proxmox/secure — iptables + fail2ban pour Proxmox VE (d'après tala-informatique.fr)

Usage :
  curl -fsSL https://get.andries.icu/proxmox/secure | bash
  curl -fsSL https://get.andries.icu/proxmox/secure | bash -s -- [options]

Options :
  -i, --iface IF        Interface de management (défaut : route par défaut, sinon vmbr0)
  -a, --allow-iface IF  Autre interface où SSH, 8006 et ping sont autorisés (ex. wg0)
  -p, --port N          Port TCP supplémentaire sur l'interface de management (ou 80,443)
      --proxy IP        IP du reverse-proxy (défaut : 192.168.30.251, proxy de l'école)
      --no-proxy        PVE pas derrière un reverse-proxy
      --f2b-api         Bannir via l'API fail2ban du proxy (http://PROXY:8080)
      --ignore IP       IP ou réseau jamais banni par fail2ban (répétable)
      --keep-ipv6       Ne pas bloquer IPv6
  -y, --yes             Non interactif (pas de retour arrière automatique)
  -h, --help            Aide
EOF2
}

# Vrai si on peut lire le clavier (session interactive, SSH ou shell web Proxmox)
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

is_ipv4() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }

parse_args() {
  local p
  while [ $# -gt 0 ]; do
    case "$1" in
      -i|--iface)       MGMT_IFACE="${2:?--iface demande une interface}"; shift ;;
      -a|--allow-iface)
        IFS=',' read -r -a p <<< "${2:?--allow-iface demande une interface}"
        ALLOW_IFACES+=("${p[@]}"); shift ;;
      -p|--port)
        IFS=',' read -r -a p <<< "${2:?--port demande un numéro}"
        EXTRA_PORTS+=("${p[@]}"); shift ;;
      --proxy)          PROXY_IP="${2:?--proxy demande une IP}"; shift ;;
      --no-proxy)       PROXY_IP="" ;;
      --f2b-api)        USE_F2B_API=1 ;;
      --ignore)         IGNORE_IPS+=("${2:?--ignore demande une IP}"); shift ;;
      --keep-ipv6)      KEEP_IPV6=1 ;;
      -y|--yes)         ASSUME_YES=1 ;;
      -h|--help)        usage; exit 0 ;;
      *)                die "Option inconnue : $1 (voir --help)" ;;
    esac
    shift
  done
  for p in "${EXTRA_PORTS[@]}"; do
    if ! [[ "$p" =~ ^[0-9]+$ ]] || [ "$p" -lt 1 ] || [ "$p" -gt 65535 ]; then
      die "Port invalide : $p"
    fi
  done
  if [ -n "$PROXY_IP" ] && ! is_ipv4 "$PROXY_IP"; then
    die "IP de proxy invalide : $PROXY_IP (IPv4 attendue)"
  fi
  if [ "$USE_F2B_API" -eq 1 ] && [ -z "$PROXY_IP" ]; then
    die "--f2b-api n'a pas de sens avec --no-proxy."
  fi
}

# ================================================================ Détection
require_pve() {
  command -v pveversion >/dev/null 2>&1 \
    || die "Ce script est réservé à Proxmox VE. Pour un autre Linux : get.andries.icu/linux/secure"
  PVE_VERSION="$(pveversion 2>/dev/null | awk -F'/' '{print $2}')"
  ok "Proxmox VE ${PVE_VERSION:-?} détecté."
  if [ -f /proc/net/if_inet6 ]; then HAS_IPV6=1; fi
  if ip -6 addr show scope global 2>/dev/null | grep -q 'inet6'; then HAS_V6_GLOBAL=1; fi
}

detect_ssh() {
  local p
  p="$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}' || true)"
  if [ -n "$p" ]; then SSH_PORT="$p"; fi
  if [ -n "${SSH_CONNECTION:-}" ]; then
    SSH_CLIENT_IP="${SSH_CONNECTION%% *}"
    SSH_CLIENT_IP="${SSH_CLIENT_IP#::ffff:}"
    SSH_IFACE="$(ip route get "$SSH_CLIENT_IP" 2>/dev/null \
      | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' || true)"
  fi
}

in_list() { local x="$1"; shift; local y; for y in "$@"; do if [ "$y" = "$x" ]; then return 0; fi; done; return 1; }

detect_ifaces() {
  local ifc
  if [ -n "$MGMT_IFACE" ]; then
    ip link show "$MGMT_IFACE" >/dev/null 2>&1 || die "Interface '$MGMT_IFACE' introuvable."
  else
    MGMT_IFACE="$(ip route show default 2>/dev/null \
      | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' || true)"
    if [ -z "$MGMT_IFACE" ] && ip link show vmbr0 >/dev/null 2>&1; then MGMT_IFACE=vmbr0; fi
    [ -n "$MGMT_IFACE" ] || die "Interface de management introuvable. Utilise --iface <nom> (voir 'ip -br a')."
  fi

  for ifc in "${ALLOW_IFACES[@]}"; do
    ip link show "$ifc" >/dev/null 2>&1 || die "Interface '$ifc' (--allow-iface) introuvable."
  done

  # Session SSH arrivée par une autre interface (ex. wg0) : on l'autorise aussi,
  # sinon on se couperait nous-mêmes.
  if [ -n "$SSH_IFACE" ] && [ "$SSH_IFACE" != "$MGMT_IFACE" ] && [ "$SSH_IFACE" != lo ] \
     && ! in_list "$SSH_IFACE" "${ALLOW_IFACES[@]}"; then
    ALLOW_IFACES+=("$SSH_IFACE")
    info "Ta session SSH arrive par $SSH_IFACE : SSH/8006/ping y seront aussi autorisés."
  fi

  # Tuto : seule l'interface de management doit avoir une IP sur l'hôte.
  while read -r ifc; do
    if [ "$ifc" != lo ] && [ "$ifc" != "$MGMT_IFACE" ] && ! in_list "$ifc" "${ALLOW_IFACES[@]}"; then
      warn "$ifc a une IP sur l'hôte : tout trafic entrant vers l'hôte par $ifc sera bloqué."
      warn "  (normal d'après le tuto ; sinon relance avec --allow-iface $ifc)"
    fi
  done < <(ip -4 -o addr show 2>/dev/null | awk '{print $2}' | sort -u)
}

detect_wireguard() {
  # Serveur WireGuard sur l'hôte (ListenPort fixe) : on ouvre son port UDP.
  # Un client WireGuard (comme sur bts3) n'en a pas besoin : réponses = ESTABLISHED.
  local f p
  for f in /etc/wireguard/*.conf; do
    [ -f "$f" ] || continue
    p="$(awk -F'=' 'tolower($1) ~ /^[ \t]*listenport[ \t]*$/ {gsub(/[ \t\r]/,"",$2); print $2; exit}' "$f")"
    if [ -n "$p" ]; then
      WG_PORTS+=("$p")
      info "WireGuard en écoute ($(basename "$f" .conf)) : UDP $p sera ouvert."
    fi
  done
}

detect_cluster() {
  [ -f /etc/pve/corosync.conf ] || return 0
  local a ip
  while read -r a; do
    ip="$(getent ahostsv4 "$a" 2>/dev/null | awk 'NR==1{print $1}' || true)"
    if [ -n "$ip" ]; then CLUSTER_IPS+=("$ip"); fi
  done < <(awk '/ring[0-9]+_addr/ {print $2}' /etc/pve/corosync.conf | sort -u)
  if [ "${#CLUSTER_IPS[@]}" -gt 0 ]; then
    info "Cluster Proxmox détecté : tout le trafic des nœuds sera accepté (${CLUSTER_IPS[*]})."
  fi
}

detect_forward() {
  # Le tuto bloque FORWARD. Sur Proxmox, c'est sans risque SAUF si le trafic des VM
  # passe par iptables : bridge-netfilter actif ou hôte qui route/NAT pour les VM.
  local brnf=/proc/sys/net/bridge/bridge-nf-call-iptables
  if [ -r "$brnf" ] && [ "$(cat "$brnf")" = 1 ]; then
    FORWARD_DROP=0; FORWARD_REASON="bridge-netfilter actif (le trafic des VM passe par iptables)"
  elif [ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo 0)" = 1 ]; then
    FORWARD_DROP=0; FORWARD_REASON="routage IPv4 activé (l'hôte route/NAT pour des VM)"
  fi
}

check_f2b_api() {
  [ -n "$PROXY_IP" ] || return 0
  local code
  # L'API PHP du tuto répond 400 sur "/" (pas d'action) : c'est notre signe de vie.
  code="$(curl -s -o /dev/null -m 5 -w '%{http_code}' "http://$PROXY_IP:8080/" 2>/dev/null || true)"
  if [ "$code" = 400 ]; then F2B_API_FOUND=1; fi

  if [ "$USE_F2B_API" -eq 1 ] && [ "$F2B_API_FOUND" -eq 0 ]; then
    warn "--f2b-api : pas de réponse de l'API sur http://$PROXY_IP:8080 (code '$code')."
    if ask "Activer quand même l'action f2b-api ?" n; then :; else
      USE_F2B_API=0
      info "Bannissement web via iptables local à la place (peu utile derrière le proxy)."
    fi
  elif [ "$USE_F2B_API" -eq 0 ] && [ "$F2B_API_FOUND" -eq 1 ]; then
    info "L'API fail2ban du proxy répond sur http://$PROXY_IP:8080."
    if ask "Bannir les attaques web via cette API (seul vrai blocage derrière le proxy) ?" n; then
      USE_F2B_API=1
    fi
  fi
}

# ================================================================ Conflits
check_conflicts() {
  step "Vérification des pare-feu déjà présents"
  if pve-firewall status 2>/dev/null | grep -qi 'status: enabled'; then
    warn "Le pare-feu intégré de Proxmox (pve-firewall) est actif : il gère lui-même iptables"
    warn "et va écraser ou contredire ces règles."
    ask "Continuer quand même ?" n \
      || die "Arrêt. Désactive-le (Datacenter → Firewall → Options → Firewall : No) puis relance."
  else
    ok "pve-firewall désactivé : pas de conflit."
  fi
}

disable_nftables() {
  # nftables.service fait un "flush ruleset" au démarrage et effacerait nos règles
  if systemctl is-enabled nftables >/dev/null 2>&1; then
    systemctl disable nftables >/dev/null 2>&1 || true
    ok "Service nftables désactivé (il effaçait les règles au démarrage)."
  fi
}

# ================================================================ Paquets
install_packages() {
  step "Installation des paquets"
  export DEBIAN_FRONTEND=noninteractive
  echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections
  echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" | debconf-set-selections
  if ! apt-get update -qq; then
    warn "apt-get update a renvoyé une erreur (dépôt enterprise sans abonnement ?). On continue."
  fi
  apt-get -y -qq install iptables iptables-persistent fail2ban python3-systemd curl >/dev/null \
    || die "Installation impossible. Vérifie les dépôts (pve-no-subscription) puis relance."
  ok "iptables, iptables-persistent et fail2ban installés."
}

# ================================================================ Règles iptables
stop_fail2ban() {
  # fail2ban arrêté pendant l'opération : ses chaînes f2b-* ne doivent pas finir
  # dans la sauvegarde (sinon doublons au redémarrage)
  if systemctl is-active --quiet fail2ban; then
    F2B_WAS_ACTIVE=1
    systemctl stop fail2ban
    info "fail2ban arrêté le temps de poser les règles."
  fi
}

backup_rules() {
  mkdir -p "$BACKUP_DIR"
  chmod 700 "$BACKUP_DIR"
  iptables-save > "$BACKUP_DIR/rules.v4.avant"
  if [ "$HAS_IPV6" -eq 1 ]; then ip6tables-save > "$BACKUP_DIR/rules.v6.avant"; fi
  if [ "$F2B_WAS_ACTIVE" -eq 1 ]; then touch "$BACKUP_DIR/fail2ban.actif"; fi

  # On ouvre tout PUIS on recharge l'ancien état (une sauvegarde vide ne suffirait pas)
  cat > "$BACKUP_DIR/restore.sh" <<EOF
#!/bin/bash
# Restaure les règles iptables d'avant proxmox/secure
systemctl stop fail2ban 2>/dev/null || true
iptables -P INPUT ACCEPT; iptables -P FORWARD ACCEPT; iptables -P OUTPUT ACCEPT
iptables -F; iptables -X
iptables-restore < '$BACKUP_DIR/rules.v4.avant'
if [ -f '$BACKUP_DIR/rules.v6.avant' ]; then
  ip6tables -P INPUT ACCEPT; ip6tables -P FORWARD ACCEPT; ip6tables -P OUTPUT ACCEPT
  ip6tables -F; ip6tables -X
  ip6tables-restore < '$BACKUP_DIR/rules.v6.avant'
fi
if [ -f '$BACKUP_DIR/fail2ban.actif' ]; then systemctl start fail2ban; fi
EOF
  chmod 700 "$BACKUP_DIR/restore.sh"
  ok "Règles actuelles sauvegardées dans $BACKUP_DIR"
}

start_rollback() {
  # Minuterie systemd : indépendante de la session (SSH coupé, onglet fermé...)
  systemctl stop "$ROLLBACK_UNIT.timer" >/dev/null 2>&1 || true
  systemctl reset-failed "$ROLLBACK_UNIT.service" >/dev/null 2>&1 || true
  systemd-run --quiet --unit="$ROLLBACK_UNIT" --on-active="${ROLLBACK_DELAY}s" \
    /bin/bash "$BACKUP_DIR/restore.sh" \
    || die "Impossible de programmer le retour arrière automatique : arrêt par sécurité."
  ROLLBACK_ON=1
  info "Retour arrière automatique programmé dans ${ROLLBACK_DELAY} s."
}

cancel_rollback() {
  [ "$ROLLBACK_ON" -eq 1 ] || return 0
  systemctl stop "$ROLLBACK_UNIT.timer" >/dev/null 2>&1 || true
  systemctl reset-failed "$ROLLBACK_UNIT.service" >/dev/null 2>&1 || true
  ROLLBACK_ON=0
  ok "Retour arrière automatique annulé."
}

apply_rules() {
  step "Application des règles iptables (IPv4) — management : $MGMT_IFACE"
  local p ifc ip

  # On repart de zéro pour que le script soit relançable sans doublons
  iptables -P INPUT ACCEPT
  iptables -P FORWARD ACCEPT
  iptables -F INPUT
  iptables -F FORWARD

  # Sessions déjà démarrées : sur TOUTES les interfaces (le tuto met -i vmbr0, mais
  # les réponses à un tunnel WireGuard sortant, à apt ou au DNS peuvent revenir ailleurs)
  iptables -A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
  iptables -A INPUT -i lo -j ACCEPT
  iptables -A INPUT -i "$MGMT_IFACE" -p icmp -j ACCEPT
  iptables -A INPUT -i "$MGMT_IFACE" -p tcp -m state --state NEW -m tcp --dport 8006 -j ACCEPT
  iptables -A INPUT -i "$MGMT_IFACE" -p tcp -m state --state NEW -m tcp --dport "$SSH_PORT" -j ACCEPT
  for p in "${EXTRA_PORTS[@]}"; do
    iptables -A INPUT -i "$MGMT_IFACE" -p tcp -m state --state NEW -m tcp --dport "$p" -j ACCEPT
  done
  for p in "${WG_PORTS[@]}"; do
    iptables -A INPUT -i "$MGMT_IFACE" -p udp --dport "$p" -j ACCEPT
  done

  for ifc in "${ALLOW_IFACES[@]}"; do
    iptables -A INPUT -i "$ifc" -p icmp -j ACCEPT
    iptables -A INPUT -i "$ifc" -p tcp -m state --state NEW -m tcp --dport 8006 -j ACCEPT
    iptables -A INPUT -i "$ifc" -p tcp -m state --state NEW -m tcp --dport "$SSH_PORT" -j ACCEPT
  done

  for ip in "${CLUSTER_IPS[@]}"; do
    iptables -A INPUT -s "$ip" -j ACCEPT
  done

  iptables -A INPUT -j DROP

  if [ "$FORWARD_DROP" -eq 1 ]; then
    iptables -A FORWARD -j DROP
    ok "FORWARD bloqué (comme dans le tuto)."
  else
    warn "FORWARD laissé ouvert : $FORWARD_REASON."
  fi
  ok "Règles IPv4 appliquées."

  if [ "$HAS_IPV6" -eq 0 ]; then
    info "IPv6 désactivé sur cette machine : rien à faire."
  elif [ "$BLOCK_V6" -eq 0 ]; then
    info "IPv6 non bloqué."
  else
    step "Blocage d'IPv6"
    ip6tables -P INPUT ACCEPT; ip6tables -P FORWARD ACCEPT; ip6tables -P OUTPUT ACCEPT
    ip6tables -F INPUT; ip6tables -F FORWARD; ip6tables -F OUTPUT
    # Boucle locale ::1 laissée ouverte : des services Proxmox l'utilisent en interne
    ip6tables -A INPUT -i lo -j ACCEPT
    ip6tables -A OUTPUT -o lo -j ACCEPT
    ip6tables -P INPUT DROP
    ip6tables -P FORWARD DROP
    ip6tables -P OUTPUT DROP
    ok "IPv6 bloqué (sauf ::1)."
  fi
}

decide_ipv6() {
  if [ "$HAS_IPV6" -eq 0 ] || [ "$KEEP_IPV6" -eq 1 ]; then BLOCK_V6=0; return 0; fi
  if [ "$HAS_V6_GLOBAL" -eq 1 ]; then
    warn "Cet hôte a une adresse IPv6 publique/globale : bloquer IPv6 peut couper un accès."
    if ask "Bloquer IPv6 quand même (comme le tuto) ?" n; then BLOCK_V6=1; else BLOCK_V6=0; fi
  else
    BLOCK_V6=1
  fi
}

confirm_access() {
  [ "$ROLLBACK_ON" -eq 1 ] || return 0

  printf '\n%s' "$C_B"
  echo "┌──────────────────────────────────────────────────────────────┐"
  echo "│  TESTE MAINTENANT, SANS FERMER CETTE FENÊTRE :               │"
  echo "│   - une NOUVELLE connexion SSH                               │"
  echo "│   - un NOUVEL onglet de l'interface web (via le proxy)       │"
  echo "│   - si tu as des VM : un ping depuis une VM                  │"
  echo "│  Si tout marche, tape 'oui'. Sinon, ne fais rien : les       │"
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
    die "Anciennes règles restaurées. Rien n'a été sauvegardé. Vérifie --iface / --allow-iface et relance."
  fi
}

save_rules() {
  step "Sauvegarde des règles (persistance au redémarrage)"
  mkdir -p /etc/iptables
  iptables-save > /etc/iptables/rules.v4
  if [ "$HAS_IPV6" -eq 1 ]; then ip6tables-save > /etc/iptables/rules.v6; fi
  systemctl enable netfilter-persistent >/dev/null 2>&1
  ok "Règles enregistrées dans /etc/iptables/ (netfilter-persistent activé)."
}

# ================================================================ Correctif reverse-proxy
install_fix_script() {
  # Script autonome : réutilisé par le hook apt après chaque mise à jour de Proxmox
  cat > "$FIX_SCRIPT" <<'FIXSCRIPT'
#!/bin/bash
# Généré par get.andries.icu/proxmox/secure — d'après tala-informatique.fr (Proxmox_fail2ban)
#
# Proxmox derrière un reverse-proxy : pveproxy ne voit que l'IP du proxy, donc fail2ban
# aussi. Ce script patche AnyEvent.pm pour remplacer l'IP du proxy par celle du client
# (en-tête X-Forwarded-For / X-Real-IP), UNIQUEMENT pour les requêtes venant du proxy.
# Le fichier est écrasé à chaque mise à jour de libpve-http-server-perl : un hook apt
# relance ce script automatiquement.
#
# Usage : pve-remoteip-fix [--quiet] [--force-reload]
set -u
PROXY_IP="__PROXY_IP__"
FILE=/usr/share/perl5/PVE/APIServer/AnyEvent.pm
MARK_START='### BUGFIX REMOTE_IP FOR FAIL2BAN ###'
MARK_END='### FIN BUGFIX REMOTE_IP ###'
QUIET=0; FORCE_RELOAD=0
for a in "$@"; do
  case "$a" in
    -q|--quiet)     QUIET=1 ;;
    --force-reload) FORCE_RELOAD=1 ;;
  esac
done
say() { if [ "$QUIET" -eq 0 ]; then echo "[pve-remoteip-fix] $*"; fi; }

reload_pveproxy() {
  # reload = redémarrage en douceur (comme lors des mises à jour Proxmox)
  systemctl reload-or-restart pveproxy || return 1
  sleep 3
  systemctl is-active --quiet pveproxy
}

[ -f "$FILE" ] || { say "$FILE introuvable."; exit 1; }

if grep -qF "$MARK_START" "$FILE" && grep -qF "'$PROXY_IP'" "$FILE"; then
  say "AnyEvent.pm déjà patché pour $PROXY_IP."
  if [ "$FORCE_RELOAD" -eq 1 ]; then
    reload_pveproxy || { say "pveproxy ne redémarre pas !"; exit 1; }
  fi
  exit 0
fi

BASE="$(mktemp)"; TMP="$(mktemp)"
trap 'rm -f "$BASE" "$TMP"' EXIT

# Fichier sans un éventuel ancien bloc (autre IP de proxy)
awk -v s="$MARK_START" -v e="$MARK_END" \
  'index($0,s){skip=1} !skip{print} index($0,e){skip=0}' "$FILE" > "$BASE"

# Point d'insertion du tuto : juste avant "if ($self->{spiceproxy})"
# dans la fonction authenticate_and_handle_request
LINE="$(awk '/^sub authenticate_and_handle_request/{insub=1}
             insub && index($0, "$self->{spiceproxy}") {print NR; exit}' "$BASE")"
if [ -z "$LINE" ]; then
  say "Point d'insertion introuvable (version de Proxmox différente ?). Rien n'a été modifié."
  exit 1
fi

{
  head -n "$((LINE - 1))" "$BASE"
  cat <<'PERL'
    ### BUGFIX REMOTE_IP FOR FAIL2BAN ###
    # Ajouté par pve-remoteip-fix (get.andries.icu/proxmox/secure), d'après tala-informatique.fr
    # On ne croit les en-têtes QUE si la requête vient du reverse-proxy de confiance.
    {
        my $f2b_peer = $reqstate->{peer_host} // '';
        $f2b_peer =~ s/^::ffff://i;
        if ($f2b_peer eq '__PROXY_IP__') {
            my $f2b_hdr = $request->header('X-Forwarded-For') // $request->header('X-Real-IP') // '';
            # "a, b, c" : la DERNIÈRE adresse est celle ajoutée par le proxy (les autres
            # peuvent être inventées par le client) ; règle aussi le cas "a, a" du tuto
            my @f2b_ips = grep { length } map { s/^\s+|\s+$//gr } split(/,/, $f2b_hdr);
            if (@f2b_ips) {
                my $f2b_ip = $f2b_ips[-1];
                $f2b_ip =~ s/^::ffff://i;
                $reqstate->{peer_host} = $f2b_ip;
            }
        }
    }
    ### FIN BUGFIX REMOTE_IP ###
PERL
  tail -n +"$LINE" "$BASE"
} > "$TMP"

if ! perl -c "$TMP" >/dev/null 2>&1; then
  say "Erreur de syntaxe Perl après patch : rien n'a été modifié."
  exit 1
fi

cp "$BASE" "$FILE.ori"     # version d'origine, sans patch
cat "$TMP" > "$FILE"       # 'cat >' garde les droits du fichier

if ! reload_pveproxy; then
  say "pveproxy ne redémarre pas : remise du fichier d'origine."
  cat "$FILE.ori" > "$FILE"
  systemctl restart pveproxy || true
  exit 1
fi
say "Correctif appliqué (proxy de confiance : $PROXY_IP)."
FIXSCRIPT
  sed -i "s/__PROXY_IP__/$PROXY_IP/g" "$FIX_SCRIPT"
  chmod 755 "$FIX_SCRIPT"
}

setup_proxy_fix() {
  [ -n "$PROXY_IP" ] || return 0
  step "Correctif reverse-proxy (proxy : $PROXY_IP)"

  # 1) /etc/default/pveproxy (méthode officielle, ne suffit plus seule d'après le tuto)
  if [ -f /etc/default/pveproxy ]; then cp /etc/default/pveproxy "$BACKUP_DIR/pveproxy.avant"; fi
  touch /etc/default/pveproxy
  sed -i '/^PROXY_REAL_IP_/d; /# proxmox\/secure/d' /etc/default/pveproxy
  cat >> /etc/default/pveproxy <<EOF
# proxmox/secure : IP réelle du client derrière le reverse-proxy de l'école
PROXY_REAL_IP_HEADER="X-Forwarded-For"
PROXY_REAL_IP_ALLOW_FROM="$PROXY_IP"
EOF
  ok "/etc/default/pveproxy configuré."

  # 2) patch AnyEvent.pm
  install_fix_script
  if "$FIX_SCRIPT" --force-reload; then
    ok "AnyEvent.pm patché, pveproxy rechargé."
  else
    warn "Le patch AnyEvent.pm a échoué : les logs montreront l'IP du proxy."
    warn "Le proxy reste ignoré par fail2ban, donc pas de risque de blocage."
  fi

  # 3) réapplication automatique après chaque mise à jour
  cat > "$APT_HOOK" <<EOF
// proxmox/secure : réapplique le correctif IP réelle après les mises à jour de Proxmox
DPkg::Post-Invoke { "if [ -x $FIX_SCRIPT ]; then $FIX_SCRIPT --quiet || true; fi"; };
EOF
  ok "Hook apt installé : le patch revient tout seul après un 'apt upgrade'."
}

# ================================================================ Fail2ban
configure_fail2ban() {
  step "Configuration de fail2ban"
  local ignore="127.0.0.1/8 ::1" ip

  if [ -n "$PROXY_IP" ]; then ignore="$ignore $PROXY_IP"; fi
  if [ -n "$SSH_CLIENT_IP" ]; then ignore="$ignore $SSH_CLIENT_IP"; fi
  for ip in "${IGNORE_IPS[@]}"; do ignore="$ignore $ip"; done

  if [ -f /etc/fail2ban/jail.local ]; then cp /etc/fail2ban/jail.local "$BACKUP_DIR/jail.local.avant"; fi

  # Le tuto copie jail.conf en jail.local puis modifie quelques valeurs : on écrit
  # directement ces valeurs (même résultat, fichier lisible)
  cat > /etc/fail2ban/jail.local <<EOF
# Généré par get.andries.icu/proxmox/secure — d'après tala-informatique.fr
[DEFAULT]
# IP jamais bannies : machine elle-même, reverse-proxy de l'école, ta session SSH, --ignore
ignoreip  = $ignore
# 3 essais ratés sur 1 jour = banni 1 semaine
maxretry  = 3
findtime  = 86400
bantime   = 604800
# Proxmox n'a pas de /var/log/auth.log : lecture via le journal systemd
backend   = systemd
banaction = iptables-multiport
banaction_allports = iptables-allports

[sshd]
enabled = true
port    = $SSH_PORT
backend = systemd
EOF

  # Jail de l'interface web (tuto : /etc/fail2ban/jail.d/proxmox.conf)
  {
    echo "# Généré par get.andries.icu/proxmox/secure — d'après tala-informatique.fr"
    echo "[proxmox]"
    echo "enabled  = true"
    echo "port     = https,http,8006"
    echo "filter   = proxmox"
    echo "backend  = systemd"
    echo "maxretry = 5"
    echo "findtime = 1d"
    echo "bantime  = 1w"
    if [ "$USE_F2B_API" -eq 1 ]; then echo "banaction = f2b-api"; fi
  } > /etc/fail2ban/jail.d/proxmox.conf

  # Filtre : accepte "authentication failure" (tuto) et "authentication verification
  # failure" (Proxmox récents), ainsi que "::ffff:IP" et "IP, IP" (section nettoyage du tuto)
  cat > /etc/fail2ban/filter.d/proxmox.conf <<'EOF'
# Généré par get.andries.icu/proxmox/secure — d'après tala-informatique.fr
[Definition]
failregex = pvedaemon\[\d+\]: authentication (?:verification )?failure; rhost=(?:::ffff:)?<HOST>,?\s.*?user=.* msg=.*
ignoreregex =
journalmatch = _SYSTEMD_UNIT=pvedaemon.service
EOF

  if [ "$USE_F2B_API" -eq 1 ]; then
    cat > /etc/fail2ban/action.d/f2b-api.conf <<EOF
# Généré par get.andries.icu/proxmox/secure — d'après tala-informatique.fr
# Bannissement sur le reverse-proxy (seul endroit où bloquer derrière le proxy)
[Definition]
actionstart =
actionstop =
actioncheck =
actionban = curl -fsS -m 5 -X GET http://$PROXY_IP:8080/ban/<ip>
actionunban = curl -fsS -m 5 -X GET http://$PROXY_IP:8080/unban/<ip>
EOF
    ok "Action f2b-api créée (bans web envoyés à $PROXY_IP:8080)."
  fi

  # Supprime l'avertissement "allowipv6 not defined" des versions récentes
  if [ ! -f /etc/fail2ban/fail2ban.local ]; then
    printf '[Definition]\nallowipv6 = auto\n' > /etc/fail2ban/fail2ban.local
  fi

  fail2ban-client -t >/dev/null 2>&1 || die "Configuration fail2ban invalide (voir : fail2ban-client -t)."
  systemctl enable fail2ban >/dev/null 2>&1
  systemctl restart fail2ban
  sleep 2
  ok "fail2ban actif : $(fail2ban-client status | awk -F':' '/Jail list/ {gsub(/^[ \t]+/,"",$2); print $2}')"
}

# ================================================================ Résumé
summary() {
  local ports="$SSH_PORT (SSH), 8006 (web)"
  if [ "${#EXTRA_PORTS[@]}" -gt 0 ]; then ports="$ports, ${EXTRA_PORTS[*]}"; fi
  if [ "${#WG_PORTS[@]}" -gt 0 ]; then ports="$ports, UDP ${WG_PORTS[*]} (WireGuard)"; fi

  step "Terminé"
  echo "  Proxmox VE      : ${PVE_VERSION:-?}"
  echo "  Management      : $MGMT_IFACE — $ports + ping"
  if [ "${#ALLOW_IFACES[@]}" -gt 0 ]; then
    echo "  Aussi autorisé  : ${ALLOW_IFACES[*]} (SSH, 8006, ping)"
  fi
  echo "  FORWARD         : $([ "$FORWARD_DROP" -eq 1 ] && echo "bloqué" || echo "ouvert ($FORWARD_REASON)")"
  echo "  IPv6            : $([ "$BLOCK_V6" -eq 1 ] && echo "bloqué" || echo "non bloqué")"
  if [ -n "$PROXY_IP" ]; then
    echo "  Reverse-proxy   : $PROXY_IP (jamais banni, IP réelle via AnyEvent.pm)"
    echo "  Bans web        : $([ "$USE_F2B_API" -eq 1 ] && echo "via l'API du proxy" || echo "iptables local (inefficace derrière le proxy)")"
  fi
  echo "  fail2ban        : sshd 3 essais / 1 j, proxmox 5 essais / 1 j → banni 1 semaine"
  echo "  Sauvegarde      : $BACKUP_DIR"
  echo
  echo "  Vérifier :"
  echo "    iptables -nvL INPUT"
  echo "    fail2ban-client status sshd"
  echo "    fail2ban-client status proxmox"
  if [ -n "$PROXY_IP" ]; then
    echo "    tail -f /var/log/pveproxy/access.log      # doit montrer l'IP du client, pas $PROXY_IP"
  fi
  echo "  Débannir une IP :"
  echo "    fail2ban-client unban <IP>"
  echo "  Tout annuler :"
  echo "    bash $BACKUP_DIR/restore.sh                       # règles iptables"
  echo "    rm -f $APT_HOOK $FIX_SCRIPT"
  echo "    apt install --reinstall libpve-http-server-perl   # AnyEvent.pm d'origine"
}

# ================================================================ Main
main() {
  parse_args "$@"
  printf '%s=== proxmox/secure — get.andries.icu ===%s\n' "$C_B" "$C_R"
  [ "$(id -u)" -eq 0 ] || die "À lancer en root."

  step "Détection"
  require_pve
  detect_ssh
  detect_ifaces
  detect_wireguard
  detect_cluster
  detect_forward
  ok "Interface de management : $MGMT_IFACE"
  ok "Port SSH : $SSH_PORT"
  if [ -n "$SSH_CLIENT_IP" ]; then
    ok "Ta session SSH vient de $SSH_CLIENT_IP (ne sera pas bannie)."
  else
    info "Pas de session SSH détectée (shell web Proxmox ?)."
  fi
  if [ -n "$PROXY_IP" ]; then
    ok "Reverse-proxy : $PROXY_IP (ne sera jamais banni)."
  else
    info "Mode sans reverse-proxy (--no-proxy)."
  fi

  check_conflicts
  check_f2b_api
  decide_ipv6

  echo
  warn "Ce script REMPLACE les règles INPUT/FORWARD actuelles (une sauvegarde est faite)."
  ask "Continuer avec l'interface de management '$MGMT_IFACE' ?" y \
    || die "Arrêt demandé. Choisis l'interface avec --iface <nom>."

  install_packages
  disable_nftables
  stop_fail2ban
  backup_rules
  if [ "$ASSUME_YES" -eq 0 ] && has_tty; then start_rollback; fi
  apply_rules
  confirm_access
  save_rules
  setup_proxy_fix
  configure_fail2ban
  summary
}

# Dernière ligne : si le téléchargement est coupé, rien ne s'exécute
main "$@"