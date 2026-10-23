#!/bin/sh
# =============================================================================
#  DESC: Installation web + vHost /opt/site
#  install-web-vhost.sh — Serveur web Apache + vhost /opt/site
#  Auteur : Alexis (MortalDemon3) — https://get.andries.icu
# -----------------------------------------------------------------------------
#  DESCRIPTION
#    Installe Apache en s'adaptant automatiquement à l'OS, puis crée un vhost
#    sur le port 80 dont la racine est /opt/site (avec une page de test).
#
#  OS SUPPORTÉS
#    Debian / Ubuntu                   → apache2
#    Rocky / Alma / RHEL / Fedora      → httpd
#    openSUSE                          → apache2
#    Arch                              → apache
#    Alpine                            → apache2
#
#  UTILISATION
#    curl -fsSL https://get.andries.icu/install-web-vhost.sh | sudo sh
#
#  RÉSULTAT
#    Mets tes fichiers dans /opt/site, ils sont servis sur http://<IP>
# =============================================================================

set -e

mkdir -p /opt/site
echo "<h1>Ça marche !</h1>" > /opt/site/index.html

VHOST='<VirtualHost *:80>
    DocumentRoot /opt/site
    <Directory /opt/site>
        Require all granted
    </Directory>
</VirtualHost>'

if command -v apt >/dev/null; then          # Debian / Ubuntu
    apt update && apt install -y apache2
    echo "$VHOST" > /etc/apache2/sites-available/site.conf
    a2dissite 000-default
    a2ensite site
    SERVICE=apache2

elif command -v dnf >/dev/null || command -v yum >/dev/null; then   # Rocky / Alma / RHEL / Fedora
    $(command -v dnf || command -v yum) install -y httpd
    echo "$VHOST" > /etc/httpd/conf.d/site.conf
    rm -f /etc/httpd/conf.d/welcome.conf
    chcon -R -t httpd_sys_content_t /opt/site 2>/dev/null || true
    SERVICE=httpd

elif command -v zypper >/dev/null; then     # openSUSE
    zypper install -y apache2
    echo "$VHOST" > /etc/apache2/vhosts.d/site.conf
    SERVICE=apache2

elif command -v pacman >/dev/null; then     # Arch
    pacman -Sy --noconfirm apache
    echo "$VHOST" > /etc/httpd/conf/extra/site.conf
    grep -q "extra/site.conf" /etc/httpd/conf/httpd.conf || \
        echo "Include conf/extra/site.conf" >> /etc/httpd/conf/httpd.conf
    SERVICE=httpd

elif command -v apk >/dev/null; then        # Alpine
    apk add apache2
    echo "$VHOST" > /etc/apache2/conf.d/site.conf
    rc-update add apache2
    rc-service apache2 restart
    echo "Site en ligne : http://$(hostname -i | awk '{print $1}')"
    exit 0

else
    echo "OS non supporté" && exit 1
fi

systemctl enable "$SERVICE"
systemctl restart "$SERVICE"

echo "Site en ligne : http://$(hostname -I | awk '{print $1}')"
