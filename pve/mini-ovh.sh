#!/bin/bash
# DESC: Mini OVH Proxmox : conteneurs Rocky Linux 9 d'hébergement pour les élèves (httpd, SSH root, iptables + fail2ban)
#
# Usage (root sur l'hôte Proxmox, dans un terminal) :
#   curl -fsSL https://get.andries.icu/pve/mini-ovh | bash
#
# CT 501 → IP 10.10.10.101, SSH sur IP_hôte:2501, site sur IP_hôte:8501
set -euo pipefail

BR=vmbr10
ROLE=BTS-Etudiant
HOOK=/var/lib/vz/snippets/mini-ovh-hook.sh
CRED=/root/mini-ovh
SECURE=https://get.andries.icu/linux/secure

die()  { echo "ERREUR : $*" >&2; exit 1; }
ask()  { local r; read -r -p "$1" r </dev/tty; echo "$r"; }
pass() { openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | cut -c1-16; }
slug() {
  echo "$1" | LC_ALL=C.UTF-8 sed 'y/àâäéèêëîïôöùûüçÀÂÄÉÈÊËÎÏÔÖÙÛÜÇ/aaaeeeeiioouuucAAAEEEEIIOOUUUC/' \
    | tr 'A-Z' 'a-z' | sed 's/[^a-z0-9]\+/-/g; s/^-//; s/-$//'
}

# CT d'un élève = CT portant les tags "miniovh" et "<identifiant>"
user_cts() {
  local f tags
  for f in /etc/pve/lxc/*.conf; do
    [ -e "$f" ] || continue
    tags="$(sed -n 's/^tags: //p' "$f" | tr ';' '\n')"
    grep -qx miniovh <<<"$tags" && grep -qx "$1" <<<"$tags" && basename "$f" .conf
  done
  return 0
}

# ============================================================ Préparation de l'hôte
setup() {
  [ "$(id -u)" = 0 ] && command -v pct >/dev/null || die "à lancer en root sur un hôte Proxmox"
  { : </dev/tty; } 2>/dev/null || die "terminal interactif requis (le menu lit le clavier)"
  mkdir -p "$CRED"; chmod 700 "$CRED"
  ARCH="$(dpkg --print-architecture)"
  WAN="$(ip route show default | awk '{print $5; exit}')"
  HOST="$(ip -4 -o addr show "$WAN" | awk '{print $4}' | cut -d/ -f1 | head -n 1)"

  # Bridge des conteneurs (sans port physique, NAT par l'hôte)
  if ! grep -q "iface $BR" /etc/network/interfaces; then
    [ -f /etc/network/interfaces.new ] && die "changements réseau en attente dans l'interface web : applique-les d'abord"
    printf '\nauto %s\niface %s inet static\n\taddress 10.10.10.1/24\n\tbridge-ports none\n\tbridge-stp off\n\tbridge-fd 0\n' "$BR" "$BR" >> /etc/network/interfaces
    ifup "$BR"
  fi
  echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-mini-ovh.conf
  sysctl -qw net.ipv4.ip_forward=1

  # Modules dont iptables a besoin DANS les CT (un CT non privilégié ne peut pas les charger)
  for m in nf_tables nft_compat xt_state xt_conntrack xt_tcpudp xt_multiport ipt_REJECT ip6t_REJECT ip6_tables; do
    modprobe -q "$m" && echo "$m" || true
  done > /etc/modules-load.d/mini-ovh.conf

  # Hookscript : isolement + redirections, exécuté par Proxmox à chaque démarrage/arrêt d'un CT
  grep -A5 '^dir: local$' /etc/pve/storage.cfg | grep -q 'content.*snippets' \
    || pvesm set local --content "$(awk '/^dir: local$/{f=1} f&&/content/{print $2; exit}' /etc/pve/storage.cfg),snippets"
  mkdir -p "$(dirname "$HOOK")"
  cat > "$HOOK" <<'EOF'
#!/bin/bash
id=$1; phase=$2; BR=vmbr10
WAN=$(ip route show default | awk '{print $5; exit}')
ip=10.10.10.$((id - 400)); ssh=$((2000 + id)); http=$((8000 + id))
nat() { iptables -t nat "$1" PREROUTING -i "$WAN" -m addrtype --dst-type LOCAL -p tcp --dport "$2" -j DNAT --to-destination "$3"; }

case $phase in
  post-start)
    # Le CT ne peut parler qu'à l'hôte, jamais aux autres CT (sinon on coupe son réseau)
    bridge link set dev "veth${id}i0" isolated on || ip link set "veth${id}i0" down

    # Internet oui, réseaux locaux et hôte non (règles recréées à chaque démarrage)
    iptables -N OVH-FWD 2>/dev/null || iptables -F OVH-FWD
    iptables -N OVH-IN  2>/dev/null || iptables -F OVH-IN
    iptables -A OVH-FWD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    iptables -A OVH-FWD -o $BR -m conntrack --ctstate DNAT -j ACCEPT
    iptables -A OVH-FWD -o $BR -j DROP
    for dns in $(awk '/^nameserver/ {print $2}' /etc/resolv.conf); do
      iptables -A OVH-FWD -i $BR -d "$dns" -p udp --dport 53 -j ACCEPT
    done
    iptables -A OVH-FWD -i $BR -d 10.0.0.0/8,172.16.0.0/12,192.168.0.0/16 -j DROP
    iptables -A OVH-FWD -i $BR -o "$WAN" -j ACCEPT
    iptables -A OVH-FWD -i $BR -j DROP
    iptables -A OVH-IN -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    iptables -A OVH-IN -p icmp -j ACCEPT
    iptables -A OVH-IN -j DROP
    iptables -C FORWARD -j OVH-FWD 2>/dev/null || iptables -I FORWARD -j OVH-FWD
    iptables -C INPUT -i $BR -j OVH-IN 2>/dev/null || iptables -I INPUT -i $BR -j OVH-IN
    iptables -t nat -C POSTROUTING -s 10.10.10.0/24 -o "$WAN" -j MASQUERADE 2>/dev/null \
      || iptables -t nat -A POSTROUTING -s 10.10.10.0/24 -o "$WAN" -j MASQUERADE

    # Redirections SSH et HTTP de ce CT
    nat -C "$ssh"  "$ip:22" 2>/dev/null || nat -A "$ssh"  "$ip:22"
    nat -C "$http" "$ip:80" 2>/dev/null || nat -A "$http" "$ip:80"
    ;;
  post-stop)
    nat -D "$ssh"  "$ip:22" 2>/dev/null
    nat -D "$http" "$ip:80" 2>/dev/null
    ;;
esac
exit 0
EOF
  chmod 755 "$HOOK"

  # Rôle Proxmox : voir, ouvrir la console, démarrer/arrêter. Rien d'autre.
  pveum role add "$ROLE" --privs VM.Audit,VM.Console,VM.PowerMgmt 2>/dev/null \
    || pveum role modify "$ROLE" --privs VM.Audit,VM.Console,VM.PowerMgmt

  # Stockage des disques
  STORE="$(pvesm status --content rootdir | awk 'NR>1 && $3=="active" {print $1}' | grep -m1 -E '^local-(lvm|zfs)$' || true)"
  [ -n "$STORE" ] || STORE="$(pvesm status --content rootdir | awk 'NR>1 && $3=="active" {print $1; exit}')"

  # Modèle Rocky 9 adapté au processeur (amd64 : Proxmox, arm64 : linuxcontainers.org)
  local cache=/var/lib/vz/template/cache url b
  TPL="$(cd "$cache" && compgen -G "rockylinux-9-*_${ARCH}.tar.xz" | sort | tail -n 1 || true)"
  if [ -z "$TPL" ]; then
    echo "Téléchargement de Rocky Linux 9 ($ARCH)..."
    if [ "$ARCH" = amd64 ]; then
      pveam update >/dev/null
      TPL="$(pveam available --section system | awk '/rockylinux-9/ {print $2}' | sort | tail -n 1)"
      pveam download local "$TPL" >/dev/null
    else
      url="https://images.linuxcontainers.org/images/rockylinux/9/$ARCH/default"
      b="$(curl -fsSL "$url/" | grep -oE '[0-9]{8}_[0-9]{2}:[0-9]{2}' | sort -u | tail -n 1)"
      TPL="rockylinux-9-default_${b%_*}_$ARCH.tar.xz"
      curl -fL -o "$cache/$TPL.part" "$url/$b/rootfs.tar.xz" && mv "$cache/$TPL.part" "$cache/$TPL"
    fi
  fi
  echo "Prêt : $HOST, $ARCH, disques sur $STORE, modèle $TPL"
}

# ============================================================ Installation dans le CT
ct_setup() {
  cat <<EOF
set -e
dnf -y -q upgrade
dnf -y -q install openssh-server httpd iptables-nft

printf 'PermitRootLogin yes\nPasswordAuthentication yes\n' > /etc/ssh/sshd_config.d/10-mini-ovh.conf
systemctl enable --now sshd

mkdir -p /opt/www
[ -e /opt/www/index.html ] || echo '<h1>Site de $LOGIN</h1>' > /opt/www/index.html
chown -R root:apache /opt/www
: > /etc/httpd/conf.d/welcome.conf
cat > /etc/httpd/conf.d/site.conf <<'VHOST'
<VirtualHost *:80>
    DocumentRoot /opt/www
    <Directory /opt/www>
        AllowOverride All
        Require all granted
    </Directory>
</VirtualHost>
VHOST
systemctl enable --now httpd

curl -fsSL $SECURE | bash -s -- --yes --iface eth0 --port 80 --ignore 10.10.10.1
curl -fsS -o /dev/null http://localhost && echo "curl http://localhost : OK"
EOF
}

# ============================================================ Actions
read_name() {
  local p n
  p="$(ask 'Prénom : ')"; n="$(ask 'Nom : ')"
  LOGIN="$(slug "$p").$(slug "$n")"
  [[ "$LOGIN" =~ ^[a-z0-9].*\.[a-z0-9] ]] || { echo "Prénom et nom obligatoires."; return 1; }
  FIRST="$p"; LAST="$n"
  echo "Identifiant : $LOGIN"
}

show() { echo "--------------------------------------------------"; cat "$CRED/$1"/*.txt; echo "--------------------------------------------------"; }

add() {
  read_name || return 0
  local id="" i ip pw dns tmp

  # Un seul mot de passe par élève : Proxmox + root de toutes ses machines
  mkdir -p "$CRED/$LOGIN"
  if [ -s "$CRED/$LOGIN/.password" ]; then
    pw="$(cat "$CRED/$LOGIN/.password")"
  else
    pw="$(pass)"
    echo "$pw" > "$CRED/$LOGIN/.password"; chmod 600 "$CRED/$LOGIN/.password"
  fi
  if pvesh get "/access/users/$LOGIN@pve" >/dev/null 2>&1; then
    echo "$LOGIN existe déjà : ajout d'une machine (même mot de passe)."
    pvesh set /access/password --userid "$LOGIN@pve" --password "$pw" >/dev/null 2>&1 \
      || echo "Attention : mot de passe Proxmox non mis à jour, fais : pveum passwd $LOGIN@pve"
  else
    pvesh create /access/users --userid "$LOGIN@pve" --password "$pw" --firstname "$FIRST" --lastname "$LAST" >/dev/null
  fi
  printf 'Proxmox : https://%s:8006\n  utilisateur : %s   (realm : Proxmox VE authentication server)\n  mot de passe : %s   (le même pour Proxmox et root sur toutes ses machines)\n' \
    "$HOST" "$LOGIN" "$pw" > "$CRED/$LOGIN/proxmox.txt"

  for i in $(seq 501 599); do pvesh get /cluster/nextid --vmid "$i" >/dev/null 2>&1 && { id=$i; break; }; done
  [ -n "$id" ] || die "plus d'ID libre entre 501 et 599"
  ip="10.10.10.$((id - 400))"
  dns="$(awk '/^nameserver/ && $2 !~ /^127|:/ {print $2}' /etc/resolv.conf | xargs)"

  echo "Création du CT $id ($ip)..."
  pct create "$id" "local:vztmpl/$TPL" --arch "$ARCH" --hostname "${LOGIN//./-}-$id" \
    --cores 1 --memory 1024 --swap 0 --rootfs "$STORE:10" \
    --unprivileged 1 --features nesting=1 --onboot 1 \
    --net0 "name=eth0,bridge=$BR,ip=$ip/24,gw=10.10.10.1" --nameserver "${dns:-1.1.1.1}" \
    --password "$pw" --tags "miniovh;$LOGIN" --hookscript local:snippets/mini-ovh-hook.sh >/dev/null
  pveum acl modify "/vms/$id" --users "$LOGIN@pve" --roles "$ROLE"
  pct start "$id"

  echo "Attente du réseau..."
  for _ in $(seq 30); do pct exec "$id" -- getent hosts rockylinux.org </dev/null >/dev/null 2>&1 && break; sleep 2; done

  echo "Installation (quelques minutes)..."
  tmp="$(mktemp)"; ct_setup > "$tmp"
  pct push "$id" "$tmp" /root/setup.sh; rm -f "$tmp"
  pct exec "$id" -- env -u SSH_CONNECTION -u SSH_CLIENT -u SSH_TTY bash /root/setup.sh </dev/null \
    || die "installation échouée dans le CT $id (diagnostic : pct enter $id)"
  pct exec "$id" -- rm -f /root/setup.sh </dev/null

  printf '\nCT %s\n  SSH : ssh -p %s root@%s\n  site : http://%s:%s   (fichiers dans /opt/www)\n' \
    "$id" "$((2000 + id))" "$HOST" "$HOST" "$((8000 + id))" > "$CRED/$LOGIN/ct-$id.txt"
  show "$LOGIN"
}

rm_ct() {
  pct stop "$1" >/dev/null 2>&1 || true
  pct destroy "$1" --purge 1 >/dev/null
  rm -f "$CRED"/*/"ct-$1.txt"
  echo "CT $1 supprimé."
}

del() {
  read_name || return 0
  local cts c id
  cts="$(user_cts "$LOGIN")"
  echo "Machines de $LOGIN : $(echo ${cts:-aucune})"
  c="$(ask 'Numéro du CT à supprimer, T = tout (machines + compte), Entrée = retour : ')"
  case "$c" in
    "") ;;
    T|t)
      for id in $cts; do rm_ct "$id"; done
      pveum user delete "$LOGIN@pve" 2>/dev/null || true
      rm -rf "${CRED:?}/$LOGIN"
      echo "$LOGIN supprimé." ;;
    *)
      grep -qx "$c" <<<"$cts" && rm_ct "$c" || echo "CT $c introuvable pour $LOGIN." ;;
  esac
}

list() {
  local d id n=0 c
  local -a users=()
  for d in "$CRED"/*/; do
    [ -d "$d" ] || continue
    users+=("$(basename "$d")"); n=$((n + 1))
    echo "$n) ${users[-1]}"
    for id in $(user_cts "${users[-1]}"); do
      echo "     CT $id  10.10.10.$((id - 400))  SSH:$((2000 + id))  HTTP:$((8000 + id))  $(pct status "$id" | cut -d' ' -f2)"
    done
  done
  [ "$n" -gt 0 ] || { echo "(aucun utilisateur)"; return 0; }
  c="$(ask 'Numéro pour afficher ses accès (Entrée = retour) : ')"
  [[ "$c" =~ ^[0-9]+$ ]] && [ "$c" -ge 1 ] && [ "$c" -le "$n" ] && show "${users[$((c - 1))]}"
  return 0
}

# ============================================================ Menu
main() {
  setup
  while true; do
    echo
    echo "1) Ajouter   2) Supprimer   3) Liste   0) Quitter"
    case "$(ask 'Choix : ')" in
      1) add ;;
      2) del ;;
      3) list ;;
      0) exit 0 ;;
    esac
  done
}

# Dernière ligne : si le téléchargement est coupé, rien ne s'exécute
main "$@"