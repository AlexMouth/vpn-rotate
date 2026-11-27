#!/bin/bash -p
# Actions privilégiées de VPN Rotation. Installé par install.sh dans un dossier
# réservé à l'administrateur ; l'application le lance par sudo, sans mot de passe.
# Tout ce qu'il reçoit vient donc d'un programme non privilégié : à contrôler.
#   control.sh apply <dossier> <secondes> <sequential|random> [on|off]
#     (dernier argument : blocage hors VPN, activé par défaut)
#   control.sh now [vpnNN]
#   control.sh stop
#   control.sh uninstall
set -e
umask 022

# Hors root, seul le mode test (dans un faux dossier racine) est permis
ROOT=""
if [ "$(id -u)" -ne 0 ]; then
  ROOT="${VPNROTATE_TEST_ROOT:?Droits administrateur requis}"
else
  # Uniquement des programmes que seul un administrateur peut modifier.
  # LC_ALL=C : bash ne charge aucune traduction depuis un autre dossier.
  export PATH="/Library/PrivilegedHelperTools/local.vpnrotate/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  export LC_ALL=C HOME=/var/root
  unset LANGUAGE
fi

H="$ROOT/Library/PrivilegedHelperTools/local.vpnrotate"
DIR="$H/etc"
SHARE="$H/share"
BIN="$H/rotate.sh"
PLIST="$ROOT/Library/LaunchDaemons/local.vpnrotate.plist"
LOG="$ROOT/var/log/vpnrotate.log"
RUN="$ROOT/var/run/wireguard"
LABEL="system/local.vpnrotate"
STATSBIN="$H/stats.sh"
STATSPLIST="$ROOT/Library/LaunchDaemons/local.vpnrotate.stats.plist"
STATSLABEL="system/local.vpnrotate.stats"

. "$H/net.sh"
. "$H/stats.sh"

die() { echo "$1" >&2; exit 1; }

unload() {
  launchctl bootout "$LABEL" 2>/dev/null || true
}

unload_stats() {
  launchctl bootout "$STATSLABEL" 2>/dev/null || true
}

load() {
  # bootout est asynchrone : on réessaie quelques secondes
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    launchctl bootstrap system "${1:-$PLIST}" 2>/dev/null && return 0
    sleep 0.5
  done
  die "Impossible de démarrer la rotation (launchctl)."
}

down_all() {
  # Compte la fin de la session avant de couper
  record_stats || true
  for conf in "$DIR"/*.conf; do
    [ -e "$conf" ] || continue
    if [ -f "$RUN/$(basename "$conf" .conf).name" ]; then
      wg-quick down "$conf" || true
    fi
  done
  rm -f "$SHARE/status"
  unblock_ipv6 >> "$LOG"
  # Même sans tunnel actif : répare des DNS restés sur ceux du VPN
  if [ -d "$SHARE" ]; then restore_dns >> "$LOG"; fi
}

# Lit un fichier avec les droits de la personne qui appelle, jamais ceux de
# root : un lien vers un fichier protégé ne donne ainsi accès à rien
read_user() {
  if [ "$(id -u)" -ne 0 ]; then
    head -c 65536 -- "$1"
  else
    [[ "${SUDO_UID:-}" =~ ^[0-9]+$ ]] || return 1
    /usr/bin/sudo -u "#$SUDO_UID" /usr/bin/head -c 65536 -- "$1"
  fi
}

# Réécrit une configuration en ne gardant que des réglages connus et des valeurs
# simples. PreUp, PostUp et tout le reste (exécutés en root par wg-quick) font
# refuser le fichier.
sanitize_conf() {
  LC_ALL=C awk '
    function trim(v) { gsub(/^[ \t\r]+|[ \t\r]+$/, "", v); return v }
    BEGIN {
      key64 = "^[A-Za-z0-9+/]+=*$"; digits = "^[0-9]+$"; nets = "^[0-9A-Fa-f.:/, ]+$"
      rule["[Interface]", "privatekey"] = key64
      rule["[Interface]", "address"] = nets
      rule["[Interface]", "dns"] = "^[A-Za-z0-9.:_, -]+$"
      rule["[Interface]", "mtu"] = digits
      rule["[Interface]", "listenport"] = digits
      rule["[Peer]", "publickey"] = key64
      rule["[Peer]", "presharedkey"] = key64
      rule["[Peer]", "allowedips"] = nets
      rule["[Peer]", "endpoint"] = "^[A-Za-z0-9._:-]+$"
      rule["[Peer]", "persistentkeepalive"] = "^([0-9]+|off)$"
    }
    { sub(/#.*/, ""); line = trim($0) }
    line == "" { next }
    line == "[Interface]" || line == "[Peer]" {
      section = line; seen[line] = 1; print line; next
    }
    {
      eq = index(line, "=")
      if (!eq) { bad = 1; exit }
      key = trim(substr(line, 1, eq - 1)); value = trim(substr(line, eq + 1))
      lower = tolower(key)
      if (!((section, lower) in rule)) { bad = 1; exit }
      checked = value
      # Les adresses IPv6 des serveurs sont entre crochets
      if (lower == "endpoint") { gsub(/\[/, "", checked); gsub(/\]/, "", checked) }
      if (checked !~ rule[section, lower]) { bad = 1; exit }
      print key " = " value
    }
    END { if (bad || !seen["[Interface]"] || !seen["[Peer]"]) exit 1 }
  '
}

case "$1" in
  apply)
    src="$2"; seconds="$3"; order="$4"; killswitch="${5:-on}"
    [[ "$seconds" =~ ^[1-9][0-9]{1,6}$ ]] && [ "$seconds" -ge 60 ] || die "Intervalle invalide."
    [ "$order" = sequential ] || [ "$order" = random ] || die "Ordre invalide."
    [ "$killswitch" = on ] || [ "$killswitch" = off ] || die "Réglage de blocage invalide."
    command -v wg-quick >/dev/null || die "WireGuard manquant : réinstallez l'application."

    # Chaque fichier est réécrit dans un dossier protégé
    new="$DIR.new"
    rm -rf "${new:?}"
    mkdir -m 700 "$new"
    count=0
    for f in "$src"/vpn[0-9][0-9].conf; do
      [ -f "$f" ] || continue
      target="$new/$(basename "$f")"
      : > "$target"
      chmod 600 "$target"
      if ! read_user "$f" | sanitize_conf > "$target"; then
        rm -rf "${new:?}"
        die "Fichier refusé : réglage non autorisé (PreUp, PostUp, Table…) ou fichier incomplet."
      fi
      count=$((count + 1))
    done
    [ "$count" -ge 2 ] || { rm -rf "${new:?}"; die "Sélectionne au moins 2 serveurs."; }

    mkdir -p "$(dirname "$LOG")"
    unload
    unload_stats
    # Bloqué avant de couper l'ancien tunnel : rien ne sort jusqu'au suivant
    if [ "$killswitch" = on ]; then
      killswitch_on "" "$new" >> "$LOG" || true
    else
      killswitch_off >> "$LOG" || true
    fi
    down_all
    rm -rf "${DIR:?}"
    mv "$new" "$DIR"
    echo "$order" > "$DIR/order"
    echo "$killswitch" > "$DIR/killswitch"

    mkdir -p "$SHARE" "$(dirname "$PLIST")"
    chmod 755 "$SHARE"
    read_user "$src/names.tsv" | awk -F '\t' -v OFS='\t' \
      'NF == 2 && $1 ~ /^vpn[0-9][0-9]$/ { gsub(/[[:cntrl:]]/, "", $2); print $1, $2 }' \
      > "$SHARE/names.tsv"
    read_user "$src/ids.tsv" | awk -F '\t' -v OFS='\t' \
      'NF == 2 && $1 ~ /^vpn[0-9][0-9]$/ && $2 ~ /^[0-9A-Fa-f-]+$/ { print $1, $2 }' \
      > "$SHARE/ids.tsv"
    echo "$seconds" > "$SHARE/interval"
    chmod 644 "$SHARE/names.tsv" "$SHARE/ids.tsv" "$SHARE/interval"
    cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>local.vpnrotate</string>
  <key>ProgramArguments</key><array><string>$BIN</string></array>
  <key>RunAtLoad</key><true/>
  <key>StartInterval</key><integer>$seconds</integer>
  <key>AbandonProcessGroup</key><true/>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
EOF
    chmod 644 "$PLIST"
    cat > "$STATSPLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>local.vpnrotate.stats</string>
  <key>ProgramArguments</key><array><string>$STATSBIN</string></array>
  <key>RunAtLoad</key><true/>
  <key>StartInterval</key><integer>60</integer>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
EOF
    chmod 644 "$STATSPLIST"
    load
    load "$STATSPLIST"
    ;;
  now)
    [ -f "$PLIST" ] || die "Rotation non installée."
    if [ -n "$2" ]; then
      [[ "$2" =~ ^vpn[0-9][0-9]$ ]] || die "Serveur invalide."
      echo "$2" > "$DIR/next"
    fi
    # Recharger relance le script et remet le minuteur à zéro
    unload
    load
    ;;
  stop)
    unload
    unload_stats
    down_all
    killswitch_off >> "$LOG" || true
    # Sans le plist, la rotation ne repart pas au redémarrage
    rm -f "$PLIST" "$STATSPLIST"
    echo "$(date '+%F %T') rotation arrêtée" >> "$LOG"
    sleep 3
    if [ -d "$SHARE" ]; then diagnostic >> "$LOG"; fi
    ;;
  uninstall)
    unload
    unload_stats
    down_all
    killswitch_off >> "$LOG" || true
    # Retire d'abord l'autorisation sans mot de passe
    rm -f "$ROOT"/etc/sudoers.d/vpnrotate-*
    rm -rf "${DIR:?}"
    # Les statistiques sont conservées pour une réinstallation
    if [ -d "$SHARE" ]; then
      find "$SHARE" -mindepth 1 -maxdepth 1 \
        ! -name stats.tsv ! -name history.tsv ! -name stats-since -exec rm -rf {} +
    fi
    rm -f "$PLIST" "$STATSPLIST" "$LOG"
    rm -rf "${H:?}/bin" "${H:?}/lib"
    rm -f "$H/rotate.sh" "$H/net.sh" "$H/stats.sh" "$H/control.sh"
    ;;
  *)
    die "Action inconnue."
    ;;
esac
