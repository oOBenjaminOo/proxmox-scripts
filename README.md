# Proxmox Scripts

Collection de scripts Bash permettant d'automatiser le déploiement de conteneurs LXC sur Proxmox VE.

## Scripts disponibles

### `create-lxc-ubuntu2404-web.sh`

Ce script crée automatiquement un conteneur LXC sous **Ubuntu 24.04 LTS** et installe un environnement complet pour héberger et administrer un serveur Web.

### `create-lxc-ubuntu2404-web-php55.sh`

Cette variante crée un LXC Ubuntu 24.04 avec le même environnement, mais utilise exactement **PHP 5.5.38**. Apache, MariaDB, SSH, Samba et code-server restent installés depuis Ubuntu 24.04 ; PHP-FPM 5.5.38 est isolé dans Docker et accessible uniquement localement par Apache.

> PHP 5.5.38 n'est plus maintenu depuis 2016. Réservez cette variante aux applications héritées et ne l'exposez pas directement à Internet.

### `create-lxc-ubuntu1804-web-php55-native.sh`

Cette seconde variante PHP 5.5.38 utilise **Ubuntu 18.04** et compile PHP directement dans le LXC. Elle fonctionne nativement avec Apache et PHP-FPM, sans Docker. Elle conserve MariaDB, phpMyAdmin 4.9.11, Samba, SSH et une version de code-server compatible avec Ubuntu 18.04.

> Ubuntu 18.04 et PHP 5.5.38 sont tous deux obsolètes. Ce script est réservé aux applications héritées sur un réseau privé.

Les sections suivantes décrivent principalement le script PHP 8.3. La variante PHP 5.5.38 conserve les mêmes modes de configuration et les mêmes accès aux services.

## Applications installées

| Application | Utilisation |
|---|---|
| Apache 2 | Serveur Web |
| PHP 8.3 | Exécution des applications PHP |
| MariaDB | Serveur de bases de données |
| phpMyAdmin | Administration Web de MariaDB |
| Samba | Accès réseau au dossier Web |
| code-server | Visual Studio Code depuis un navigateur |
| OpenSSH Server | Administration distante en SSH |

## Fonctionnalités

Le script effectue automatiquement les opérations suivantes :

- téléchargement du dernier template Ubuntu 24.04 disponible ;
- création du conteneur LXC ;
- sélection du stockage du conteneur et du template ;
- configuration réseau en DHCP ou en adresse IPv4 fixe ;
- prise en charge des stockages locaux, NFS et CIFS ;
- installation et configuration des applications ;
- création des comptes Linux et MariaDB ;
- configuration du partage Samba `Web` ;
- configuration de code-server sur le port `8680` ;
- création automatique des notes dans l'interface Proxmox ;
- affichage des services, des adresses et des identifiants dans les notes Proxmox ;
- suppression automatique du conteneur si la création échoue ;
- affichage d'une progression claire pendant l'installation.

## Modes de configuration

Au lancement, le script propose trois modes avec une sélection par case :

1. **Paramètres par défaut - identifiants générés automatiquement**
2. **Paramètres par défaut - saisie manuelle des identifiants**
3. **Paramètres avancés - configuration complète et identifiants personnalisés**

### Paramètres par défaut

| Paramètre | Valeur |
|---|---|
| Système | Ubuntu 24.04 LTS |
| Nom du conteneur | `ubuntu-web` |
| CPU | 2 cœurs |
| Mémoire | 4096 Mo |
| Swap | 512 Mo |
| Disque | 32 Go |
| Bridge réseau | `vmbr0` |
| Réseau | DHCP |
| DNS | `8.8.8.8` |
| Conteneur non privilégié | Oui |
| Démarrage automatique | Oui |
| Utilisateur Linux | `admin` |
| Utilisateur MariaDB | `dbadmin` |

Le VMID est automatiquement choisi à partir du prochain identifiant disponible sur le cluster Proxmox.

## Identifiants automatiques

Dans le premier mode, les mots de passe sont générés automatiquement avec :

- exactement 8 caractères ;
- uniquement des lettres majuscules, des lettres minuscules et des chiffres.

Les identifiants générés sont inscrits dans les notes du conteneur Proxmox.

## Progression de l'installation

La sortie détaillée des commandes système est masquée afin de conserver un affichage lisible.

Le script affiche une progression en 9 étapes :

```text
[1/9] Configuration du réseau
  ⏳ En cours...
  ✔ Terminée

[2/9] Mise à jour du système
  ⏳ En cours...
  ✔ Terminée

[3/9] Apache et PHP
[4/9] MariaDB
[5/9] Utilisateur Linux et SSH
[6/9] phpMyAdmin
[7/9] Samba
[8/9] code-server
[9/9] Vérification finale
```

En cas d'erreur, les 30 dernières lignes utiles du journal sont affichées automatiquement.

Le journal détaillé de l'installation est disponible dans le conteneur :

```text
/var/log/lxc-web-install.log
```

Le journal principal du script est également conservé sur le nœud Proxmox dans :

```text
/var/log/create-lxc-web-AAAAMMJJ-HHMMSS.log
```

## Notes Proxmox

Dès la création du conteneur, le script ajoute une note indiquant que l'installation est en cours.

Une fois l'installation terminée, les notes sont mises à jour avec :

- l'état de l'installation ;
- l'adresse IP du conteneur ;
- les liens d'accès aux services ;
- les identifiants Linux, MariaDB, code-server et root ;
- le bridge réseau, le DNS et le VLAN utilisé.

## Accès aux services

Après l'installation, remplacez `<IP>` par l'adresse du conteneur.

| Service | Adresse ou commande |
|---|---|
| Apache | `http://<IP>` |
| phpMyAdmin | `http://<IP>/phpmyadmin` |
| code-server | `http://<IP>:8680` |
| Samba | `\\<IP>\Web` |
| SSH | `ssh admin@<IP>` |

## Exécution

Connectez-vous en root sur un nœud Proxmox VE, puis exécutez :

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/oOBenjaminOo/proxmox-scripts/main/create-lxc-ubuntu2404-web.sh)"
```

Pour créer la variante PHP 5.5.38 :

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/oOBenjaminOo/proxmox-scripts/main/create-lxc-ubuntu2404-web-php55.sh)"
```

Pour créer la variante PHP 5.5.38 native, sans Docker :

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/oOBenjaminOo/proxmox-scripts/main/create-lxc-ubuntu1804-web-php55-native.sh)"
```

## Prérequis

- Proxmox VE 8 ou supérieur ;
- exécution en tant que root sur un nœud Proxmox ;
- accès Internet depuis le nœud et le conteneur ;
- stockage compatible avec les contenus `rootdir` et `vztmpl` ;
- bridge réseau Proxmox fonctionnel.

## Sécurité

- Le conteneur est non privilégié par défaut.
- La connexion SSH directe de l'utilisateur root est désactivée.
- Les fichiers temporaires contenant les identifiants sont protégés puis supprimés après l'installation.
- Les journaux du script sur le nœud Proxmox sont accessibles uniquement à root.

> Les mots de passe générés automatiquement sont volontairement simples à saisir. Pour une utilisation exposée sur Internet, il est recommandé de choisir le mode avec identifiants personnalisés et d'utiliser des mots de passe plus longs.

## Licence

Ce projet est distribué sous licence MIT. Consultez le fichier `LICENSE` pour plus d'informations.
