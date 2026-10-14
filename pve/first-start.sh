#!/bin/bash
# DESC: Première config Proxmox 9 (dépôts gratuits, MAJ, abonnement, cartes réseau, alias, pare-feu)
# D'après tala-informatique.fr (Proxmox_first_start + Proxmox_iptables)
#
# Usage : curl -fsSL https://get.andries.icu/pve/first-start | bash

# Depots : desactivation enterprise + ajout gratuit
sed -i '/^Enabled:/d' /etc/apt/sources.list.d/pve-enterprise.sources /etc/apt/sources.list.d/ceph.sources
echo "Enabled: false" >> /etc/apt/sources.list.d/pve-enterprise.sources
echo "Enabled: false" >> /etc/apt/sources.list.d/ceph.sources
cat > /etc/apt/sources.list.d/proxmox.sources <<EOF
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF

# Mise a jour
apt update && apt full-upgrade -y

# Suppression du message d'abonnement
wget https://github.com/Jamesits/pve-fake-subscription/releases/download/v0.0.11/pve-fake-subscription_0.0.11+git-1_all.deb
dpkg -i pve-fake-subscription_0.0.11+git-1_all.deb
echo "127.0.0.1 shop.maurer-it.com" >> /etc/hosts

# Nommage des cartes reseau (laisser vide pour ne pas renommer)
ip -br link
for carte in $(ls /sys/class/net); do
  [ -e /sys/class/net/$carte/device ] || continue
  mac=$(cat /sys/class/net/$carte/address)
  read -p "Nouveau nom pour $carte ($mac) : " nom
  [ -z "$nom" ] && continue
  echo "SUBSYSTEM==\"net\", ACTION==\"add\", DRIVERS==\"?*\", ATTR{address}==\"$mac\", ATTR{type}==\"1\", KERNEL==\"eth*\", NAME=\"$nom\"" >> /etc/udev/rules.d/70-persistent-net.rules
  sed -i "s/$carte/$nom/g" /etc/network/interfaces
done

# Alias
echo "alias ll='ls -l'" >> /root/.bashrc
echo "alias vi=vim.tiny" >> /root/.bashrc

# Pare-feu IPv4 : web Proxmox (8006), SSH (22) et ping sur vmbr0
iptables -F
iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -i vmbr0 -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables -A INPUT -i vmbr0 -p icmp -j ACCEPT
iptables -A INPUT -i vmbr0 -p tcp --dport 8006 -j ACCEPT
iptables -A INPUT -i vmbr0 -p tcp --dport 22 -j ACCEPT
iptables -A INPUT -j DROP
iptables -A FORWARD -j DROP

# Pare-feu IPv6 : tout bloque
ip6tables -P INPUT DROP
ip6tables -P FORWARD DROP
ip6tables -P OUTPUT DROP

# Sauvegarde des regles + rechargement automatique au demarrage
iptables-save > /etc/iptables.v4
ip6tables-save > /etc/iptables.v6
echo "@reboot root /usr/sbin/iptables-restore < /etc/iptables.v4; /usr/sbin/ip6tables-restore < /etc/iptables.v6" > /etc/cron.d/iptables

echo "Termine !"