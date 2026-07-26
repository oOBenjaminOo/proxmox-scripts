#!/usr/bin/env bash
# Création interactive d'un LXC Ubuntu 24.04 LTS sur Proxmox VE.
# Applications : Apache, PHP, MariaDB, phpMyAdmin, Samba, code-server et SSH.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

readonly BACKTITLE="Proxmox VE - LXC Web Ubuntu 24.04"
LOG_FILE="/var/log/create-lxc-web-$(date '+%Y%m%d-%H%M%S').log"
TEMP_DIR=""
CTID=""
CT_CREATION_STARTED=0

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
wt_msg(){ whiptail --backtitle "$BACKTITLE" --title "$1" --msgbox "$2" 16 78; }
wt_yesno(){ whiptail --backtitle "$BACKTITLE" --title "$1" --yesno "$2" 16 78; }
inputbox(){ local v; v=$(wt --title "$1" --inputbox "$2" 12 76 "$3") || exit 0; printf '%s' "$v"; }
passwordbox(){
  local a b
  while true; do
    a=$(wt --title "$1" --passwordbox "$2\n\nMinimum : 8 caractères." 14 76) || exit 0
    (( ${#a} >= 8 )) || { wt_msg "Valeur invalide" "Le mot de passe doit contenir au moins 8 caractères."; continue; }
    b=$(wt --title "$1" --passwordbox "Confirme le mot de passe." 12 76) || exit 0
    [[ "$a" == "$b" ]] && { printf '%s' "$a"; return; }
    wt_msg "Erreur" "Les deux mots de passe ne correspondent pas."
  done
}

require_environment(){
  [[ $EUID -eq 0 ]] || { msg_err "Exécute ce script en root sur un nœud Proxmox VE."; exit 1; }
  for cmd in pct qm pveam pvesm pvesh whiptail; do command -v "$cmd" >/dev/null 2>&1 || { msg_err "Commande manquante : $cmd"; exit 1; }; done
  [[ -r /dev/tty && -w /dev/tty ]] || { msg_err "Terminal interactif indisponible."; exit 1; }
}

storage_type(){
  local storage="$1" type=""
  type=$(pvesm status --storage "$storage" 2>/dev/null | awk 'NR==2 {print $2}') || true
  if [[ -z "$type" && -r /etc/pve/storage.cfg ]]; then
    type=$(awk -v id="$storage" '
      /^[[:alnum:]_-]+:[[:space:]]+/ {
        split($0,a,":"); current=a[2]; sub(/^[[:space:]]+/,"",current); current_type=a[1]
      }
      current==id { print current_type; exit }
    ' /etc/pve/storage.cfg 2>/dev/null) || true
  fi
  printf '%s' "$type"
  return 0
}

storage_menu(){
  local content="$1" title="$2" default="$3" storage type usage
  local rows=()
  while read -r storage; do
    [[ -z "$storage" ]] && continue
    type=$(storage_type "$storage")
    usage=$(pvesm status --storage "$storage" 2>/dev/null | awk 'NR==2 {print $6" libres sur "$4}') || true
    rows+=("$storage" "Type: ${type:-inconnu} | ${usage:-espace inconnu}")
  done < <(pvesm status -content "$content" 2>/dev/null | awk 'NR>1 && $3=="active" {print $1}' | sort -u)
  (( ${#rows[@]} > 0 )) || { wt_msg "Erreur" "Aucun stockage actif compatible avec '$content'."; exit 1; }
  wt --title "$title" --menu "Sélectionne le stockage à utiliser." 20 88 10 "${rows[@]}" --default-item "$default"
}

validate_id(){ [[ "$1" =~ ^[1-9][0-9]{2,8}$ ]] && ! pct status "$1" >/dev/null 2>&1 && ! qm status "$1" >/dev/null 2>&1; }
validate_hostname(){ [[ "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]{0,62}$ ]]; }
validate_user(){ [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; }
validate_uint(){ [[ "$1" =~ ^[0-9]+$ ]]; }
validate_cidr(){ [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$ ]]; }
validate_ip(){ [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }
ask_valid(){ local v; while true; do v=$(inputbox "$1" "$2" "$3"); "$4" "$v" && { printf '%s' "$v"; return; }; wt_msg "Valeur invalide" "La valeur saisie n'est pas valide ou est déjà utilisée."; done; }

set_defaults(){
  local host_dns
  host_dns=$(awk '/^nameserver[[:space:]]+/ && $2 !~ /^127\./ {print $2; exit}' /etc/resolv.conf 2>/dev/null || true)
  CTID=$(pvesh get /cluster/nextid 2>/dev/null || echo 100)
  HOSTNAME="ubuntu-web"; ROOTFS_STORAGE="local-lvm"; TEMPLATE_STORAGE="local"
  CPU_CORES=2; MEMORY_MB=4096; SWAP_MB=512; DISK_GB=32
  BRIDGE="vmbr0"; VLAN_TAG=0; NETWORK_MODE="dhcp"; NET_IP="dhcp"; GATEWAY=""
  DNS_SERVER="${host_dns:-1.1.1.1}"; DNS_SEARCH="local"; ONBOOT=1; UNPRIVILEGED=1
}

choose_mode(){
  MODE=$(wt --title "PARAMÈTRES" --menu "Choisis le mode de configuration.\n\nLe stockage du conteneur et celui du template seront demandés dans les deux modes." 18 80 4 \
    "1" "Paramètres par défaut" "2" "Paramètres avancés" "3" "Quitter" --default-item "1") || exit 0
  [[ "$MODE" != "3" ]] || exit 0
}

choose_storages(){
  ROOTFS_STORAGE=$(storage_menu rootdir "Stockage du conteneur" "$ROOTFS_STORAGE") || exit 0
  TEMPLATE_STORAGE=$(storage_menu vztmpl "Stockage du template" "$TEMPLATE_STORAGE") || exit 0
}

advanced_configuration(){
  CTID=$(ask_valid "VMID" "Identifiant du conteneur LXC." "$CTID" validate_id)
  HOSTNAME=$(ask_valid "Nom du conteneur" "Nom d'hôte du nouveau conteneur." "$HOSTNAME" validate_hostname)
  CPU_CORES=$(ask_valid "CPU" "Nombre de cœurs CPU." "$CPU_CORES" validate_uint)
  MEMORY_MB=$(ask_valid "Mémoire" "Mémoire vive en Mo." "$MEMORY_MB" validate_uint)
  SWAP_MB=$(ask_valid "Swap" "Mémoire swap en Mo." "$SWAP_MB" validate_uint)
  DISK_GB=$(ask_valid "Disque" "Taille du disque racine en Go." "$DISK_GB" validate_uint)
  BRIDGE=$(inputbox "Bridge réseau" "Bridge Proxmox utilisé par le conteneur." "$BRIDGE")
  VLAN_TAG=$(ask_valid "VLAN" "Tag VLAN. Utilise 0 pour aucun VLAN." "$VLAN_TAG" validate_uint)
  if wt_yesno "Réseau" "Utiliser une adresse IPv4 attribuée par DHCP ?"; then NETWORK_MODE="dhcp"; NET_IP="dhcp"; GATEWAY=""; else
    NETWORK_MODE="static"
    NET_IP=$(ask_valid "Adresse IPv4" "Adresse IPv4 avec préfixe." "192.168.1.50/24" validate_cidr)
    GATEWAY=$(ask_valid "Passerelle" "Passerelle IPv4." "192.168.1.1" validate_ip)
  fi
  DNS_SERVER=$(ask_valid "DNS" "Serveur DNS IPv4." "$DNS_SERVER" validate_ip)
  DNS_SEARCH=$(inputbox "Recherche DNS" "Domaine de recherche DNS." "$DNS_SEARCH")
  wt_yesno "Démarrage automatique" "Démarrer automatiquement le conteneur avec Proxmox ?" && ONBOOT=1 || ONBOOT=0
  wt_yesno "Isolation" "Créer un conteneur non privilégié ?\n\nC'est le choix recommandé." && UNPRIVILEGED=1 || UNPRIVILEGED=0
}

validate_storage_combination(){
  local type
  while true; do
    type=$(storage_type "$ROOTFS_STORAGE")
    if (( UNPRIVILEGED == 1 )) && [[ "$type" == "nfs" || "$type" == "cifs" ]]; then
      wt_msg "Stockage incompatible" "Le stockage racine '$ROOTFS_STORAGE' est de type '$type'.\n\nUn LXC non privilégié peut échouer sur ce type de partage. Sélectionne un stockage local compatible. Le template peut rester sur le NAS."
      ROOTFS_STORAGE=$(storage_menu rootdir "Choisir un autre stockage racine" "local-lvm") || exit 0
      continue
    fi
    break
  done
}

credentials_configuration(){
  CT_ROOT_PASSWORD=$(passwordbox "Mot de passe root" "Mot de passe du compte root du conteneur.")
  while true; do ADMIN_USER=$(inputbox "Utilisateur Linux" "Compte utilisé pour SSH, Samba et code-server." "admin"); validate_user "$ADMIN_USER" && break; wt_msg "Nom invalide" "Utilise des minuscules, chiffres, tirets ou underscores."; done
  ADMIN_PASSWORD=$(passwordbox "Mot de passe Linux" "Mot de passe du compte '$ADMIN_USER'.")
  while true; do DB_ADMIN_USER=$(inputbox "Utilisateur MariaDB" "Compte administrateur MariaDB/phpMyAdmin." "dbadmin"); validate_user "$DB_ADMIN_USER" && break; wt_msg "Nom invalide" "Utilise des minuscules, chiffres, tirets ou underscores."; done
  DB_ADMIN_PASSWORD=$(passwordbox "Mot de passe MariaDB" "Mot de passe du compte '$DB_ADMIN_USER'.")
  CODE_SERVER_PASSWORD=$(passwordbox "Mot de passe code-server" "Mot de passe de l'interface Web code-server.")
}

confirm_configuration(){
  local privilege startup
  (( UNPRIVILEGED == 1 )) && privilege="Non privilégié" || privilege="Privilégié"
  (( ONBOOT == 1 )) && startup="Oui" || startup="Non"
  wt_yesno "CONFIRMATION" "VMID : $CTID\nNom : $HOSTNAME\nStockage racine : $ROOTFS_STORAGE\nStockage template : $TEMPLATE_STORAGE\nCPU : $CPU_CORES\nRAM : $MEMORY_MB Mo\nDisque : $DISK_GB Go\nBridge : $BRIDGE\nRéseau : $NETWORK_MODE\nDNS : $DNS_SERVER\nIsolation : $privilege\nDémarrage automatique : $startup\n\nCréer maintenant ce conteneur ?" || exit 0
}

download_template(){
  msg_info "Recherche du template Ubuntu 24.04..."
  pveam update >/dev/null
  TEMPLATE_NAME=$(pveam available --section system | awk '$2 ~ /^ubuntu-24\.04-standard_.*_amd64\.tar\.(zst|xz|gz)$/ {print $2}' | sort -V | tail -n1)
  [[ -n "$TEMPLATE_NAME" ]] || { msg_err "Template Ubuntu 24.04 introuvable."; exit 1; }
  TEMPLATE_VOLUME="${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE_NAME}"
  if ! pveam list "$TEMPLATE_STORAGE" | awk 'NR>1 {print $1}' | grep -qx "$TEMPLATE_VOLUME"; then msg_info "Téléchargement de $TEMPLATE_NAME..."; pveam download "$TEMPLATE_STORAGE" "$TEMPLATE_NAME"; fi
  msg_ok "Template prêt."
}

create_container(){
  local net0="name=eth0,bridge=${BRIDGE},ip=${NET_IP},firewall=1,type=veth"
  [[ "$NETWORK_MODE" == "static" ]] && net0+=",gw=${GATEWAY}"
  (( VLAN_TAG > 0 )) && net0+=",tag=${VLAN_TAG}"
  msg_info "Création du conteneur LXC $CTID..."; CT_CREATION_STARTED=1
  pct create "$CTID" "$TEMPLATE_VOLUME" --hostname "$HOSTNAME" --ostype ubuntu --arch amd64 \
    --cores "$CPU_CORES" --memory "$MEMORY_MB" --swap "$SWAP_MB" --rootfs "${ROOTFS_STORAGE}:${DISK_GB}" \
    --net0 "$net0" --nameserver "$DNS_SERVER" --searchdomain "$DNS_SEARCH" --password "$CT_ROOT_PASSWORD" \
    --unprivileged "$UNPRIVILEGED" --features "nesting=1,keyctl=1" --onboot "$ONBOOT" --start 0 \
    --description "LXC Ubuntu 24.04 LTS - Apache, PHP, MariaDB, phpMyAdmin, Samba, code-server et SSH"
  msg_ok "Conteneur créé."
}

build_installer(){
  TEMP_DIR=$(mktemp -d); INNER_SCRIPT="$TEMP_DIR/install.sh"; CREDS="$TEMP_DIR/credentials.env"
  cat > "$CREDS" <<EOF2
ADMIN_USER='$ADMIN_USER'
ADMIN_PASSWORD_B64='$(printf '%s' "$ADMIN_PASSWORD" | base64 -w0)'
DB_ADMIN_USER='$DB_ADMIN_USER'
DB_ADMIN_PASSWORD_B64='$(printf '%s' "$DB_ADMIN_PASSWORD" | base64 -w0)'
CODE_SERVER_PASSWORD_B64='$(printf '%s' "$CODE_SERVER_PASSWORD" | base64 -w0)'
DNS_SERVER='$DNS_SERVER'
EOF2
  chmod 600 "$CREDS"
  cat > "$INNER_SCRIPT" <<'INNER'
#!/usr/bin/env bash
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
exec > >(tee -a /var/log/lxc-web-applications-install.log) 2>&1
source /root/.lxc-web-install-credentials
ADMIN_PASSWORD=$(printf '%s' "$ADMIN_PASSWORD_B64" | base64 -d)
DB_ADMIN_PASSWORD=$(printf '%s' "$DB_ADMIN_PASSWORD_B64" | base64 -d)
CODE_SERVER_PASSWORD=$(printf '%s' "$CODE_SERVER_PASSWORD_B64" | base64 -d)

printf '[RÉSEAU] Attente d’une adresse IPv4 et d’une route par défaut...\n'
for _ in {1..60}; do
  if ip -4 -o addr show dev eth0 | grep -q 'inet ' && ip route show default | grep -q '^default '; then
    break
  fi
  sleep 2
done
ip -4 -o addr show dev eth0 | grep -q 'inet ' || { echo 'ERREUR : aucune adresse IPv4 obtenue sur eth0.'; exit 1; }
ip route show default | grep -q '^default ' || { echo 'ERREUR : aucune route par défaut disponible.'; exit 1; }

printf 'nameserver %s\noptions timeout:2 attempts:2\n' "$DNS_SERVER" > /etc/resolv.conf
printf '[RÉSEAU] Vérification de la résolution DNS...\n'
for _ in {1..30}; do
  getent ahostsv4 archive.ubuntu.com >/dev/null 2>&1 && break
  sleep 2
done
getent ahostsv4 archive.ubuntu.com >/dev/null 2>&1 || {
  echo "ERREUR : impossible de résoudre archive.ubuntu.com avec le DNS $DNS_SERVER."
  echo 'Adresse IPv4 :'; ip -4 addr show dev eth0 || true
  echo 'Route :'; ip route || true
  echo 'DNS :'; cat /etc/resolv.conf || true
  exit 1
}

apt-get update
apt-get full-upgrade -y
apt-get install -y acl apache2 ca-certificates curl debconf-utils libapache2-mod-php mariadb-client mariadb-server openssh-server php php-apcu php-bcmath php-cli php-common php-curl php-gd php-imagick php-intl php-mbstring php-mysql php-opcache php-soap php-xml php-zip samba samba-common-bin sudo unattended-upgrades
id "$ADMIN_USER" >/dev/null 2>&1 || useradd --create-home --shell /bin/bash "$ADMIN_USER"
printf '%s:%s\n' "$ADMIN_USER" "$ADMIN_PASSWORD" | chpasswd
usermod -aG sudo "$ADMIN_USER"
mkdir -p /etc/ssh/sshd_config.d
printf 'PasswordAuthentication yes\nKbdInteractiveAuthentication no\nPermitRootLogin no\nUsePAM yes\n' > /etc/ssh/sshd_config.d/99-lxc-web.conf
sshd -t; systemctl enable --now ssh
a2enmod rewrite headers expires ssl
rm -f /var/www/html/index.html
cat > /var/www/html/index.php <<'PHP'
<!doctype html><html lang="fr"><head><meta charset="utf-8"><title>Serveur Web Ubuntu</title></head><body><h1>Serveur Web Ubuntu</h1><p>Apache et PHP sont opérationnels.</p></body></html>
PHP
systemctl enable --now apache2
systemctl enable --now mariadb
SQL_USER=${DB_ADMIN_USER//\'/\'\'}; SQL_PASSWORD=${DB_ADMIN_PASSWORD//\'/\'\'}
mariadb --protocol=socket <<SQL
CREATE USER IF NOT EXISTS '${SQL_USER}'@'localhost' IDENTIFIED BY '${SQL_PASSWORD}';
ALTER USER '${SQL_USER}'@'localhost' IDENTIFIED BY '${SQL_PASSWORD}';
GRANT ALL PRIVILEGES ON *.* TO '${SQL_USER}'@'localhost' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL
echo "phpmyadmin phpmyadmin/reconfigure-webserver multiselect apache2" | debconf-set-selections
echo "phpmyadmin phpmyadmin/dbconfig-install boolean false" | debconf-set-selections
apt-get install -y phpmyadmin
getent group webdev >/dev/null || groupadd webdev
usermod -aG webdev "$ADMIN_USER"; usermod -aG webdev www-data
chown -R "$ADMIN_USER:webdev" /var/www/html
find /var/www/html -type d -exec chmod 2775 {} \;
find /var/www/html -type f -exec chmod 0664 {} \;
cat >> /etc/samba/smb.conf <<EOF3

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
EOF3
printf '%s\n%s\n' "$ADMIN_PASSWORD" "$ADMIN_PASSWORD" | smbpasswd -s -a "$ADMIN_USER"
systemctl enable --now smbd
installer=$(mktemp); curl -fsSL https://code-server.dev/install.sh -o "$installer"; chmod 700 "$installer"; "$installer"; rm -f "$installer"
mkdir -p "/home/$ADMIN_USER/.config/code-server"
cat > "/home/$ADMIN_USER/.config/code-server/config.yaml" <<EOF4
bind-addr: 0.0.0.0:8680
auth: password
password: "$CODE_SERVER_PASSWORD"
cert: false
disable-telemetry: true
EOF4
chown -R "$ADMIN_USER:$ADMIN_USER" "/home/$ADMIN_USER/.config"
chmod 600 "/home/$ADMIN_USER/.config/code-server/config.yaml"
systemctl enable --now "code-server@$ADMIN_USER.service"
rm -f /root/.lxc-web-install-credentials
INNER
  chmod 700 "$INNER_SCRIPT"
}

install_inside_container(){
  msg_info "Démarrage du conteneur..."; pct start "$CTID"
  for _ in {1..60}; do pct exec "$CTID" -- true >/dev/null 2>&1 && break; sleep 2; done
  pct exec "$CTID" -- true >/dev/null 2>&1 || { msg_err "Le conteneur ne répond pas."; exit 1; }
  pct push "$CTID" "$INNER_SCRIPT" /root/install-applications.sh --perms 700
  pct push "$CTID" "$CREDS" /root/.lxc-web-install-credentials --perms 600
  msg_info "Installation des applications..."
  pct exec "$CTID" -- bash /root/install-applications.sh
  pct exec "$CTID" -- rm -f /root/install-applications.sh /root/.lxc-web-install-credentials
  msg_ok "Applications installées."
}

container_ip(){ pct exec "$CTID" -- sh -c "ip -4 -o addr show dev eth0 | awk '{print \$4}' | cut -d/ -f1 | head -n1" 2>/dev/null || true; }
finish(){
  local ip; ip=$(container_ip); ip=${ip:-"adresse non détectée"}; CT_CREATION_STARTED=0
  wt_msg "INSTALLATION TERMINÉE" "Le conteneur est prêt.\n\nVMID : $CTID\nNom : $HOSTNAME\nAdresse IP : $ip\n\nApache : http://$ip\nphpMyAdmin : http://$ip/phpmyadmin\ncode-server : http://$ip:8680\nSamba : \\\\$ip\\Web\nSSH : $ADMIN_USER@$ip\n\nJournal : $LOG_FILE"
  msg_ok "LXC $CTID prêt : http://$ip"
}

main(){
  require_environment
  touch "$LOG_FILE"; chmod 600 "$LOG_FILE"; exec > >(tee -a "$LOG_FILE") 2>&1
  set_defaults
  choose_mode
  choose_storages
  [[ "$MODE" == "2" ]] && advanced_configuration
  validate_storage_combination
  credentials_configuration
  confirm_configuration
  download_template
  build_installer
  create_container
  install_inside_container
  finish
}
main "$@"
