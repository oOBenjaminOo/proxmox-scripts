# Proxmox Scripts

Une collection de scripts Bash permettant d'automatiser le déploiement de conteneurs LXC et de machines virtuelles sur Proxmox VE.

## Script disponible

### create-lxc-ubuntu2404-web.sh

Création automatisée d'un conteneur **Ubuntu 24.04 LTS** avec installation et configuration de :

- Apache 2
- PHP
- MariaDB
- phpMyAdmin
- Samba
- code-server
- OpenSSH Server

Le script :

- télécharge automatiquement le template Ubuntu si nécessaire ;
- crée le conteneur LXC ;
- configure le réseau (DHCP ou IP fixe) ;
- installe l'ensemble des services ;
- applique une configuration sécurisée ;
- affiche un récapitulatif complet en fin d'installation.

## Exécution

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/oOBenjaminOo/proxmox-scripts/main/create-lxc-ubuntu2404-web.sh)"
```

## Prérequis

- Proxmox VE 8 ou supérieur
- Exécution en tant que root sur un nœud Proxmox
- Accès Internet pour télécharger les paquets nécessaires

## Licence

Ce projet est distribué sous licence MIT. Consultez le fichier LICENSE pour plus d'informations.
