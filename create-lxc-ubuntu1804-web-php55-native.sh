#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

readonly BACKTITLE="Proxmox VE Helper Scripts"
LOG_FILE="/var/log/create-lxc-web-php55-native-$(date '+%Y%m%d-%H%M%S').log"
TEMP_DIR=""; CTID=""; CT_CREATION_STARTED=0
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; RESET='\033[0m'
msg_info(){ echo -e "${BLUE}▶${RESET} $*"; }
msg_ok(){ echo -e "${GREEN}✔${RESET} $*"; }
msg_warn(){ echo -e "${YELLOW}⚠${RESET} $*"; }
msg_err(){ echo -e "${RED}✖${RESET} $*" >&2; }

cleanup(){
  local rc=$?
  [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"
  unset CT_ROOT_PASSWORD ADMIN_PASSWORD DB_ADMIN_PASSWORD CODE_SERVER_PASSWORD || true
  if (( rc != 0 )); then
    msg_err "Échec du déploiement. Journal : $LOG_FILE"
    if (( CT_CREATION_STARTED == 1 )) && [[ -n "$CTID" ]] && pct config "$CTID" >/dev/null 2>&1; then
      pct stop "$CTID" --skiplock 1 >/dev/null 2>&1 || true
      pct destroy "$CTID" --purge 1 >/dev/null 2>&1 || true
      msg_warn "La création partielle du conteneur $CTID a été supprimée."
    fi
  fi
}
trap cleanup EXIT
trap 'msg_err "Erreur ligne ${LINENO} : ${BASH_COMMAND}"' ERR

wt(){ whiptail --backtitle "$BACKTITLE" "$@" 3>&1 1>&2 2>&3; }
wt_msg(){ whiptail --backtitle "$BACKTITLE" --title "$1" --msgbox "$2" 19 86; }
wt_yesno(){ whiptail --backtitle "$BACKTITLE" --title "$1" --yesno "$2" 19 86; }
inputbox(){ local v; v=$(wt --title "$1" --inputbox "$2" 12 76 "$3") || exit 0; printf '%s' "$v"; }
passwordbox(){ local a b; while true; do a=$(wt --title "$1" --passwordbox "$2\n\nMinimum : 8 caractères." 14 76) || exit 0; (( ${#a} >= 8 )) || { wt_msg "Valeur invalide" "Le mot de passe doit contenir au moins 8 caractères."; continue; }; b=$(wt --title "$1" --passwordbox "Confirme le mot de passe." 12 76) || exit 0; [[ "$a" == "$b" ]] && { printf '%s' "$a"; return; }; wt_msg "Erreur" "Les deux mots de passe ne correspondent pas."; done; }
require_environment(){ [[ $EUID -eq 0 ]] || { msg_err "Exécute ce script en root sur Proxmox VE."; exit 1; }; for c in pct qm pveam pvesm pvesh whiptail tr head; do command -v "$c" >/dev/null || { msg_err "Commande manquante : $c"; exit 1; }; done; }
storage_type(){ local s="$1" t=""; t=$(pvesm status --storage "$s" 2>/dev/null | awk 'NR==2 {print $2}') || true; [[ -n "$t" ]] || t=$(awk -v id="$s" '/^[[:alnum:]_-]+:[[:space:]]+/ {split($0,a,":"); cur=a[2]; sub(/^[[:space:]]+/,"",cur); typ=a[1]} cur==id {print typ; exit}' /etc/pve/storage.cfg 2>/dev/null || true); printf '%s' "$t"; }
storage_menu(){ local content="$1" title="$2" def="$3" s t u state selected; local rows=(); while read -r s; do [[ -z "$s" ]] && continue; t=$(storage_type "$s"); u=$(pvesm status --storage "$s" 2>/dev/null | awk 'NR==2 {print $6" libres"}') || true; [[ "$s" == "$def" ]] && state=ON || state=OFF; rows+=("$s" "Type: ${t:-inconnu} | ${u:-espace inconnu}" "$state"); done < <(pvesm status -content "$content" 2>/dev/null | awk 'NR>1 && $3=="active" {print $1}' | sort -u); (( ${#rows[@]} )) || { wt_msg "Erreur" "Aucun stockage compatible avec $content."; exit 1; }; selected=$(wt --title "$title" --radiolist "Sélectionne un stockage.\n\n↑/↓ : déplacer   Espace : cocher   Tab : OK   Entrée : valider" 22 94 12 "${rows[@]}") || exit 0; selected=${selected//\"/}; [[ -n "$selected" ]] || { wt_msg "Sélection obligatoire" "Coche un stockage avec la barre espace."; storage_menu "$content" "$title" "$def"; return; }; printf '%s' "$selected"; }

validate_id(){ [[ "$1" =~ ^[1-9][0-9]{2,8}$ ]] && ! pct status "$1" >/dev/null 2>&1 && ! qm status "$1" >/dev/null 2>&1; }
validate_hostname(){ [[ "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]{0,62}$ ]]; }
validate_user(){ [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; }
validate_uint(){ [[ "$1" =~ ^[0-9]+$ ]]; }
validate_ip(){ [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }
validate_cidr(){ [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$ ]]; }
ask_valid(){ local v; while true; do v=$(inputbox "$1" "$2" "$3"); "$4" "$v" && { printf '%s' "$v"; return; }; wt_msg "Valeur invalide" "La valeur saisie est invalide ou déjà utilisée."; done; }
random_password(){ local p=""; while (( ${#p} < 8 )); do p+=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 8 || true); done; printf '%s' "${p:0:8}"; }
set_defaults(){ CTID=$(pvesh get /cluster/nextid 2>/dev/null || echo 100); HOSTNAME="ubuntu1804-php55"; ROOTFS_STORAGE="local-lvm"; TEMPLATE_STORAGE="local"; CPU_CORES=2; MEMORY_MB=4096; SWAP_MB=512; DISK_GB=32; BRIDGE="vmbr0"; VLAN_TAG=0; NETWORK_MODE="dhcp"; NET_IP="dhcp"; GATEWAY=""; DNS_SERVER="8.8.8.8"; ONBOOT=1; UNPRIVILEGED=1; FIREWALL=0; ADMIN_USER="admin"; DB_ADMIN_USER="dbadmin"; }
choose_mode(){ MODE=$(wt --title "CHOIX DU PARAMÉTRAGE" --radiolist "Sélectionne le mode de configuration.\n\n↑/↓ : déplacer   Espace : cocher   Tab : OK   Entrée : valider" 20 96 8 "1" "Paramètres par défaut - identifiants générés automatiquement" ON "2" "Paramètres par défaut - saisie manuelle des identifiants" OFF "3" "Paramètres avancés - configuration complète et identifiants personnalisés" OFF "4" "Quitter" OFF) || exit 0; MODE=${MODE//\"/}; [[ -n "$MODE" ]] || { wt_msg "Sélection obligatoire" "Coche un choix avec la barre espace."; choose_mode; return; }; case "$MODE" in 1|2|3) ;; 4) exit 0 ;; *) wt_msg "Erreur" "Mode invalide : $MODE"; exit 1 ;; esac; }
choose_storages(){ ROOTFS_STORAGE=$(storage_menu rootdir "Stockage du conteneur" "$ROOTFS_STORAGE") || exit 0; TEMPLATE_STORAGE=$(storage_menu vztmpl "Stockage du template" "$TEMPLATE_STORAGE") || exit 0; }
advanced_configuration(){ CTID=$(ask_valid "VMID" "Identifiant du conteneur." "$CTID" validate_id); HOSTNAME=$(ask_valid "Nom" "Nom d'hôte du conteneur." "$HOSTNAME" validate_hostname); CPU_CORES=$(ask_valid "CPU" "Nombre de cœurs." "$CPU_CORES" validate_uint); MEMORY_MB=$(ask_valid "RAM" "Mémoire en Mo." "$MEMORY_MB" validate_uint); SWAP_MB=$(ask_valid "Swap" "Swap en Mo." "$SWAP_MB" validate_uint); DISK_GB=$(ask_valid "Disque" "Taille en Go." "$DISK_GB" validate_uint); BRIDGE=$(inputbox "Bridge" "Bridge Proxmox." "$BRIDGE"); VLAN_TAG=$(ask_valid "VLAN" "0 pour aucun VLAN." "$VLAN_TAG" validate_uint); if wt_yesno "Réseau" "Utiliser DHCP ?"; then NETWORK_MODE=dhcp; NET_IP=dhcp; GATEWAY=""; else NETWORK_MODE=static; NET_IP=$(ask_valid "IPv4" "Adresse avec préfixe." "192.168.1.50/24" validate_cidr); GATEWAY=$(ask_valid "Passerelle" "Passerelle IPv4." "192.168.1.1" validate_ip); fi; DNS_SERVER=$(ask_valid "DNS" "Serveur DNS IPv4." "$DNS_SERVER" validate_ip); wt_yesno "Pare-feu" "Activer le pare-feu Proxmox sur l'interface ?" && FIREWALL=1 || FIREWALL=0; wt_yesno "Démarrage" "Démarrer automatiquement avec Proxmox ?" && ONBOOT=1 || ONBOOT=0; wt_yesno "Isolation" "Créer un LXC non privilégié ?" && UNPRIVILEGED=1 || UNPRIVILEGED=0; }
validate_bridge(){ ip link show "$BRIDGE" >/dev/null 2>&1 || { wt_msg "Bridge introuvable" "Le bridge $BRIDGE n'existe pas."; exit 1; }; }
advanced_credentials(){ CT_ROOT_PASSWORD=$(passwordbox "Mot de passe root" "Mot de passe root du conteneur."); while true; do ADMIN_USER=$(inputbox "Utilisateur Linux" "Compte SSH, Samba et code-server." admin); validate_user "$ADMIN_USER" && break; wt_msg "Nom invalide" "Nom Linux invalide."; done; ADMIN_PASSWORD=$(passwordbox "Mot de passe Linux" "Mot de passe de $ADMIN_USER."); while true; do DB_ADMIN_USER=$(inputbox "Utilisateur MariaDB" "Compte MariaDB/phpMyAdmin." dbadmin); validate_user "$DB_ADMIN_USER" && break; wt_msg "Nom invalide" "Nom MariaDB invalide."; done; DB_ADMIN_PASSWORD=$(passwordbox "Mot de passe MariaDB" "Mot de passe de $DB_ADMIN_USER."); CODE_SERVER_PASSWORD=$(passwordbox "Mot de passe code-server" "Mot de passe Web code-server."); }
default_credentials(){ ADMIN_USER="admin"; DB_ADMIN_USER="dbadmin"; CT_ROOT_PASSWORD=$(random_password); ADMIN_PASSWORD=$(random_password); DB_ADMIN_PASSWORD=$(random_password); CODE_SERVER_PASSWORD=$(random_password); }
confirm(){ local cm; [[ "$MODE" == 1 ]] && cm="Générés automatiquement" || cm="Personnalisés"; wt_yesno "CONFIRMATION - SYSTÈME HÉRITÉ" "ATTENTION : Ubuntu 18.04 et PHP 5.5.38 ne sont plus maintenus.\nCe serveur doit rester isolé d'Internet.\n\nPHP sera compilé et installé nativement, sans Docker.\n\nVMID : $CTID\nNom : $HOSTNAME\nStockage : $ROOTFS_STORAGE\nCPU : $CPU_CORES\nRAM : $MEMORY_MB Mo\nDisque : $DISK_GB Go\nRéseau : $NETWORK_MODE\nUtilisateur Linux : $ADMIN_USER\nIdentifiants : $cm\n\nCréer le conteneur ?" || exit 0; }

download_template(){ msg_info "Recherche du template Ubuntu 18.04..."; pveam update >/dev/null; TEMPLATE_NAME=$(pveam available --section system | awk '$2 ~ /^ubuntu-18\.04-standard_.*_amd64\.tar\.(zst|xz|gz)$/ {print $2}' | sort -V | tail -n1); [[ -n "$TEMPLATE_NAME" ]] || { msg_err "Template Ubuntu 18.04 introuvable sur le serveur Proxmox."; exit 1; }; TEMPLATE_VOLUME="${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE_NAME}"; pveam list "$TEMPLATE_STORAGE" | awk 'NR>1 {print $1}' | grep -qx "$TEMPLATE_VOLUME" || pveam download "$TEMPLATE_STORAGE" "$TEMPLATE_NAME"; }
create_container(){ local net0="name=eth0,bridge=${BRIDGE},ip=${NET_IP},firewall=${FIREWALL},type=veth" previous_umask; [[ "$NETWORK_MODE" == dhcp ]] && net0+=",ip6=dhcp"; [[ "$NETWORK_MODE" == static ]] && net0+=",gw=${GATEWAY}"; (( VLAN_TAG > 0 )) && net0+=",tag=${VLAN_TAG}"; CT_CREATION_STARTED=1; previous_umask=$(umask); umask 022; pct create "$CTID" "$TEMPLATE_VOLUME" --hostname "$HOSTNAME" --ostype ubuntu --arch amd64 --cores "$CPU_CORES" --memory "$MEMORY_MB" --swap "$SWAP_MB" --rootfs "${ROOTFS_STORAGE}:${DISK_GB}" --net0 "$net0" --nameserver "$DNS_SERVER" --password "$CT_ROOT_PASSWORD" --unprivileged "$UNPRIVILEGED" --features "nesting=1,keyctl=1" --onboot "$ONBOOT" --start 0; umask "$previous_umask"; write_notes "Adresse IP en attente" "Installation en cours"; }

build_installer(){
  TEMP_DIR=$(mktemp -d); INNER_SCRIPT="$TEMP_DIR/install.sh"; CREDS="$TEMP_DIR/credentials.env"
  cat >"$CREDS" <<EOF
ADMIN_USER='$ADMIN_USER'
ADMIN_PASSWORD_B64='$(printf %s "$ADMIN_PASSWORD" | base64 -w0)'
DB_ADMIN_USER='$DB_ADMIN_USER'
DB_ADMIN_PASSWORD_B64='$(printf %s "$DB_ADMIN_PASSWORD" | base64 -w0)'
CODE_SERVER_PASSWORD_B64='$(printf %s "$CODE_SERVER_PASSWORD" | base64 -w0)'
DNS_SERVER='$DNS_SERVER'
EOF
  chmod 600 "$CREDS"
  cat >"$INNER_SCRIPT" <<'INNER'
#!/usr/bin/env bash
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
source /root/.lxc-web-install-credentials
ADMIN_PASSWORD=$(printf %s "$ADMIN_PASSWORD_B64" | base64 -d)
DB_ADMIN_PASSWORD=$(printf %s "$DB_ADMIN_PASSWORD_B64" | base64 -d)
CODE_SERVER_PASSWORD=$(printf %s "$CODE_SERVER_PASSWORD_B64" | base64 -d)
INSTALL_LOG="/var/log/lxc-web-install.log"
PHP_VERSION="5.5.38"
PHP_PREFIX="/opt/php-5.5.38"
PHPMYADMIN_VERSION="4.9.11"
CODE_SERVER_VERSION="4.16.1"
TOTAL_STEPS=9; CURRENT_STEP=0
: >"$INSTALL_LOG"
run_step(){ local title="$1" fn="$2"; CURRENT_STEP=$((CURRENT_STEP + 1)); printf '\n[%d/%d] %s\n  ⏳ En cours...\n' "$CURRENT_STEP" "$TOTAL_STEPS" "$title"; if "$fn" >>"$INSTALL_LOG" 2>&1; then printf '  ✔ Terminée\n'; else printf '  ✖ Échec\n\nDernières lignes du journal :\n'; tail -n 40 "$INSTALL_LOG" || true; exit 1; fi; }

step_network(){ for _ in {1..60}; do ip -4 -o addr show dev eth0 scope global | grep -q 'inet ' && ip route show default | grep -q '^default ' && break; sleep 2; done; ip -4 -o addr show dev eth0 scope global | grep -q 'inet '; ip route show default | grep -q '^default '; printf 'nameserver %s\noptions timeout:2 attempts:2\n' "$DNS_SERVER" >/etc/resolv.conf; getent ahostsv4 old-releases.ubuntu.com >/dev/null; [[ "$(uname -m)" == x86_64 ]]; }
step_system(){
  cat >/etc/apt/sources.list <<'APT'
deb http://old-releases.ubuntu.com/ubuntu/ bionic main restricted universe multiverse
deb http://old-releases.ubuntu.com/ubuntu/ bionic-updates main restricted universe multiverse
deb http://old-releases.ubuntu.com/ubuntu/ bionic-security main restricted universe multiverse
APT
  apt-get -o Acquire::Check-Valid-Until=false update
  apt-get -o Acquire::Check-Valid-Until=false full-upgrade -y
  apt-get install -y ca-certificates curl openssl sudo xz-utils unattended-upgrades
}
step_apache_php(){
  apt-get install -y apache2 acl build-essential pkg-config libxml2-dev libssl1.0-dev libcurl4-gnutls-dev libjpeg-dev libpng-dev libfreetype6-dev libreadline-dev libxslt1-dev libbz2-dev libsqlite3-dev zlib1g-dev
  cd /usr/local/src
  curl -fsSLO "https://museum.php.net/php5/php-${PHP_VERSION}.tar.xz"
  echo "cb527c44b48343c8557fe2446464ff1d4695155a95601083e5d1f175df95580f  php-${PHP_VERSION}.tar.xz" | sha256sum -c -
  tar -xJf "php-${PHP_VERSION}.tar.xz"
  cd "php-${PHP_VERSION}"
  ./configure --prefix="$PHP_PREFIX" --with-config-file-path="$PHP_PREFIX/etc" --with-config-file-scan-dir="$PHP_PREFIX/etc/conf.d" --enable-fpm --with-fpm-user=www-data --with-fpm-group=www-data --enable-mbstring --enable-mysqlnd --with-mysqli=mysqlnd --with-pdo-mysql=mysqlnd --with-openssl --with-curl --with-zlib --with-bz2 --with-gd --with-jpeg-dir=/usr --with-png-dir=/usr --with-freetype-dir=/usr --with-readline --with-xsl --enable-soap --enable-zip --enable-bcmath --enable-calendar --enable-exif --enable-sockets --enable-opcache
  make -j"$(nproc)"
  make install
  mkdir -p "$PHP_PREFIX/etc/conf.d" /var/www/html
  cp php.ini-production "$PHP_PREFIX/etc/php.ini"
  cat >"$PHP_PREFIX/etc/conf.d/99-legacy.ini" <<'INI'
expose_php = Off
display_errors = Off
log_errors = On
date.timezone = Europe/Paris
memory_limit = 256M
post_max_size = 64M
upload_max_filesize = 64M
max_execution_time = 120
session.cookie_httponly = 1
INI
  cat >"$PHP_PREFIX/etc/php-fpm.conf" <<'FPM'
[global]
pid = /run/php55-fpm.pid
error_log = /var/log/php55-fpm.log
daemonize = no

[www]
user = www-data
group = www-data
listen = 127.0.0.1:9055
listen.allowed_clients = 127.0.0.1
pm = dynamic
pm.max_children = 10
pm.start_servers = 2
pm.min_spare_servers = 1
pm.max_spare_servers = 3
clear_env = no
catch_workers_output = yes
FPM
  ln -sf "$PHP_PREFIX/bin/php" /usr/local/bin/php
  cat >/etc/systemd/system/php55-fpm.service <<EOF
[Unit]
Description=PHP 5.5.38 FastCGI Process Manager natif
After=network.target

[Service]
Type=simple
ExecStart=$PHP_PREFIX/sbin/php-fpm --nodaemonize --fpm-config $PHP_PREFIX/etc/php-fpm.conf
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  a2enmod proxy proxy_fcgi rewrite headers
  cat >/etc/apache2/conf-available/php55-native.conf <<'APACHE'
<FilesMatch "\.php$">
    SetHandler "proxy:fcgi://127.0.0.1:9055"
</FilesMatch>
DirectoryIndex index.php index.html
APACHE
  a2enconf php55-native
  rm -f /var/www/html/index.html
  cat >/var/www/html/index.php <<'PHP'
<!doctype html><html lang="fr"><meta charset="utf-8"><title>PHP 5.5.38 natif</title><h1>Serveur Web PHP natif</h1><p>Apache et PHP <?php echo htmlspecialchars(PHP_VERSION, ENT_QUOTES, 'UTF-8'); ?> sont opérationnels.</p>
PHP
  systemctl daemon-reload
  systemctl enable --now php55-fpm.service
  systemctl enable apache2
  systemctl restart apache2
  php -r 'exit(PHP_VERSION === "5.5.38" ? 0 : 1);'
}
step_mariadb(){ apt-get install -y mariadb-client mariadb-server; systemctl enable --now mariadb; local su sp; su=${DB_ADMIN_USER//\'/\'\'}; sp=${DB_ADMIN_PASSWORD//\\/\\\\}; sp=${sp//\'/\'\'}; mysql <<SQL
CREATE USER IF NOT EXISTS '${su}'@'localhost' IDENTIFIED BY '${sp}';
GRANT ALL PRIVILEGES ON *.* TO '${su}'@'localhost' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL
}
step_ssh_user(){ apt-get install -y openssh-server; id "$ADMIN_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash "$ADMIN_USER"; printf '%s:%s\n' "$ADMIN_USER" "$ADMIN_PASSWORD" | chpasswd; usermod -aG sudo "$ADMIN_USER"; sed -ri 's/^[#[:space:]]*PasswordAuthentication.*/PasswordAuthentication yes/; s/^[#[:space:]]*PermitRootLogin.*/PermitRootLogin no/; s/^[#[:space:]]*UsePAM.*/UsePAM yes/' /etc/ssh/sshd_config; systemctl enable --now ssh; systemctl restart ssh; }
step_phpmyadmin(){ local a="phpMyAdmin-${PHPMYADMIN_VERSION}-all-languages.tar.gz" u="https://files.phpmyadmin.net/phpMyAdmin/${PHPMYADMIN_VERSION}" secret; cd /tmp; curl -fsSLO "$u/$a"; curl -fsSLO "$u/$a.sha256"; sha256sum -c "$a.sha256"; rm -rf /var/www/html/phpmyadmin; tar -xzf "$a"; mv "phpMyAdmin-${PHPMYADMIN_VERSION}-all-languages" /var/www/html/phpmyadmin; rm -f "$a" "$a.sha256"; secret=$(openssl rand -hex 32); cat >/var/www/html/phpmyadmin/config.inc.php <<EOF
<?php
\$cfg['blowfish_secret'] = '$secret';
\$i = 0; ++\$i;
\$cfg['Servers'][\$i]['auth_type'] = 'cookie';
\$cfg['Servers'][\$i]['host'] = 'localhost';
\$cfg['Servers'][\$i]['AllowNoPassword'] = false;
\$cfg['TempDir'] = '/var/www/html/phpmyadmin/tmp';
EOF
  mkdir -p /var/www/html/phpmyadmin/tmp; chown -R www-data:www-data /var/www/html/phpmyadmin; chmod 0750 /var/www/html/phpmyadmin/tmp; chmod 0640 /var/www/html/phpmyadmin/config.inc.php; }
step_samba(){ apt-get install -y samba samba-common-bin; getent group webdev >/dev/null || groupadd webdev; usermod -aG webdev "$ADMIN_USER"; usermod -aG webdev www-data; chown -R "$ADMIN_USER:webdev" /var/www/html; find /var/www/html -type d -exec chmod 2775 {} \;; find /var/www/html -type f -exec chmod 0664 {} \;; setfacl -Rm u:www-data:rwX,d:u:www-data:rwX /var/www/html; cat >>/etc/samba/smb.conf <<SMB
[Web]
 path = /var/www/html
 browseable = yes
 read only = no
 guest ok = no
 valid users = $ADMIN_USER
 force user = $ADMIN_USER
 force group = webdev
 create mask = 0664
 directory mask = 2775
SMB
  printf '%s\n%s\n' "$ADMIN_PASSWORD" "$ADMIN_PASSWORD" | smbpasswd -s -a "$ADMIN_USER"; systemctl enable --now smbd; }
step_code_server(){ local deb="/tmp/code-server.deb"; curl -fsSL "https://github.com/coder/code-server/releases/download/v${CODE_SERVER_VERSION}/code-server_${CODE_SERVER_VERSION}_amd64.deb" -o "$deb"; dpkg -i "$deb" || apt-get install -f -y; rm -f "$deb"; mkdir -p "/home/$ADMIN_USER/.config/code-server"; cat >"/home/$ADMIN_USER/.config/code-server/config.yaml" <<CFG
bind-addr: 0.0.0.0:8680
auth: password
password: "$CODE_SERVER_PASSWORD"
cert: false
disable-telemetry: true
CFG
  chown -R "$ADMIN_USER:$ADMIN_USER" "/home/$ADMIN_USER/.config"; chmod 600 "/home/$ADMIN_USER/.config/code-server/config.yaml"; systemctl enable --now "code-server@$ADMIN_USER.service"; }
step_final(){ systemctl is-active --quiet apache2; systemctl is-active --quiet php55-fpm; systemctl is-active --quiet mariadb; systemctl is-active --quiet ssh; systemctl is-active --quiet smbd; systemctl is-active --quiet "code-server@$ADMIN_USER.service"; php -r 'exit(PHP_VERSION === "5.5.38" && extension_loaded("mysqli") && extension_loaded("pdo_mysql") && extension_loaded("openssl") ? 0 : 1);'; curl -fsS http://127.0.0.1/ | grep -q 'PHP 5.5.38'; curl -fsS http://127.0.0.1/phpmyadmin/ >/dev/null; rm -f /root/.lxc-web-install-credentials; }

printf 'Installation native Ubuntu 18.04 / PHP 5.5.38\n'
run_step "Configuration du réseau" step_network
run_step "Mise à jour du système Ubuntu 18.04" step_system
run_step "Compilation et installation native de PHP 5.5.38" step_apache_php
run_step "MariaDB" step_mariadb
run_step "Utilisateur Linux et SSH" step_ssh_user
run_step "phpMyAdmin 4.9.11" step_phpmyadmin
run_step "Samba" step_samba
run_step "code-server 4.16.1" step_code_server
run_step "Vérification finale" step_final
INNER
  chmod 700 "$INNER_SCRIPT"
}

install_inside(){ msg_info "Démarrage du conteneur..."; pct start "$CTID"; for _ in {1..60}; do pct exec "$CTID" -- true >/dev/null 2>&1 && break; sleep 2; done; pct exec "$CTID" -- true >/dev/null 2>&1 || { msg_err "Le conteneur ne répond pas."; exit 1; }; pct push "$CTID" "$INNER_SCRIPT" /root/install-applications.sh --perms 700; pct push "$CTID" "$CREDS" /root/.lxc-web-install-credentials --perms 600; pct exec "$CTID" -- bash /root/install-applications.sh; pct exec "$CTID" -- rm -f /root/install-applications.sh /root/.lxc-web-install-credentials; }
container_ip(){ pct exec "$CTID" -- hostname -I 2>/dev/null | awk '{print $1}' || true; }
escape_notes(){ local v="$1"; v=${v//&/&amp;}; v=${v//</&lt;}; v=${v//>/&gt;}; printf '%s' "$v"; }
write_notes(){ local ip="$1" status="$2" h au ap du dp cp rp st notes; h=$(escape_notes "$HOSTNAME"); au=$(escape_notes "$ADMIN_USER"); ap=$(escape_notes "$ADMIN_PASSWORD"); du=$(escape_notes "$DB_ADMIN_USER"); dp=$(escape_notes "$DB_ADMIN_PASSWORD"); cp=$(escape_notes "$CODE_SERVER_PASSWORD"); rp=$(escape_notes "$CT_ROOT_PASSWORD"); st=$(escape_notes "$status"); notes="<div align='center'><h2>${h}</h2><p><strong>État :</strong> ${st}</p><p><strong>Attention :</strong> Ubuntu 18.04 et PHP 5.5.38 sont obsolètes. Ne pas exposer à Internet.</p></div>

## Services
- Apache - http://${ip}
- PHP 5.5.38 natif via PHP-FPM
- MariaDB
- phpMyAdmin 4.9.11 - http://${ip}/phpmyadmin
- code-server 4.16.1 - http://${ip}:8680
- Serveur SMB - \\\\${ip}\\Web
- SSH - port 22

## Identifiants
- Root LXC : root / ${rp}
- Linux, SSH et SMB : ${au} / ${ap}
- MariaDB et phpMyAdmin : ${du} / ${dp}
- code-server : ${cp}

## Réseau
- Adresse IP : ${ip}
- DNS : ${DNS_SERVER}
- Bridge : ${BRIDGE}
- VLAN : ${VLAN_TAG}
"; pct set "$CTID" --description "$notes" >/dev/null; }
finish(){ local ip; ip=$(container_ip); ip=${ip:-adresse_non_detectee}; write_notes "$ip" "Installation terminée"; CT_CREATION_STARTED=0; wt_msg "INSTALLATION TERMINÉE" "LXC Ubuntu 18.04 prêt avec PHP 5.5.38 natif.\n\nVMID : $CTID\nIP : $ip\nApache : http://$ip\nphpMyAdmin : http://$ip/phpmyadmin\ncode-server : http://$ip:8680\nSamba : \\\\$ip\\Web\nSSH : $ADMIN_USER@$ip\n\nNe pas exposer directement à Internet."; }
main(){ require_environment; touch "$LOG_FILE"; chmod 600 "$LOG_FILE"; exec > >(tee -a "$LOG_FILE") 2>&1; set_defaults; choose_mode; choose_storages; case "$MODE" in 1) default_credentials ;; 2) advanced_credentials ;; 3) advanced_configuration; advanced_credentials ;; esac; validate_bridge; confirm; download_template; build_installer; create_container; install_inside; finish; }
main "$@"
