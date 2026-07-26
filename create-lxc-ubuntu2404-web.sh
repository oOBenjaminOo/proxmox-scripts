#!/usr/bin/env bash
# =============================================================================
# Création automatisée d'un LXC Ubuntu 24.04 LTS sur Proxmox VE
# puis installation de :
#   - Apache 2 + PHP
#   - MariaDB
#   - phpMyAdmin
#   - Samba partageant /var/www/html
#   - code-server sur le port 8680
#   - OpenSSH Server
#
# À exécuter directement dans le shell du nœud Proxmox en tant que root.
#
# Compatible avec une exécution en une ligne :
# bash -c "$(curl -fsSL https://serveur.exemple/script.sh)"
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

LOG_FILE="/var/log/create-lxc-web-$(date '+%Y%m%d-%H%M%S').log"
TEMP_DIR=""
CT_CREATED=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
RESET='\033[0m'

info()    { echo -e "${BLUE}[INFO]${RESET} $*"; }
success() { echo -e "${GREEN}[OK]${RESET} $*"; }
warn()    { echo -e "${YELLOW}[ATTENTION]${RESET} $*"; }
error()   { echo -e "${RED}[ERREUR]${RESET} $*" >&2; }
section() {
    echo
    echo -e "${CYAN}================================================================${RESET}"
    echo -e "${CYAN} $*${RESET}"
    echo -e "${CYAN}================================================================${RESET}"
}

cleanup() {
    local exit_code=$?

    if [[ -n "${TEMP_DIR:-}" && -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
    fi

    unset \
        CT_ROOT_PASSWORD \
        ADMIN_PASSWORD \
        DB_ADMIN_PASSWORD \
        CODE_SERVER_PASSWORD || true

    if (( exit_code != 0 )); then
        error "Le déploiement a échoué. Journal : ${LOG_FILE}"

        if (( CT_CREATED == 1 )) && [[ -n "${CTID:-}" ]] && pct status "$CTID" >/dev/null 2>&1; then
            warn "Le conteneur ${CTID} a été créé partiellement et a été conservé pour diagnostic."
            warn "Pour le supprimer manuellement : pct stop ${CTID} --skiplock 1 ; pct destroy ${CTID} --purge 1"
        fi
    fi
}
trap cleanup EXIT
trap 'error "Erreur à la ligne ${LINENO} : ${BASH_COMMAND}"' ERR

require_root() {
    if [[ $EUID -ne 0 ]]; then
        error "Ce script doit être exécuté en root depuis le shell Proxmox."
        exit 1
    fi
}

require_proxmox() {
    local command
    for command in pct pveam pvesm pvesh; do
        if ! command -v "$command" >/dev/null 2>&1; then
            error "Commande Proxmox absente : ${command}"
            exit 1
        fi
    done
}

require_tty() {
    if [[ ! -r /dev/tty || ! -w /dev/tty ]]; then
        error "Aucun terminal interactif n'est disponible."
        error "Lance le script depuis le shell Proxmox avec :"
        error "bash -c \"\$(curl -fsSL URL_DU_SCRIPT)\""
        exit 1
    fi
}

read_required() {
    local prompt="$1"
    local variable="$2"
    local value=""

    while true; do
        read -r -p "$prompt" value < /dev/tty
        if [[ -n "$value" ]]; then
            printf -v "$variable" '%s' "$value"
            return
        fi
        warn "Cette valeur ne peut pas être vide."
    done
}

read_default() {
    local prompt="$1"
    local default="$2"
    local variable="$3"
    local value=""

    read -r -p "${prompt} [${default}] : " value < /dev/tty
    printf -v "$variable" '%s' "${value:-$default}"
}

read_yes_no() {
    local prompt="$1"
    local default="$2"
    local variable="$3"
    local answer=""

    while true; do
        if [[ "$default" == "yes" ]]; then
            read -r -p "${prompt} [O/n] : " answer < /dev/tty
            answer="${answer:-o}"
        else
            read -r -p "${prompt} [o/N] : " answer < /dev/tty
            answer="${answer:-n}"
        fi

        case "${answer,,}" in
            o|oui|y|yes)
                printf -v "$variable" '%s' "yes"
                return
                ;;
            n|non|no)
                printf -v "$variable" '%s' "no"
                return
                ;;
            *)
                warn "Réponds par oui ou non."
                ;;
        esac
    done
}

read_username() {
    local prompt="$1"
    local variable="$2"
    local username=""

    while true; do
        read -r -p "$prompt" username < /dev/tty

        if [[ "$username" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
            printf -v "$variable" '%s' "$username"
            return
        fi

        warn "Nom invalide : 1 à 32 caractères, minuscules, chiffres, tirets et underscores."
    done
}

read_password() {
    local prompt="$1"
    local variable="$2"
    local password=""
    local confirmation=""

    while true; do
        read -r -s -p "$prompt" password < /dev/tty
        echo
        read -r -s -p "Confirmation : " confirmation < /dev/tty
        echo

        if [[ -z "$password" ]]; then
            warn "Le mot de passe ne peut pas être vide."
            continue
        fi

        if (( ${#password} < 8 )); then
            warn "Le mot de passe doit contenir au moins 8 caractères."
            continue
        fi

        if [[ "$password" != "$confirmation" ]]; then
            warn "Les mots de passe ne correspondent pas."
            continue
        fi

        printf -v "$variable" '%s' "$password"
        unset password confirmation
        return
    done
}

validate_ipv4_cidr() {
    local value="$1"
    [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$ ]]
}

validate_ipv4() {
    local value="$1"
    [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

choose_storage() {
    local content_type="$1"
    local variable="$2"
    local default_storage="$3"
    local storages=()

    mapfile -t storages < <(
        pvesm status -content "$content_type" 2>/dev/null |
        awk 'NR > 1 && $3 == "active" {print $1}' |
        sort -u
    )

    if (( ${#storages[@]} == 0 )); then
        error "Aucun stockage actif compatible avec le contenu '${content_type}'."
        exit 1
    fi

    echo "Stockages disponibles pour ${content_type} :"
    printf '  - %s\n' "${storages[@]}"

    if [[ -z "$default_storage" ]] || ! printf '%s\n' "${storages[@]}" | grep -qx "$default_storage"; then
        default_storage="${storages[0]}"
    fi

    local selected=""
    while true; do
        read_default "Stockage à utiliser" "$default_storage" selected

        if printf '%s\n' "${storages[@]}" | grep -qx "$selected"; then
            printf -v "$variable" '%s' "$selected"
            return
        fi

        warn "Le stockage '${selected}' n'est pas disponible pour ${content_type}."
    done
}

collect_configuration() {
    section "Paramètres du conteneur LXC"

    local suggested_vmid
    suggested_vmid="$(pvesh get /cluster/nextid 2>/dev/null || true)"
    suggested_vmid="${suggested_vmid:-100}"

    while true; do
        read_default "VMID du conteneur" "$suggested_vmid" CTID

        if [[ ! "$CTID" =~ ^[1-9][0-9]{2,8}$ ]]; then
            warn "Le VMID doit être un nombre valide d'au moins 100."
            continue
        fi

        if pct status "$CTID" >/dev/null 2>&1 || qm status "$CTID" >/dev/null 2>&1; then
            warn "Le VMID ${CTID} est déjà utilisé."
            continue
        fi
        break
    done

    while true; do
        read_required "Nom du LXC : " HOSTNAME
        if [[ "$HOSTNAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]{0,62}$ ]]; then
            break
        fi
        warn "Nom invalide. Utilise des lettres, chiffres, points et tirets."
    done

    choose_storage "rootdir" ROOTFS_STORAGE "local-lvm"
    choose_storage "vztmpl" TEMPLATE_STORAGE "local"

    read_default "Nombre de cœurs CPU" "2" CPU_CORES
    read_default "Mémoire RAM en Mo" "4096" MEMORY_MB
    read_default "Swap en Mo" "512" SWAP_MB
    read_default "Taille du disque en Go" "32" DISK_GB
    read_default "Bridge réseau Proxmox" "vmbr0" BRIDGE
    read_default "VLAN tag, laisser 0 sans VLAN" "0" VLAN_TAG

    for numeric_value in CPU_CORES MEMORY_MB SWAP_MB DISK_GB VLAN_TAG; do
        if [[ ! "${!numeric_value}" =~ ^[0-9]+$ ]]; then
            error "Valeur numérique invalide pour ${numeric_value} : ${!numeric_value}"
            exit 1
        fi
    done

    echo
    echo "Configuration réseau :"
    echo "  1) DHCP"
    echo "  2) Adresse IPv4 statique"

    local network_choice=""
    while true; do
        read_default "Choix réseau" "1" network_choice
        case "$network_choice" in
            1)
                NETWORK_MODE="dhcp"
                NET_IP="dhcp"
                GATEWAY=""
                break
                ;;
            2)
                NETWORK_MODE="static"

                while true; do
                    read_required "Adresse IPv4 avec préfixe, exemple 192.168.40.220/24 : " NET_IP
                    validate_ipv4_cidr "$NET_IP" && break
                    warn "Format invalide. Exemple attendu : 192.168.40.220/24"
                done

                while true; do
                    read_required "Passerelle IPv4 : " GATEWAY
                    validate_ipv4 "$GATEWAY" && break
                    warn "Adresse de passerelle invalide."
                done
                break
                ;;
            *)
                warn "Choisis 1 ou 2."
                ;;
        esac
    done

    read_default "Serveur DNS" "1.1.1.1" DNS_SERVER
    read_default "Domaine de recherche DNS" "local" DNS_SEARCH

    section "Identifiants du conteneur"

    echo "Mot de passe root du LXC, utilisé notamment depuis sa console :"
    read_password "Mot de passe root : " CT_ROOT_PASSWORD

    echo
    read_username "Nom d'utilisateur Linux, SSH et Samba : " ADMIN_USER
    read_password "Mot de passe Linux, SSH et Samba : " ADMIN_PASSWORD

    echo
    read_username "Nom d'utilisateur administrateur MariaDB/phpMyAdmin : " DB_ADMIN_USER
    read_password "Mot de passe MariaDB/phpMyAdmin : " DB_ADMIN_PASSWORD

    echo
    echo "code-server utilise le compte Linux '${ADMIN_USER}' et demande seulement un mot de passe Web."
    read_password "Mot de passe code-server : " CODE_SERVER_PASSWORD

    read_yes_no "Démarrer automatiquement le LXC avec Proxmox" "yes" START_AT_BOOT
    read_yes_no "Créer un LXC non privilégié, recommandé" "yes" UNPRIVILEGED_CHOICE

    if [[ "$START_AT_BOOT" == "yes" ]]; then
        ONBOOT=1
    else
        ONBOOT=0
    fi

    if [[ "$UNPRIVILEGED_CHOICE" == "yes" ]]; then
        UNPRIVILEGED=1
    else
        UNPRIVILEGED=0
        warn "Un conteneur privilégié offre moins d'isolation."
    fi
}

display_summary_and_confirm() {
    section "Résumé avant création"

    cat <<EOF
VMID                 : ${CTID}
Nom                  : ${HOSTNAME}
Système              : Ubuntu 24.04 LTS, sans interface graphique
Stockage racine      : ${ROOTFS_STORAGE}
Stockage template    : ${TEMPLATE_STORAGE}
CPU                  : ${CPU_CORES} cœur(s)
RAM                  : ${MEMORY_MB} Mo
Swap                 : ${SWAP_MB} Mo
Disque               : ${DISK_GB} Go
Bridge               : ${BRIDGE}
VLAN                 : ${VLAN_TAG}
Réseau               : ${NETWORK_MODE}
Adresse               : ${NET_IP}
Passerelle            : ${GATEWAY:-attribuée par DHCP}
DNS                  : ${DNS_SERVER}
Utilisateur SSH      : ${ADMIN_USER}
Utilisateur MariaDB  : ${DB_ADMIN_USER}
code-server          : port 8680
Conteneur privilégié : $([[ "$UNPRIVILEGED" == "1" ]] && echo "non" || echo "oui")
Démarrage Proxmox    : $([[ "$ONBOOT" == "1" ]] && echo "oui" || echo "non")
EOF

    local confirmation
    read_yes_no "Créer maintenant ce conteneur" "yes" confirmation

    if [[ "$confirmation" != "yes" ]]; then
        warn "Création annulée."
        exit 0
    fi
}

download_template() {
    section "Téléchargement du template Ubuntu 24.04"

    pveam update

    TEMPLATE_NAME="$(
        pveam available --section system |
        awk '$2 ~ /^ubuntu-24\.04-standard_.*_amd64\.tar\.(zst|xz|gz)$/ {print $2}' |
        sort -V |
        tail -n 1
    )"

    if [[ -z "$TEMPLATE_NAME" ]]; then
        error "Aucun template Ubuntu 24.04 amd64 n'a été trouvé dans le catalogue Proxmox."
        error "Commande de contrôle : pveam available --section system | grep ubuntu-24.04"
        exit 1
    fi

    TEMPLATE_VOLUME="${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE_NAME}"

    if pveam list "$TEMPLATE_STORAGE" | awk 'NR > 1 {print $1}' | grep -qx "$TEMPLATE_VOLUME"; then
        success "Template déjà présent : ${TEMPLATE_VOLUME}"
    else
        info "Téléchargement de ${TEMPLATE_NAME}..."
        pveam download "$TEMPLATE_STORAGE" "$TEMPLATE_NAME"
    fi
}

create_container() {
    section "Création du conteneur LXC"

    local net0
    net0="name=eth0,bridge=${BRIDGE},ip=${NET_IP},firewall=1,type=veth"

    if [[ "$NETWORK_MODE" == "static" ]]; then
        net0+=",gw=${GATEWAY}"
    fi

    if (( VLAN_TAG > 0 )); then
        net0+=",tag=${VLAN_TAG}"
    fi

    pct create "$CTID" "$TEMPLATE_VOLUME" \
        --hostname "$HOSTNAME" \
        --ostype ubuntu \
        --arch amd64 \
        --cores "$CPU_CORES" \
        --memory "$MEMORY_MB" \
        --swap "$SWAP_MB" \
        --rootfs "${ROOTFS_STORAGE}:${DISK_GB}" \
        --net0 "$net0" \
        --nameserver "$DNS_SERVER" \
        --searchdomain "$DNS_SEARCH" \
        --password "$CT_ROOT_PASSWORD" \
        --unprivileged "$UNPRIVILEGED" \
        --features "nesting=1,keyctl=1" \
        --onboot "$ONBOOT" \
        --start 0 \
        --description "LXC Ubuntu 24.04 LTS - Apache, MariaDB, phpMyAdmin, Samba et code-server"

    CT_CREATED=1
    success "Conteneur ${CTID} créé."
}

create_inner_installer() {
    TEMP_DIR="$(mktemp -d)"
    INNER_SCRIPT="${TEMP_DIR}/install-applications.sh"
    CREDENTIALS_FILE="${TEMP_DIR}/credentials.env"

    cat > "$INNER_SCRIPT" <<'INNER_SCRIPT_EOF'
#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

CREDENTIALS_FILE="/root/.lxc-web-install-credentials"
LOG_FILE="/var/log/lxc-web-applications-install.log"

exec > >(tee -a "$LOG_FILE") 2>&1

log() {
    printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

fail() {
    log "ERREUR : $*"
    exit 1
}

trap 'fail "ligne ${LINENO} : ${BASH_COMMAND}"' ERR

[[ -f "$CREDENTIALS_FILE" ]] || fail "Fichier d'identifiants absent."
# shellcheck disable=SC1090
source "$CREDENTIALS_FILE"

required_variables=(
    ADMIN_USER
    ADMIN_PASSWORD_B64
    DB_ADMIN_USER
    DB_ADMIN_PASSWORD_B64
    CODE_SERVER_PASSWORD_B64
)

for variable in "${required_variables[@]}"; do
    [[ -n "${!variable:-}" ]] || fail "Variable absente : ${variable}"
done

ADMIN_PASSWORD="$(printf '%s' "$ADMIN_PASSWORD_B64" | base64 -d)"
DB_ADMIN_PASSWORD="$(printf '%s' "$DB_ADMIN_PASSWORD_B64" | base64 -d)"
CODE_SERVER_PASSWORD="$(printf '%s' "$CODE_SERVER_PASSWORD_B64" | base64 -d)"

export DEBIAN_FRONTEND=noninteractive

log "Mise à jour des dépôts Ubuntu..."
apt-get update
apt-get full-upgrade -y

log "Installation des paquets de base..."
apt-get install -y \
    acl \
    apache2 \
    ca-certificates \
    curl \
    debconf-utils \
    libapache2-mod-php \
    mariadb-client \
    mariadb-server \
    openssh-server \
    php \
    php-apcu \
    php-bcmath \
    php-cli \
    php-common \
    php-curl \
    php-gd \
    php-imagick \
    php-intl \
    php-mbstring \
    php-mysql \
    php-opcache \
    php-soap \
    php-xml \
    php-zip \
    samba \
    samba-common-bin \
    sudo \
    unattended-upgrades

log "Création du compte Linux ${ADMIN_USER}..."
if ! id "$ADMIN_USER" >/dev/null 2>&1; then
    useradd --create-home --shell /bin/bash "$ADMIN_USER"
fi

printf '%s:%s\n' "$ADMIN_USER" "$ADMIN_PASSWORD" | chpasswd
usermod -aG sudo "$ADMIN_USER"

log "Configuration SSH..."
mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/99-lxc-web.conf <<EOF
PasswordAuthentication yes
KbdInteractiveAuthentication no
PermitRootLogin no
UsePAM yes
EOF

sshd -t
systemctl enable ssh
systemctl restart ssh

log "Configuration Apache et PHP..."
a2enmod rewrite headers expires ssl

cat > /etc/apache2/conf-available/lxc-web-security.conf <<'EOF'
ServerTokens Prod
ServerSignature Off

<IfModule mod_headers.c>
    Header always set X-Content-Type-Options "nosniff"
    Header always set X-Frame-Options "SAMEORIGIN"
    Header always set Referrer-Policy "strict-origin-when-cross-origin"
</IfModule>

<Directory /var/www/html>
    Options -Indexes +FollowSymLinks
    AllowOverride All
    Require all granted
</Directory>
EOF

a2enconf lxc-web-security

mkdir -p /var/www/html
rm -f /var/www/html/index.html

cat > /var/www/html/index.php <<'EOF'
<?php
declare(strict_types=1);
?>
<!DOCTYPE html>
<html lang="fr">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Serveur Web Ubuntu personnalisé</title>
    <style>
        body {
            min-height: 100vh;
            margin: 0;
            display: grid;
            place-items: center;
            font-family: Arial, sans-serif;
            background: #111827;
            color: #f9fafb;
        }
        main {
            width: min(700px, calc(100% - 40px));
            padding: 40px;
            box-sizing: border-box;
            background: #1f2937;
            border-radius: 16px;
        }
        .ok { color: #4ade80; font-weight: bold; }
        code { color: #93c5fd; }
    </style>
</head>
<body>
    <main>
        <h1>🌐 Serveur Web Ubuntu personnalisé</h1>
        <p class="ok">✅ Apache et PHP sont opérationnels.</p>
        <p>Serveur : <code><?= htmlspecialchars(gethostname() ?: 'Ubuntu') ?></code></p>
        <p>Version PHP : <code><?= htmlspecialchars(PHP_VERSION) ?></code></p>
        <p>Répertoire Web : <code>/var/www/html</code></p>
    </main>
</body>
</html>
EOF

PHP_VERSION="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')"
for PHP_INI in \
    "/etc/php/${PHP_VERSION}/apache2/php.ini" \
    "/etc/php/${PHP_VERSION}/cli/php.ini"
do
    [[ -f "$PHP_INI" ]] || continue
    sed -i \
        -e 's/^memory_limit = .*/memory_limit = 256M/' \
        -e 's/^upload_max_filesize = .*/upload_max_filesize = 128M/' \
        -e 's/^post_max_size = .*/post_max_size = 128M/' \
        -e 's/^max_execution_time = .*/max_execution_time = 300/' \
        -e 's/^expose_php = .*/expose_php = Off/' \
        -e 's#^;date.timezone =.*#date.timezone = Europe/Paris#' \
        "$PHP_INI"
done

apache2ctl configtest
systemctl enable apache2
systemctl restart apache2

log "Configuration MariaDB..."
systemctl enable mariadb
systemctl restart mariadb

SQL_USER="${DB_ADMIN_USER//\'/\'\'}"
SQL_PASSWORD="${DB_ADMIN_PASSWORD//\'/\'\'}"

mariadb --protocol=socket <<SQL
DELETE FROM mysql.user WHERE User = '';
DELETE FROM mysql.user
WHERE User = 'root'
  AND Host NOT IN ('localhost', '127.0.0.1', '::1');

DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db = 'test' OR Db LIKE 'test\\_%';

CREATE USER IF NOT EXISTS '${SQL_USER}'@'localhost'
IDENTIFIED BY '${SQL_PASSWORD}';

ALTER USER '${SQL_USER}'@'localhost'
IDENTIFIED BY '${SQL_PASSWORD}';

GRANT ALL PRIVILEGES ON *.* TO '${SQL_USER}'@'localhost'
WITH GRANT OPTION;

FLUSH PRIVILEGES;
SQL

MARIADB_CONFIG="/etc/mysql/mariadb.conf.d/50-server.cnf"
if grep -qE '^[[:space:]]*bind-address' "$MARIADB_CONFIG"; then
    sed -i 's/^[[:space:]]*bind-address.*/bind-address = 127.0.0.1/' "$MARIADB_CONFIG"
else
    sed -i '/^\[mysqld\]/a bind-address = 127.0.0.1' "$MARIADB_CONFIG"
fi

systemctl restart mariadb
mariadb-admin ping --silent

log "Installation de phpMyAdmin..."
echo "phpmyadmin phpmyadmin/reconfigure-webserver multiselect apache2" \
    | debconf-set-selections
echo "phpmyadmin phpmyadmin/dbconfig-install boolean false" \
    | debconf-set-selections

apt-get install -y phpmyadmin

a2disconf phpmyadmin >/dev/null 2>&1 || true

cat > /etc/apache2/conf-available/lxc-web-phpmyadmin.conf <<'EOF'
Alias /phpmyadmin /usr/share/phpmyadmin

<Directory /usr/share/phpmyadmin>
    Options SymLinksIfOwnerMatch
    DirectoryIndex index.php
    Require all granted
</Directory>

<Directory /usr/share/phpmyadmin/setup>
    Require all denied
</Directory>

<Directory /usr/share/phpmyadmin/libraries>
    Require all denied
</Directory>

<Directory /usr/share/phpmyadmin/templates>
    Require all denied
</Directory>
EOF

a2enconf lxc-web-phpmyadmin
apache2ctl configtest
systemctl reload apache2

log "Configuration des permissions de /var/www/html..."
WEB_GROUP="webdev"
getent group "$WEB_GROUP" >/dev/null 2>&1 || groupadd "$WEB_GROUP"
usermod -aG "$WEB_GROUP" "$ADMIN_USER"
usermod -aG "$WEB_GROUP" www-data

chown -R "${ADMIN_USER}:${WEB_GROUP}" /var/www/html
find /var/www/html -type d -exec chmod 2775 {} \;
find /var/www/html -type f -exec chmod 0664 {} \;

setfacl -R \
    -m "u:${ADMIN_USER}:rwx" \
    -m "u:www-data:rwx" \
    -m "g:${WEB_GROUP}:rwx" \
    /var/www/html

setfacl -R \
    -d -m "u:${ADMIN_USER}:rwx" \
    -d -m "u:www-data:rwx" \
    -d -m "g:${WEB_GROUP}:rwx" \
    -d -m "o::rx" \
    /var/www/html

log "Configuration Samba..."
awk '
    BEGIN { skip = 0 }
    /^\[/ {
        if ($0 == "[Web]") {
            skip = 1
            next
        }
        skip = 0
    }
    !skip { print }
' /etc/samba/smb.conf > /etc/samba/smb.conf.tmp
mv /etc/samba/smb.conf.tmp /etc/samba/smb.conf

cat >> /etc/samba/smb.conf <<EOF

[Web]
   comment = Répertoire Web Apache
   path = /var/www/html
   browseable = yes
   read only = no
   writable = yes
   guest ok = no
   valid users = ${ADMIN_USER}
   force user = ${ADMIN_USER}
   force group = ${WEB_GROUP}
   create mask = 0664
   force create mode = 0660
   directory mask = 2775
   force directory mode = 2770
   inherit permissions = yes
   inherit acls = yes
EOF

printf '%s\n%s\n' "$ADMIN_PASSWORD" "$ADMIN_PASSWORD" |
    smbpasswd -s -a "$ADMIN_USER"
smbpasswd -e "$ADMIN_USER"

testparm -s >/dev/null
systemctl enable smbd
systemctl restart smbd

log "Installation de code-server..."
CODE_SERVER_INSTALLER="$(mktemp)"
curl -fsSL https://code-server.dev/install.sh -o "$CODE_SERVER_INSTALLER"
chmod 700 "$CODE_SERVER_INSTALLER"
"$CODE_SERVER_INSTALLER"
rm -f "$CODE_SERVER_INSTALLER"

CODE_SERVER_CONFIG_DIR="/home/${ADMIN_USER}/.config/code-server"
mkdir -p "$CODE_SERVER_CONFIG_DIR"

cat > "${CODE_SERVER_CONFIG_DIR}/config.yaml" <<EOF
bind-addr: 0.0.0.0:8680
auth: password
password: "${CODE_SERVER_PASSWORD}"
cert: false
disable-telemetry: true
EOF

chown -R "${ADMIN_USER}:${ADMIN_USER}" "/home/${ADMIN_USER}/.config"
chmod 700 "$CODE_SERVER_CONFIG_DIR"
chmod 600 "${CODE_SERVER_CONFIG_DIR}/config.yaml"

systemctl enable --now "code-server@${ADMIN_USER}.service"
systemctl restart "code-server@${ADMIN_USER}.service"

log "Activation des mises à jour automatiques de sécurité..."
dpkg-reconfigure -f noninteractive unattended-upgrades || true
systemctl enable --now unattended-upgrades.service || true

log "Vérification des services..."
systemctl is-active --quiet ssh
systemctl is-active --quiet apache2
systemctl is-active --quiet mariadb
systemctl is-active --quiet smbd
systemctl is-active --quiet "code-server@${ADMIN_USER}.service"

curl -fsS --max-time 15 http://127.0.0.1/ >/dev/null
curl -fsS --max-time 15 http://127.0.0.1:8680/ >/dev/null
mariadb-admin ping --silent
testparm -s >/dev/null

rm -f "$CREDENTIALS_FILE"
unset \
    ADMIN_PASSWORD \
    DB_ADMIN_PASSWORD \
    CODE_SERVER_PASSWORD \
    ADMIN_PASSWORD_B64 \
    DB_ADMIN_PASSWORD_B64 \
    CODE_SERVER_PASSWORD_B64

log "Installation terminée avec succès."
INNER_SCRIPT_EOF

    chmod 700 "$INNER_SCRIPT"

    cat > "$CREDENTIALS_FILE" <<EOF
ADMIN_USER='${ADMIN_USER}'
ADMIN_PASSWORD_B64='$(printf '%s' "$ADMIN_PASSWORD" | base64 -w 0)'
DB_ADMIN_USER='${DB_ADMIN_USER}'
DB_ADMIN_PASSWORD_B64='$(printf '%s' "$DB_ADMIN_PASSWORD" | base64 -w 0)'
CODE_SERVER_PASSWORD_B64='$(printf '%s' "$CODE_SERVER_PASSWORD" | base64 -w 0)'
EOF

    chmod 600 "$CREDENTIALS_FILE"
}

start_and_prepare_container() {
    section "Démarrage et préparation du LXC"

    pct start "$CTID"

    local attempts=60
    while (( attempts > 0 )); do
        if pct exec "$CTID" -- true >/dev/null 2>&1; then
            break
        fi
        sleep 2
        ((attempts--))
    done

    if (( attempts == 0 )); then
        error "Le conteneur ne répond pas à pct exec."
        exit 1
    fi

    pct push "$CTID" "$INNER_SCRIPT" /root/install-applications.sh \
        --perms 700

    pct push "$CTID" "$CREDENTIALS_FILE" /root/.lxc-web-install-credentials \
        --perms 600

    success "Script d'installation copié dans le LXC."
}

install_applications() {
    section "Installation des applications dans le LXC"

    pct exec "$CTID" -- bash /root/install-applications.sh

    pct exec "$CTID" -- rm -f \
        /root/install-applications.sh \
        /root/.lxc-web-install-credentials

    success "Applications installées."
}

get_container_ip() {
    local ip=""

    for _ in {1..30}; do
        ip="$(
            pct exec "$CTID" -- sh -c \
                "ip -4 -o addr show dev eth0 2>/dev/null | awk '{print \$4}' | cut -d/ -f1 | head -n1" \
                2>/dev/null || true
        )"

        if [[ -n "$ip" ]]; then
            printf '%s' "$ip"
            return
        fi

        sleep 2
    done

    printf '%s' "adresse non détectée"
}

final_summary() {
    section "DÉPLOIEMENT TERMINÉ"

    local container_ip
    container_ip="$(get_container_ip)"

    cat <<EOF

LXC Proxmox
  VMID             : ${CTID}
  Nom              : ${HOSTNAME}
  Adresse IP       : ${container_ip}
  Système          : Ubuntu 24.04 LTS
  Interface        : ligne de commande uniquement

SSH / PuTTY
  Adresse          : ${container_ip}
  Port             : 22
  Utilisateur      : ${ADMIN_USER}

Apache
  http://${container_ip}

phpMyAdmin
  http://${container_ip}/phpmyadmin
  Utilisateur      : ${DB_ADMIN_USER}

Samba
  \\${container_ip}\Web
  Utilisateur      : ${ADMIN_USER}
  Répertoire       : /var/www/html

code-server
  http://${container_ip}:8680
  Compte système   : ${ADMIN_USER}

Commandes Proxmox utiles
  Ouvrir un shell  : pct enter ${CTID}
  État du LXC      : pct status ${CTID}
  Arrêter          : pct shutdown ${CTID}
  Redémarrer       : pct reboot ${CTID}

Journal Proxmox
  ${LOG_FILE}

Journal dans le LXC
  /var/log/lxc-web-applications-install.log

Les mots de passe ne sont pas affichés dans ce résumé.
EOF
}

main() {
    require_root
    require_proxmox
    require_tty

    touch "$LOG_FILE"
    chmod 600 "$LOG_FILE"
    exec > >(tee -a "$LOG_FILE") 2>&1

    section "CRÉATION D'UN LXC WEB UBUNTU 24.04 LTS"

    collect_configuration
    display_summary_and_confirm
    download_template
    create_inner_installer
    create_container
    start_and_prepare_container
    install_applications
    final_summary

    success "Le conteneur est prêt à être utilisé."
}

main "$@"
