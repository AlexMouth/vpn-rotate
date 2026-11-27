#!/bin/bash -p
# Installation, lancée avec le mot de passe administrateur (une fois, puis après
# une mise à jour de l'application) : copie les programmes dans un dossier protégé
# et autorise ce compte à lancer control.sh, et lui seul, sans mot de passe.
#   install.sh <identifiant numérique du compte>
set -e
umask 022

ROOT=""
if [ "$(id -u)" -ne 0 ]; then
  ROOT="${VPNROTATE_TEST_ROOT:?Droits administrateur requis}"
else
  export PATH="/usr/bin:/bin:/usr/sbin:/sbin" LC_ALL=C HOME=/var/root
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
H="$ROOT/Library/PrivilegedHelperTools/local.vpnrotate"
SUDOERS="$ROOT/etc/sudoers.d"
PLIST="$ROOT/Library/LaunchDaemons/local.vpnrotate.plist"
STATSPLIST="$ROOT/Library/LaunchDaemons/local.vpnrotate.stats.plist"
LOG="$ROOT/var/log/vpnrotate.log"
RUN="$ROOT/var/run/wireguard"
# Nom de l'installation jusqu'à la version 2.4, repris puis retiré ci-dessous
OLD_NAME="local.protonvpn.rotation"
OLD_H="$ROOT/Library/PrivilegedHelperTools/$OLD_NAME"

die() { echo "$1" >&2; exit 1; }

uid="$1"
[[ "$uid" =~ ^[1-9][0-9]*$ ]] || die "Compte invalide."
[ -x "$HERE/wireguard/bin/wg-quick" ] || die "WireGuard absent de l'application."
if [ -z "$ROOT" ]; then
  grep -qE '^[#@]includedir[[:space:]]+(/private)?/etc/sudoers\.d' /etc/sudoers ||
    die "Ce Mac ne lit pas /etc/sudoers.d : installation impossible."
fi

mkdir -p "$H/bin" "$H/lib" "$H/share" "$(dirname "$LOG")" "$(dirname "$PLIST")"
chmod 755 "$H" "$H/bin" "$H/lib" "$H/share"

# Remplacement d'un seul coup : un programme en cours d'exécution n'est pas modifié
put() {
  rm -f "$2.new"
  cp -X "$1" "$2.new"
  chmod "$3" "$2.new"
  [ -n "$ROOT" ] || chown root:wheel "$2.new"
  mv -f "$2.new" "$2"
}

for f in "$HERE"/wireguard/lib/*; do put "$f" "$H/lib/$(basename "$f")" 644; done
for f in "$HERE"/wireguard/bin/*; do put "$f" "$H/bin/$(basename "$f")" 755; done
put "$HERE/net.sh" "$H/net.sh" 644
put "$HERE/stats.sh" "$H/stats.sh" 755
put "$HERE/rotate.sh" "$H/rotate.sh" 755
put "$HERE/control.sh" "$H/control.sh" 755

# Installation sous l'ancien nom : on la coupe, reprend ses statistiques et
# son jeton pf (le blocage hors VPN reste en place), puis on la retire
if [ -d "$OLD_H" ] && [ ! -L "$OLD_H" ]; then
  launchctl bootout "system/$OLD_NAME" 2>/dev/null || true
  launchctl bootout "system/$OLD_NAME.stats" 2>/dev/null || true
  (
    DIR="$OLD_H/etc" SHARE="$OLD_H/share"
    [ -n "$ROOT" ] || export PATH="$H/bin:$PATH"
    . "$H/net.sh"
    . "$H/stats.sh"
    record_stats || true
    # Retirer la prise de contrôle arrête le tunnel, comme "wg-quick down"
    for f in "$RUN"/pvpn[0-9][0-9].name; do
      [ -f "$f" ] || continue
      iface="$(cat "$f")"
      if [[ "$iface" =~ ^utun[0-9]+$ ]]; then rm -f "$RUN/$iface.sock"; fi
      rm -f "$f"
    done
    rm -f "$SHARE/status"
    unblock_ipv6 >> "$LOG" || true
    restore_dns >> "$LOG" || true
  )
  for name in stats.tsv history.tsv stats-since; do
    [ -f "$OLD_H/share/$name" ] && [ ! -L "$OLD_H/share/$name" ] && [ ! -e "$H/share/$name" ] || continue
    cp -X "$OLD_H/share/$name" "$H/share/$name"
    chmod 644 "$H/share/$name"
  done
  if [ -f "$OLD_H/pf-token" ] && [ ! -e "$H/pf-token" ]; then
    cp -X "$OLD_H/pf-token" "$H/pf-token"
    chmod 600 "$H/pf-token"
  fi
  rm -f "$ROOT/Library/LaunchDaemons/$OLD_NAME.plist" "$ROOT/Library/LaunchDaemons/$OLD_NAME.stats.plist" \
    "$SUDOERS"/protonvpn-rotation-* "$ROOT/var/log/protonvpn-rotation.log"
  # Contient des copies des clés privées
  rm -rf "${OLD_H:?}"
fi

# En dernier, une fois tout en place ; contrôlé avant d'être activé
mkdir -p "$SUDOERS"
rule="$H/sudoers.new"
rm -f "$rule"
printf '#%s ALL=(root) NOPASSWD: %s\n' "$uid" "$H/control.sh" > "$rule"
chmod 440 "$rule"
visudo -cf "$rule" >/dev/null || { rm -f "$rule"; die "Autorisation invalide."; }
mv -f "$rule" "$SUDOERS/vpnrotate-$uid"
echo "$(date '+%F %T') installation terminée" >> "$LOG"
