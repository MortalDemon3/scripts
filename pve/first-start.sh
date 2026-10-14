#!/bin/bash
# DESC: Première config Proxmox 9 (dépôts gratuits, MAJ, abonnement, cartes réseau, alias, pare-feu)
# D'après tala-informatique.fr (Proxmox_first_start + Proxmox_iptables)
#
# Usage : curl -fsSL https://get.andries.icu/pve/first-start | bash
set -euo pipefail

# Questions au clavier : on lit /dev/tty, car avec "curl | bash"
# l'entrée standard contient le script lui-même
demander() {
  local reponse=""
  read -r -p "$1 " reponse < /dev/tty || true
  printf '%s' "$reponse"
}

main() {
  [ "$(id -u)" -eq 0 ] || { echo "À lancer en root."; exit 1; }
  command -v pveversion >/dev/null || { echo "Proxmox non détecté."; exit 1; }

  # ------------------------------------------------------------ Dépôts
  echo "==> Dépôts : désactivation des dépôts payants"
  local f
  for f in /etc/apt/sources.list.d/pve-enterprise.sources /etc/apt/sources.list.d/ceph.sources; do
    [ -f "$f" ] || continue
    cp -n "$f" "$f.bak"
    if grep -qi '^Enabled:' "$f"; then
      sed -i 's/^Enabled:.*/Enabled: false/I' "$f"
    else
      sed -i '/^Types:/a Enabled: false' "$f"
    fi
  done

  echo "==> Dépôts : ajout du dépôt gratuit"
  cat > /etc/apt/sources.list.d/proxmox.sources <<'EOF'
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
Enabled: true
EOF

  # ------------------------------------------------------------ Mise à jour
  echo "==> Mise à jour"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get -y full-upgrade

  # ------------------------------------------------------------ Abonnement
  echo "==> Suppression du message d'abonnement"
  local deb=/tmp/pve-fake-subscription.deb
  curl -fsSL -o "$deb" \
    "https://github.com/Jamesits/pve-fake-subscription/releases/download/v0.0.11/pve-fake-subscription_0.0.11+git-1_all.deb"
  dpkg -i "$deb"
  rm -f "$deb"
  grep -q 'shop.maurer-it.com' /etc/hosts || echo "127.0.0.1 shop.maurer-it.com" >> /etc/hosts

  # ------------------------------------------------------------ Cartes réseau
  # Méthode actuelle (fichiers .link de systemd) : la règle udev KERNEL=="eth*"
  # ne marche plus avec les noms modernes (enp3s0, eno1...)
  echo "==> Nommage des cartes réseau (Entrée = ne pas renommer)"
  ip -br link
  local renomme=0 chemin carte mac nom
  for chemin in /sys/class/net/*; do
    carte="$(basename "$chemin")"
    [ -e "$chemin/device" ] || continue
    mac="$(cat "$chemin/address")"
    nom="$(demander "Nouveau nom pour $carte ($mac) :")"
    [ -z "$nom" ] && continue
    printf '[Match]\nMACAddress=%s\nType=ether\n\n[Link]\nName=%s\n' "$mac" "$nom" \
      > "/etc/systemd/network/10-$nom.link"
    cp -n /etc/network/interfaces /etc/network/interfaces.bak
    # \b : "eno1" ne remplace pas le début de "eno12"
    sed -i "s/\b$carte\b/$nom/g" /etc/network/interfaces
    renomme=1
  done
  if [ "$renomme" -eq 1 ]; then
    update-initramfs -u -k all
  fi

  # ------------------------------------------------------------ Alias
  echo "==> Alias"
  grep -q "alias ll=" /root/.bashrc || echo "alias ll='ls -l'" >> /root/.bashrc
  grep -q "alias vi=" /root/.bashrc || echo "alias vi=vim.tiny" >> /root/.bashrc

  # ------------------------------------------------------------ Pare-feu
  echo "==> Pare-feu : n'autorise que l'interface web (8006), SSH (22) et le ping"
  if [ "$(demander "Activer le pare-feu ? [o/N]")" = "o" ]; then
    # Repart de zéro : relancer le script ne duplique pas les règles
    iptables -F INPUT
    iptables -A INPUT -i lo -j ACCEPT
    iptables -A INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    iptables -A INPUT -p icmp -j ACCEPT
    # Toutes les interfaces (vmbr0, vmbr0.5...), pas seulement vmbr0
    iptables -A INPUT -p tcp -m conntrack --ctstate NEW --dport 8006 -j ACCEPT
    iptables -A INPUT -p tcp -m conntrack --ctstate NEW --dport 22 -j ACCEPT
    iptables -A INPUT -j DROP
    # FORWARD non touché : ne pas couper le réseau des VM et conteneurs

    # IPv6 bloqué, sauf la boucle locale (::1) utilisée par certains services
    ip6tables -F INPUT
    ip6tables -F OUTPUT
    ip6tables -A INPUT -i lo -j ACCEPT
    ip6tables -A OUTPUT -o lo -j ACCEPT
    ip6tables -P INPUT DROP
    ip6tables -P OUTPUT DROP

    apt-get -y install iptables-persistent
    iptables-save > /etc/iptables/rules.v4
    ip6tables-save > /etc/iptables/rules.v6
    systemctl enable netfilter-persistent
  else
    echo "Pare-feu ignoré."
  fi

  echo
  echo "Terminé ! Tape 'source /root/.bashrc' pour charger les alias."
  [ "$renomme" -eq 1 ] && echo "Cartes renommées : fais 'reboot' pour appliquer."
  return 0
}

# Dernière ligne : si le téléchargement est coupé, rien ne s'exécute
main "$@"