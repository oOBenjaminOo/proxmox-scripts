#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

readonly BACKTITLE="Proxmox VE - LXC Web Ubuntu 24.04"
LOG_FILE="/var/log/create-lxc-web-$(date '+%Y%m%d-%H%M%S').log"
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
wt_msg(){ whiptail --backtitle "$BACKTITLE" --title "$1" --msgbox "$2" 17 80; }
wt_yesno(){ whiptail --backtitle "$BACKTITLE" --title "$1" --yesno "$2" 17 80; }
inputbox(){ local v; v=$(wt --title "$1" --inputbox "$2" 12 76 "$3") || exit 0; printf '%s' "$v"; }
passwordbox(){ local a b; while true; do a=$(wt --title "$1" --passwordbox "$2\n\nMinimum : 8 caractères." 14 76) || exit 0; (( ${#a} >= 8 )) || { wt_msg "Valeur invalide" "Le mot de passe doit contenir au moins 8 caractères."; continue; }; b=$(wt --title "$1" --passwordbox "Confirme le mot de passe." 12 76) || exit 0; [[ "$a" == "$b" ]] && { printf '%s' "$a"; return; }; wt_msg "Erreur" "Les deux mots de passe ne correspondent pas."; done; }
require_environment(){ [[ $EUID -eq 0 ]] || { msg_err "Exécute ce script en root sur Proxmox VE."; exit 1; }; for c in pct qm pveam pvesm pvesh whiptail od tr; do command -v "$c" >/dev/null || { msg_err "Commande manquante : $c"; exit 1; }; done; }
storage_type(){ local s="$1" t=""; t=$(pvesm status --storage "$s" 2>/dev/null | awk 'NR==2 {print $2}') || true; [[ -n "$t" ]] || t=$(awk -v id="$s" '/^[[:alnum:]_-]+:[[:space:]]+/ {split($0,a,":"); cur=a[2]; sub(/^[[:space:]]+/,"",cur); typ=a[1]} cur==id {print typ; exit}' /etc/pve/storage.cfg 2>/dev/null || true); printf '%s' "$t"; }
storage_menu(){
  local content="$1" title="$2" def="$3" s t u state selected; local rows=()
  while read -r s; do [[ -z "$s" ]] && continue; t=$(storage_type "$s"); u=$(pvesm status --storage "$s" 2>/dev/null | awk 'NR==2 {print $6" libres"}') || true; [[ "$s" == "$def" ]] && state=ON || state=OFF; rows+=("$s" "Type: ${t:-inconnu} | ${u:-espace inconnu}" "$state"); done < <(pvesm status -content "$content" 2>/dev/null | awk 'NR>1 && $3=="active" {print $1}' | sort -u)
  (( ${#rows[@]} )) || { wt_msg "Erreur" "Aucun stockage compatible avec $content."; exit 1; }
  selected=$(wt --title "$title" --radiolist "Sélectionne un stockage.\n\n↑/↓ : déplacer   Espace : cocher   Tab : OK   Entrée : valider" 22 94 12 "${rows[@]}") || exit 0
  selected=${selected//\"/}
  [[ -n "$selected" ]] || { wt_msg "Sélection obligatoire" "Coche un stockage avec la barre espace."; storage_menu "$content" "$title" "$def"; return; }
  printf '%s' "$selected"
}
validate_id(){ [[ "$1" =~ ^[1-9][0-9]{2,8}$ ]] && ! pct status "$1" >/dev/null 2>&1 && ! qm status "$1" >/dev/null 2>&1; }
validate_hostname(){ [[ "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]{0,62}$ ]]; }
validate_user(){ [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; }
validate_uint(){ [[ "$1" =~ ^[0-9]+$ ]]; }
validate_ip(){ [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }
validate_cidr(){ [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$ ]]; }
ask_valid(){ local v; while true; do v=$(inputbox "$1" "$2" "$3"); "$4" "$v" && { printf '%s' "$v"; return; }; wt_msg "Valeur invalide" "La valeur saisie est invalide ou déjà utilisée."; done; }
random_password(){ od -An -N12 -tx1 /dev/urandom | tr -d ' \n'; }
set_defaults(){ CTID=$(pvesh get /cluster/nextid 2>/dev/null || echo 100); HOSTNAME="ubuntu-web"; ROOTFS_STORAGE="local-lvm"; TEMPLATE_STORAGE="local"; CPU_CORES=2; MEMORY_MB=4096; SWAP_MB=512; DISK_GB=32; BRIDGE="vmbr0"; VLAN_TAG=0; NETWORK_MODE="dhcp"; NET_IP="dhcp"; GATEWAY=""; DNS_SERVER="8.8.8.8"; ONBOOT=1; UNPRIVILEGED=1; FIREWALL=0; ADMIN_USER="admin"; DB_ADMIN_USER="dbadmin"; }
choose_mode(){ MODE=$(wt --title "PARAMÈTRES" --radiolist "Choisis le mode.\n\n↑/↓ : déplacer   Espace : cocher   Tab : OK   Entrée : valider" 19 88 5 "1" "Paramètres par défaut — identifiants générés automatiquement" ON "2" "Paramètres avancés — configuration et identifiants personnalisés" OFF "3" "Quitter" OFF) || exit 0; MODE=${MODE//\"/}; [[ -n "$MODE" ]] || { wt_msg "Sélection obligatoire" "Coche un choix avec la barre espace."; choose_mode; return; }; case "$MODE" in 1|2) ;; 3) exit 0 ;; *) wt_msg "Erreur" "Mode invalide : $MODE"; exit 1 ;; esac; }
choose_storages(){ ROOTFS_STORAGE=$(storage_menu rootdir "Stockage du conteneur" "$ROOTFS_STORAGE") || exit 0; TEMPLATE_STORAGE=$(storage_menu vztmpl "Stockage du template" "$TEMPLATE_STORAGE") || exit 0; }
advanced_configuration(){ CTID=$(ask_valid "VMID" "Identifiant du conteneur." "$CTID" validate_id); HOSTNAME=$(ask_valid "Nom" "Nom d'hôte du conteneur." "$HOSTNAME" validate_hostname); CPU_CORES=$(ask_valid "CPU" "Nombre de cœurs." "$CPU_CORES" validate_uint); MEMORY_MB=$(ask_valid "RAM" "Mémoire en Mo." "$MEMORY_MB" validate_uint); SWAP_MB=$(ask_valid "Swap" "Swap en Mo." "$SWAP_MB" validate_uint); DISK_GB=$(ask_valid "Disque" "Taille en Go." "$DISK_GB" validate_uint); BRIDGE=$(inputbox "Bridge" "Bridge Proxmox." "$BRIDGE"); VLAN_TAG=$(ask_valid "VLAN" "0 pour aucun VLAN." "$VLAN_TAG" validate_uint); if wt_yesno "Réseau" "Utiliser DHCP ?"; then NETWORK_MODE=dhcp; NET_IP=dhcp; GATEWAY=""; else NETWORK_MODE=static; NET_IP=$(ask_valid "IPv4" "Adresse avec préfixe." "192.168.1.50/24" validate_cidr); GATEWAY=$(ask_valid "Passerelle" "Passerelle IPv4." "192.168.1.1" validate_ip); fi; DNS_SERVER=$(ask_valid "DNS" "Serveur DNS IPv4." "$DNS_SERVER" validate_ip); wt_yesno "Pare-feu" "Activer le pare-feu Proxmox sur l'interface ?" && FIREWALL=1 || FIREWALL=0; wt_yesno "Démarrage" "Démarrer automatiquement avec Proxmox ?" && ONBOOT=1 || ONBOOT=0; wt_yesno "Isolation" "Créer un LXC non privilégié ?" && UNPRIVILEGED=1 || UNPRIVILEGED=0; }
validate_bridge(){ ip link show "$BRIDGE" >/dev/null 2>&1 || { wt_msg "Bridge introuvable" "Le bridge $BRIDGE n'existe pas."; exit 1; }; }
validate_storage(){ local t; while true; do t=$(storage_type "$ROOTFS_STORAGE"); if (( UNPRIVILEGED )) && [[ "$t" == nfs || "$t" == cifs ]]; then wt_msg "Stockage incompatible" "Un LXC non privilégié peut échouer sur $ROOTFS_STORAGE ($t). Choisis un stockage local."; ROOTFS_STORAGE=$(storage_menu rootdir "Autre stockage racine" local-lvm) || exit 0; else break; fi; done; }
advanced_credentials(){ CT_ROOT_PASSWORD=$(passwordbox "Mot de passe root" "Mot de passe root du conteneur."); while true; do ADMIN_USER=$(inputbox "Utilisateur Linux" "Compte SSH, Samba et code-server." admin); validate_user "$ADMIN_USER" && break; wt_msg "Nom invalide" "Nom Linux invalide."; done; ADMIN_PASSWORD=$(passwordbox "Mot de passe Linux" "Mot de passe de $ADMIN_USER."); while true; do DB_ADMIN_USER=$(inputbox "Utilisateur MariaDB" "Compte MariaDB/phpMyAdmin." dbadmin); validate_user "$DB_ADMIN_USER" && break; wt_msg "Nom invalide" "Nom MariaDB invalide."; done; DB_ADMIN_PASSWORD=$(passwordbox "Mot de passe MariaDB" "Mot de passe de $DB_ADMIN_USER."); CODE_SERVER_PASSWORD=$(passwordbox "Mot de passe code-server" "Mot de passe Web code-server."); }
default_credentials(){ ADMIN_USER="admin"; DB_ADMIN_USER="dbadmin"; CT_ROOT_PASSWORD=$(random_password); ADMIN_PASSWORD=$(random_password); DB_ADMIN_PASSWORD=$(random_password); CODE_SERVER_PASSWORD=$(random_password); msg_ok "Identifiants sécurisés générés automatiquement pour le mode par défaut."; }
confirm(){ local credential_mode; [[ "$MODE" == 1 ]] && credential_mode="Générés automatiquement et inscrits dans les notes Proxmox" || credential_mode="Personnalisés"; wt_yesno "CONFIRMATION" "VMID : $CTID\nNom : $HOSTNAME\nStockage racine : $ROOTFS_STORAGE\nTemplate : $TEMPLATE_STORAGE\nCPU : $CPU_CORES\nRAM : $MEMORY_MB Mo\nDisque : $DISK_GB Go\nBridge : $BRIDGE\nRéseau : $NETWORK_MODE\nDNS : $DNS_SERVER\nUtilisateur Linux : $ADMIN_USER\nUtilisateur MariaDB : $DB_ADMIN_USER\nIdentifiants : $credential_mode\n\nCréer le conteneur ?" || exit 0; }
download_template(){ msg_info "Recherche du template Ubuntu 24.04..."; pveam update >/dev/null; TEMPLATE_NAME=$(pveam available --section system | awk '$2 ~ /^ubuntu-24\.04-standard_.*_amd64\.tar\.(zst|xz|gz)$/ {print $2}' | sort -V | tail -n1); [[ -n "$TEMPLATE_NAME" ]] || { msg_err "Template introuvable."; exit 1; }; TEMPLATE_VOLUME="${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE_NAME}"; pveam list "$TEMPLATE_STORAGE" | awk 'NR>1 {print $1}' | grep -qx "$TEMPLATE_VOLUME" || pveam download "$TEMPLATE_STORAGE" "$TEMPLATE_NAME"; msg_ok "Template prêt."; }
create_container(){
  local net0="name=eth0,bridge=${BRIDGE},ip=${NET_IP},firewall=${FIREWALL},type=veth"
  local previous_umask
  [[ "$NETWORK_MODE" == dhcp ]] && net0+=",ip6=dhcp"
  [[ "$NETWORK_MODE" == static ]] && net0+=",gw=${GATEWAY}"
  (( VLAN_TAG > 0 )) && net0+=",tag=${VLAN_TAG}"
  msg_info "Création du conteneur LXC $CTID..."
  CT_CREATION_STARTED=1
  previous_umask=$(umask)
  umask 022
  pct create "$CTID" "$TEMPLATE_VOLUME" --hostname "$HOSTNAME" --ostype ubuntu --arch amd64 --cores "$CPU_CORES" --memory "$MEMORY_MB" --swap "$SWAP_MB" --rootfs "${ROOTFS_STORAGE}:${DISK_GB}" --net0 "$net0" --nameserver "$DNS_SERVER" --password "$CT_ROOT_PASSWORD" --unprivileged "$UNPRIVILEGED" --features "nesting=1,keyctl=1" --onboot "$ONBOOT" --start 0
  umask "$previous_umask"
  msg_ok "Conteneur créé."
  msg_info "Configuration réseau Proxmox : $(pct config "$CTID" | sed -n 's/^net0: //p')"
}
build_installer(){ TEMP_DIR=$(mktemp -d); INNER_SCRIPT="$TEMP_DIR/install.sh"; CREDS="$TEMP_DIR/credentials.env"; cat >"$CREDS" <<EOF
ADMIN_USER='$ADMIN_USER'
ADMIN_PASSWORD_B64='$(printf %s "$ADMIN_PASSWORD" | base64 -w0)'
DB_ADMIN_USER='$DB_ADMIN_USER'
DB_ADMIN_PASSWORD_B64='$(printf %s "$DB_ADMIN_PASSWORD" | base64 -w0)'
CODE_SERVER_PASSWORD_B64='$(printf %s "$CODE_SERVER_PASSWORD" | base64 -w0)'
DNS_SERVER='$DNS_SERVER'
EOF
chmod 600 "$CREDS"; cat >"$INNER_SCRIPT" <<'INNER'
#!/usr/bin/env bash
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
source /root/.lxc-web-install-credentials
ADMIN_PASSWORD=$(printf %s "$ADMIN_PASSWORD_B64" | base64 -d)
DB_ADMIN_PASSWORD=$(printf %s "$DB_ADMIN_PASSWORD_B64" | base64 -d)
CODE_SERVER_PASSWORD=$(printf %s "$CODE_SERVER_PASSWORD_B64" | base64 -d)

printf '[RÉSEAU] Attente de la configuration IPv4 native de Proxmox...\n'
for _ in {1..60}; do
  if ip -4 -o addr show dev eth0 scope global | grep -q 'inet ' && ip route show default | grep -q '^default '; then
    break
  fi
  sleep 2
done
ip -4 -o addr show dev eth0 scope global | grep -q 'inet ' || { echo 'ERREUR : aucune IPv4 obtenue.'; ip link show eth0 || true; ip addr show eth0 || true; ip route || true; systemctl status systemd-networkd --no-pager || true; networkctl status eth0 --no-pager || true; stat /etc/systemd/network/eth0.network 2>/dev/null || true; cat /etc/systemd/network/eth0.network 2>/dev/null || true; journalctl -u systemd-networkd --no-pager -n 100 || true; exit 1; }
ip route show default | grep -q '^default ' || { echo 'ERREUR : aucune route par défaut.'; ip route; exit 1; }
printf 'nameserver %s\noptions timeout:2 attempts:2\n' "$DNS_SERVER" > /etc/resolv.conf
getent ahostsv4 archive.ubuntu.com >/dev/null || { echo "ERREUR DNS avec $DNS_SERVER"; exit 1; }
apt-get update
apt-get full-upgrade -y
apt-get install -y acl apache2 ca-certificates curl debconf-utils libapache2-mod-php mariadb-client mariadb-server openssh-server php php-apcu php-bcmath php-cli php-common php-curl php-gd php-imagick php-intl php-mbstring php-mysql php-opcache php-soap php-xml php-zip samba samba-common-bin sudo unattended-upgrades
id "$ADMIN_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash "$ADMIN_USER"
printf '%s:%s\n' "$ADMIN_USER" "$ADMIN_PASSWORD" | chpasswd
usermod -aG sudo "$ADMIN_USER"
mkdir -p /etc/ssh/sshd_config.d
printf 'PasswordAuthentication yes\nPermitRootLogin no\nUsePAM yes\n' >/etc/ssh/sshd_config.d/99-lxc-web.conf
systemctl enable --now ssh apache2 mariadb
rm -f /var/www/html/index.html
printf '%s\n' '<!doctype html><html lang="fr"><meta charset="utf-8"><title>Serveur Web Ubuntu</title><h1>Serveur Web Ubuntu</h1><p>Apache et PHP sont opérationnels.</p>' >/var/www/html/index.php
SQL_USER=${DB_ADMIN_USER//\'/\'\'}; SQL_PASSWORD=${DB_ADMIN_PASSWORD//\'/\'\'}
mariadb <<SQL
CREATE USER IF NOT EXISTS '${SQL_USER}'@'localhost' IDENTIFIED BY '${SQL_PASSWORD}';
GRANT ALL PRIVILEGES ON *.* TO '${SQL_USER}'@'localhost' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL
echo 'phpmyadmin phpmyadmin/reconfigure-webserver multiselect apache2' | debconf-set-selections
echo 'phpmyadmin phpmyadmin/dbconfig-install boolean false' | debconf-set-selections
apt-get install -y phpmyadmin
getent group webdev >/dev/null || groupadd webdev
usermod -aG webdev "$ADMIN_USER"; usermod -aG webdev www-data
chown -R "$ADMIN_USER:webdev" /var/www/html
find /var/www/html -type d -exec chmod 2775 {} \;
find /var/www/html -type f -exec chmod 0664 {} \;
cat >>/etc/samba/smb.conf <<SMB
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
printf '%s\n%s\n' "$ADMIN_PASSWORD" "$ADMIN_PASSWORD" | smbpasswd -s -a "$ADMIN_USER"
systemctl enable --now smbd
installer=$(mktemp); curl -fsSL https://code-server.dev/install.sh -o "$installer"; chmod 700 "$installer"; "$installer"; rm -f "$installer"
mkdir -p "/home/$ADMIN_USER/.config/code-server"
cat >"/home/$ADMIN_USER/.config/code-server/config.yaml" <<CFG
bind-addr: 0.0.0.0:8680
auth: password
password: "$CODE_SERVER_PASSWORD"
cert: false
disable-telemetry: true
CFG
chown -R "$ADMIN_USER:$ADMIN_USER" "/home/$ADMIN_USER/.config"
chmod 600 "/home/$ADMIN_USER/.config/code-server/config.yaml"
systemctl enable --now "code-server@$ADMIN_USER.service"
rm -f /root/.lxc-web-install-credentials
INNER
chmod 700 "$INNER_SCRIPT"; }
install_inside(){ msg_info "Démarrage du conteneur..."; pct start "$CTID"; for _ in {1..60}; do pct exec "$CTID" -- true >/dev/null 2>&1 && break; sleep 2; done; pct exec "$CTID" -- true >/dev/null 2>&1 || { msg_err "Le conteneur ne répond pas."; exit 1; }; pct push "$CTID" "$INNER_SCRIPT" /root/install-applications.sh --perms 700; pct push "$CTID" "$CREDS" /root/.lxc-web-install-credentials --perms 600; msg_info "Installation des applications..."; pct exec "$CTID" -- bash /root/install-applications.sh; pct exec "$CTID" -- rm -f /root/install-applications.sh /root/.lxc-web-install-credentials; msg_ok "Applications installées."; }
container_ip(){ pct exec "$CTID" -- sh -c "ip -4 -o addr show dev eth0 scope global | awk '{print \\$4}' | cut -d/ -f1 | head -n1" 2>/dev/null || true; }
escape_notes(){ local v="$1"; v=${v//&/&amp;}; v=${v//</&lt;}; v=${v//>/&gt;}; printf '%s' "$v"; }
write_notes(){ local ip="$1" h au ap du dp cp rp notes; h=$(escape_notes "$HOSTNAME"); au=$(escape_notes "$ADMIN_USER"); ap=$(escape_notes "$ADMIN_PASSWORD"); du=$(escape_notes "$DB_ADMIN_USER"); dp=$(escape_notes "$DB_ADMIN_PASSWORD"); cp=$(escape_notes "$CODE_SERVER_PASSWORD"); rp=$(escape_notes "$CT_ROOT_PASSWORD"); notes="<div align='center'>

# ${h}

</div>

## Services
- Apache — http://${ip}
- PHP 8.3
- MariaDB
- phpMyAdmin — http://${ip}/phpmyadmin
- code-server / VS Code — http://${ip}:8680
- Serveur SMB — \\\\${ip}\\Web
- SSH — port 22

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
"; pct set "$CTID" --description "$notes" >/dev/null; msg_ok "Notes Proxmox renseignées."; }
finish(){ local ip; ip=$(container_ip); ip=${ip:-adresse_non_detectee}; write_notes "$ip"; CT_CREATION_STARTED=0; wt_msg "INSTALLATION TERMINÉE" "Conteneur prêt.\n\nVMID : $CTID\nNom : $HOSTNAME\nIP : $ip\n\nApache : http://$ip\nphpMyAdmin : http://$ip/phpmyadmin\ncode-server : http://$ip:8680\nSamba : \\\\$ip\\Web\nSSH : $ADMIN_USER@$ip"; msg_ok "LXC $CTID prêt : http://$ip"; }
main(){ require_environment; touch "$LOG_FILE"; chmod 600 "$LOG_FILE"; exec > >(tee -a "$LOG_FILE") 2>&1; set_defaults; choose_mode; choose_storages; case "$MODE" in 1) default_credentials ;; 2) advanced_configuration; advanced_credentials ;; *) msg_err "Mode invalide : $MODE"; exit 1 ;; esac; validate_bridge; validate_storage; confirm; download_template; build_installer; create_container; install_inside; finish; }
main "$@"
