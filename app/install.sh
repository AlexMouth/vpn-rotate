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
OLD_DIR="$ROOT/usr/local/etc/vpnrotate"
OLD_SHARE="$ROOT/usr/local/share/vpnrotate"
OLD_BIN="$ROOT/usr/local/libexec"

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

# Ancienne installation (dans /usr/local) : on la coupe, reprend ses
# statistiques et la retire
if [ -d "$OLD_DIR" ] || [ -f "$OLD_BIN/vpnrotate-rotate.sh" ]; then
  launchctl bootout system/local.vpnrotate 2>/dev/null || true
  launchctl bootout system/local.vpnrotate.stats 2>/dev/null || true
  # L'ancien dossier de données n'est utilisé que s'il appartient bien à root
  old="$OLD_SHARE"
  if [ -z "$ROOT" ] && { [ -L "$old" ] || [ "$(stat -f %u "$old" 2>/dev/null)" != 0 ]; }; then
    old="$H/share"
  fi
  (
    DIR="$OLD_DIR" SHARE="$old"
    [ -n "$ROOT" ] || export PATH="$PATH:$H/bin"
    . "$H/net.sh"
    . "$H/stats.sh"
    record_stats || true
    # Retirer la prise de contrôle arrête le tunnel, comme "wg-quick down"
    for f in "$RUN"/vpn[0-9][0-9].name; do
      [ -f "$f" ] || continue
      iface="$(cat "$f")"
      if [[ "$iface" =~ ^utun[0-9]+$ ]]; then rm -f "$RUN/$iface.sock"; fi
      rm -f "$f"
    done
    rm -f "$SHARE/status"
    unblock_ipv6 >> "$LOG" || true
    restore_dns >> "$LOG" || true
  )
  if [ "$old" != "$H/share" ]; then
    for name in stats.tsv history.tsv stats-since; do
      [ -f "$old/$name" ] && [ ! -e "$H/share/$name" ] || continue
      # Lu avec les droits du compte, jamais ceux de root
      if [ -z "$ROOT" ]; then
        sudo -u "#$uid" cat "$old/$name" > "$H/share/$name"
      else
        cat "$old/$name" > "$H/share/$name"
      fi
      chmod 644 "$H/share/$name"
    done
  fi
  rm -f "$PLIST" "$STATSPLIST" "$OLD_BIN/vpnrotate-rotate.sh" \
    "$OLD_BIN/vpnrotate-net.sh" "$OLD_BIN/vpnrotate-stats.sh"
  # Contient des copies des clés privées
  rm -rf "${OLD_DIR:?}"
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
