#!/bin/bash
# Cumule le temps et les données de chaque serveur.
# Lancé chaque minute par launchd, et inclus par rotate.sh et control.sh
# pour compter la fin d'une session avant de couper le tunnel.
# Nécessite les variables SHARE et RUN.
#   stats.tsv   : identifiant, nom, secondes, octets reçus, octets envoyés
#   history.tsv : heure (epoch), identifiant, secondes, octets reçus, octets envoyés
#   stats.state : session en cours et dernier relevé

# Au-delà de cet écart entre deux relevés, le Mac dormait
STATS_MAX_GAP=150

record_stats() {
  local lock="$SHARE/stats.lock" i
  [ -f "$SHARE/status" ] || return 0
  # Un seul relevé à la fois
  for ((i = 0; i < 20; i++)); do
    if mkdir "$lock" 2>/dev/null; then
      record_sample
      rmdir "$lock" 2>/dev/null
      return 0
    fi
    sleep 0.1
  done
  # Verrou abandonné par un processus interrompu
  if [ -n "$(find "$lock" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
    rmdir "$lock" 2>/dev/null
  fi
  return 0
}

record_sample() {
  local id iface started now counters rx tx
  local session last last_rx last_tx seconds key name hour

  IFS=$'\t' read -r id iface started < "$SHARE/status" || return 0
  [[ "$started" =~ ^[0-9]+$ ]] || return 0
  # Le tunnel doit encore exister (pas le cas après un redémarrage)
  [ -n "$iface" ] && [ "$(cat "$RUN/$id.name" 2>/dev/null)" = "$iface" ] || return 0

  counters=$(wg show "$iface" transfer 2>/dev/null) || return 0
  [ -n "$counters" ] || return 0
  read -r rx tx <<< "$(echo "$counters" |
    awk '{ r += $2; t += $3 } END { printf "%.0f %.0f", r, t }')"
  now=$(date +%s)

  session="$id-$started"
  last=$started last_rx=0 last_tx=0
  if [ -f "$SHARE/stats.state" ]; then
    local saved saved_time saved_rx saved_tx
    read -r saved saved_time saved_rx saved_tx < "$SHARE/stats.state"
    if [ "$saved" = "$session" ]; then
      last=$saved_time last_rx=$saved_rx last_tx=$saved_tx
    fi
  fi

  seconds=$((now - last))
  [ "$seconds" -ge 0 ] || seconds=0
  [ "$seconds" -le "$STATS_MAX_GAP" ] || seconds=60
  # Compteurs repartis de zéro : tout est nouveau
  [ "$rx" -ge "$last_rx" ] || last_rx=0
  [ "$tx" -ge "$last_tx" ] || last_tx=0

  key=$(awk -F '\t' -v id="$id" '$1 == id { print $2 }' "$SHARE/ids.tsv" 2>/dev/null)
  name=$(awk -F '\t' -v id="$id" '$1 == id { print $2 }' "$SHARE/names.tsv" 2>/dev/null)
  [ -n "$key" ] || return 0

  [ -f "$SHARE/stats-since" ] || echo "$started" > "$SHARE/stats-since"
  touch "$SHARE/stats.tsv"
  # ENVIRON évite qu'awk interprète les caractères spéciaux d'un nom
  KEY="$key" NAME="${name:-$id}" awk -F '\t' -v OFS='\t' \
    -v s="$seconds" -v r="$((rx - last_rx))" -v t="$((tx - last_tx))" '
    $1 == ENVIRON["KEY"] {
      $2 = ENVIRON["NAME"]
      $3 = sprintf("%.0f", $3 + s)
      $4 = sprintf("%.0f", $4 + r)
      $5 = sprintf("%.0f", $5 + t)
      found = 1
    }
    { print }
    END { if (!found) print ENVIRON["KEY"], ENVIRON["NAME"], s, r, t }
  ' "$SHARE/stats.tsv" > "$SHARE/stats.new" || return 0
  # Même relevé, rangé dans l'heure en cours pour les graphiques
  hour=$((now - now % 3600))
  touch "$SHARE/history.tsv"
  KEY="$key" awk -F '\t' -v OFS='\t' -v h="$hour" \
    -v s="$seconds" -v r="$((rx - last_rx))" -v t="$((tx - last_tx))" '
    $1 == h && $2 == ENVIRON["KEY"] {
      $3 = sprintf("%.0f", $3 + s)
      $4 = sprintf("%.0f", $4 + r)
      $5 = sprintf("%.0f", $5 + t)
      found = 1
    }
    { print }
    END { if (!found && s + r + t > 0) print h, ENVIRON["KEY"], s, r, t }
  ' "$SHARE/history.tsv" > "$SHARE/history.new" || return 0
  mv "$SHARE/stats.new" "$SHARE/stats.tsv"
  mv "$SHARE/history.new" "$SHARE/history.tsv"
  echo "$session $now $rx $tx" > "$SHARE/stats.state"
  chmod 644 "$SHARE/stats.tsv" "$SHARE/history.tsv" "$SHARE/stats-since"
}

# Exécuté directement (et non inclus) : un relevé
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  umask 022
  ROOT=""
  if [ "$(id -u)" -ne 0 ]; then
    ROOT="${VPNROTATE_TEST_ROOT:?Droits administrateur requis}"
  else
    # Uniquement des programmes que seul un administrateur peut modifier
    export PATH="/Library/PrivilegedHelperTools/local.vpnrotate/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    export LC_ALL=C HOME=/var/root
    unset LANGUAGE
  fi
  H="$ROOT/Library/PrivilegedHelperTools/local.vpnrotate"
  SHARE="$H/share"
  RUN="$ROOT/var/run/wireguard"
  record_stats
  # Un changement de réseau peut effacer le blocage de l'IPv6 : on le repose
  if [ -f "$SHARE/status" ]; then
    IFS=$'\t' read -r id iface _ < "$SHARE/status"
    if [ -n "$iface" ] && [ "$(cat "$RUN/$id.name" 2>/dev/null)" = "$iface" ]; then
      . "$H/net.sh"
      block_ipv6
    fi
  fi
fi
