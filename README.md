# VPN Rotate

Application macOS qui change automatiquement de serveur VPN (WireGuard, avec les fichiers `.conf` de votre fournisseur) à intervalle régulier.

- Import de vos fichiers `.conf` et choix des serveurs de la rotation
- Carte du monde : position actuelle et circuit de la rotation
- Débit en direct, statistiques par serveur et hors VPN
- Blocage hors VPN (kill switch, pare-feu pf de macOS) : rien ne sort en clair pendant un changement de serveur ou si le tunnel tombe
- Notifications : serveur injoignable, tunnel tombé, VPN rétabli, et en option chaque changement de serveur (tant que l'application est ouverte)
- Réglages et journal

## Télécharger

Prenez `VPN-Rotate.zip` dans la page **Releases** de ce dépôt.

Configuration requise : Mac Apple Silicon (arm64) sous **macOS 27 ou plus récent** (version minimale des outils WireGuard embarqués).

## Installer

1. Décompressez le zip et glissez **VPN Rotate** dans le dossier Applications.
2. Ouvrez-la. L'application n'est pas notariée par Apple : macOS la bloque la première fois. Allez dans **Réglages Système → Confidentialité et sécurité**, puis cliquez sur **Ouvrir quand même**.
3. À l'installation, le mot de passe administrateur est demandé une fois (il peut l'être à nouveau après une mise à jour).
4. Ajoutez au moins deux fichiers `.conf`, puis démarrez la rotation. Quittez d'abord toute autre application VPN.

La rotation continue quand l'application est fermée : utilisez **Arrêter** pour couper le VPN.

Ne publiez jamais vos fichiers `.conf` : ils contiennent vos clés privées.

## Compiler

Il faut les outils en ligne de commande Xcode et Homebrew :

```bash
brew install wireguard-tools bash
./app/build.sh
```

## Composants tiers

L'archive téléchargeable embarque [wireguard-tools](https://git.zx2c4.com/wireguard-tools/) (GPL-2.0), [wireguard-go](https://git.zx2c4.com/wireguard-go/) (MIT), [GNU bash](https://www.gnu.org/software/bash/) et readline (GPL-3.0), ncurses (MIT) et gettext/libintl (LGPL-2.1), tels que distribués par Homebrew. Leurs sources sont disponibles aux adresses des projets.

Les contours des pays de la carte viennent de [Natural Earth](https://www.naturalearthdata.com/) (domaine public), simplifiés par `app/countries.py`.
