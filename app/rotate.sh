#!/bin/bash
# Coupe le tunnel actif et monte le serveur suivant (lancé par launchd en root).
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
DIR="$H/etc"
SHARE="$H/share"
LOG="$ROOT/var/log/vpnrotate.log"
RUN="$ROOT/var/run/wireguard"

. "$H/net.sh"
. "$H/stats.sh"

say() { echo "$(date '+%F %T') $1"; }

# Garde le journal sous 500 Ko (réécriture sur place)
if [ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt 512000 ]; then
  keep=$(tail -n 500 "$LOG")
  echo "$keep" > "$LOG"
fi

shopt -s nullglob
configs=("$DIR"/*.conf)
count=${#configs[@]}
if [ "$count" -eq 0 ]; then
  say "ÉCHEC : aucun serveur configuré" >&2
  exit 1
fi

# Compte la fin de la session avant de couper
record_stats || true

# Rien ne sort en clair pendant le changement de serveur
if killswitch_enabled; then
  killswitch_on || true
else
  killswitch_off
fi

for conf in "${configs[@]}"; do
  if [ -f "$RUN/$(basename "$conf" .conf).name" ]; then
    wg-quick down "$conf"
  fi
done
rm -f "$SHARE/status"
unblock_ipv6
restore_dns
backup_dns

last=$(cat "$DIR/index" 2>/dev/null || echo -1)
order=$(cat "$DIR/order" 2>/dev/null || echo sequential)

# Liste des serveurs à essayer, dans l'ordre
queue=()
if [ "$order" = random ]; then
  for ((i = 0; i < count; i++)); do
    [ "$i" -ne "$last" ] && queue+=("$i")
  done
  # Mélange de Fisher-Yates
  for ((i = ${#queue[@]} - 1; i > 0; i--)); do
    j=$((RANDOM % (i + 1)))
    tmp=${queue[$i]}; queue[$i]=${queue[$j]}; queue[$j]=$tmp
  done
  [ "$last" -ge 0 ] && [ "$last" -lt "$count" ] && queue+=("$last")
else
  for ((i = 1; i <= count; i++)); do
    queue+=($(((last + i) % count)))
  done
fi

# Serveur demandé explicitement depuis l'application : essayé en premier
if [ -f "$DIR/next" ]; then
  wanted=$(cat "$DIR/next")
  rm -f "$DIR/next"
  for ((i = 0; i < count; i++)); do
    [ "$(basename "${configs[$i]}" .conf)" = "$wanted" ] && queue=("$i" "${queue[@]}")
  done
fi

for index in "${queue[@]}"; do
  conf=${configs[$index]}
  id=$(basename "$conf" .conf)
  label=$(awk -F '\t' -v id="$id" '$1 == id { print $2 }' "$SHARE/names.tsv" 2>/dev/null)
  if wg-quick up "$conf"; then
    echo "$index" > "$DIR/index"
    iface=$(cat "$RUN/$id.name" 2>/dev/null)
    printf '%s\t%s\t%s\n' "$id" "$iface" "$(date +%s)" > "$SHARE/status"
    chmod 644 "$SHARE/status"
    say "connecté : ${label:-$id}"
    block_ipv6
    if killswitch_enabled; then
      if [ -n "$iface" ]; then
        killswitch_on "$iface" || true
      else
        say "ÉCHEC : interface du tunnel inconnue, trafic bloqué" >&2
      fi
    fi
    exit 0
  fi
  say "serveur injoignable : ${label:-$id}" >&2
  restore_dns
done

if killswitch_enabled; then
  say "ÉCHEC : aucun serveur joignable, trafic bloqué jusqu'à l'arrêt de la rotation" >&2
else
  say "ÉCHEC : aucun serveur joignable, VPN coupé" >&2
fi
exit 1
