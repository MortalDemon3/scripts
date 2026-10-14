#!/bin/bash
# Premiere configuration Proxmox 9 - d'apres tala-informatique.fr (Proxmox_first_start + Proxmox_iptables)

# Depots : desactivation repot
sed -i 's/true/false/g' /etc/apt/sources.list.d/pve-enterprise.sources
sed -i 's/true/false/g' /etc/apt/sources.list.d/ceph.sources

# Depots : rajout rep gratuit
cat > /etc/apt/sources.list.d/proxmox.sources <<EOF
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
Enabled: true
EOF

# Mise à jour (a faire une fois)
apt update && apt full-upgrade -y

# Suppression du message d'abonnement
wget https://github.com/Jamesits/pve-fake-subscription/releases/download/v0.0.11/pve-fake-subscription_0.0.11+git-1_all.deb
dpkg -i pve-fake-subscription_0.0.11+git-1_all.deb
echo "127.0.0.1 shop.maurer-it.com" >> /etc/hosts

# Nommage des cartes réseau (laisser vide pour ne pas renommer)
ip -br link
for carte in $(ls /sys/class/net); do
  [ -e /sys/class/net/$carte/device ] || continue
  mac=$(cat /sys/class/net/$carte/address)
  read -p "Nouveau nom pour $carte ($mac) : " nom
  [ -z "$nom" ] && continue
  echo "SUBSYSTEM==\"net\", ACTION==\"add\", DRIVERS==\"?*\", ATTR{address}==\"$mac\", ATTR{type}==\"1\", KERNEL==\"eth*\", NAME=\"$nom\"" >> /etc/udev/rules.d/70-persistent-net.rules
  sed -i "s/$carte/$nom/g" /etc/network/interfaces
done

# Création d'un alias
echo "alias ll='ls -l'" >> /root/.bashrc
echo "alias vi=vim.tiny" >> /root/.bashrc

# Pare-feu IPv4 : on n'autorise que le web Proxmox (8006), SSH (22) et le ping sur vmbr0
iptables -A INPUT -i vmbr0 -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables -A INPUT -i vmbr0 -p icmp -j ACCEPT
iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -i vmbr0 -p tcp -m state --state NEW -m tcp --dport 8006 -j ACCEPT
iptables -A INPUT -i vmbr0 -p tcp -m state --state NEW -m tcp --dport 22 -j ACCEPT
iptables -A INPUT -j DROP
iptables -A FORWARD -j DROP

# Pare-feu IPv6 : on bloque tout (IPv6 non utilisé)
ip6tables -P INPUT DROP
ip6tables -P FORWARD DROP
ip6tables -P OUTPUT DROP

# Sauvegarde des règles pour qu'elles restent après un reboot
DEBIAN_FRONTEND=noninteractive apt -y install iptables-persistent
iptables-save > /etc/iptables/rules.v4
ip6tables-save > /etc/iptables/rules.v6
systemctl enable netfilter-persistent

# Rechargement de l'environnement (marche seulement si le script est lance avec source )
. /root/.bashrc
echo "Terminé ! Alias chargés et pare-feu actif. Pense à faire 'reboot' si tu as renommé des cartes."
