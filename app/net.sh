# Sauvegarde et restauration des DNS, blocage de l'IPv6 hors tunnel
# (inclus par rotate.sh, control.sh et stats.sh).
# wg-quick restaure les DNS en arrière-plan : lors d'une rotation, le tunnel
# suivant pouvait mémoriser le DNS du VPN comme réglage "d'origine".
# Nécessite les variables DIR et SHARE.

services() {
  networksetup -listallnetworkservices | tail -n +2 | sed 's/^\*//'
}

# Adresses DNS déclarées dans les fichiers .conf, une par ligne
tunnel_dns() {
  cat "$DIR"/*.conf 2>/dev/null |
    awk -F= 'tolower($1) ~ /^[ \t]*dns[ \t]*$/ { sub(/#.*/, "", $2); print $2 }' |
    tr ', \t\r' '\n\n\n\n' | grep -E '^[0-9a-fA-F]*[.:][0-9a-fA-F.:]+$' | sort -u
}

uses_tunnel_dns() {
  local wanted
  wanted=$(tunnel_dns)
  [ -n "$wanted" ] && networksetup -getdnsservers "$1" | grep -qxF "$wanted"
}

# Valeurs actuelles sur une ligne, ou "Empty" (automatique)
current_setting() {
  local out
  out=$(networksetup "$1" "$2")
  case "$out" in
    *"aren't any"*) echo Empty ;;
    *) echo "$out" | tr '\n' ' ' ;;
  esac
}

# À appeler avant de monter un tunnel
backup_dns() {
  local file="$SHARE/dns-backup.tsv" new="$SHARE/dns-backup.new" service
  : > "$new"
  while IFS= read -r service; do
    if uses_tunnel_dns "$service"; then
      # Réglage déjà pollué : on conserve l'ancienne sauvegarde
      awk -F '\t' -v s="$service" '$1 == s' "$file" 2>/dev/null >> "$new"
    else
      printf '%s\t%s\t%s\n' "$service" \
        "$(current_setting -getdnsservers "$service")" \
        "$(current_setting -getsearchdomains "$service")" >> "$new"
    fi
  done < <(services)
  mv "$new" "$file"
}

# Attend la fin des surveillants lancés par "wg-quick up" : ils modifient
# encore les DNS après la coupure, même une fois "route -n monitor" arrêté.
wait_monitors() {
  local pattern="wg-quick up $DIR/" i
  for ((i = 0; i < 60; i++)); do
    pgrep -f "$pattern" >/dev/null || return 0
    sleep 0.5
  done
  pkill -9 -f "$pattern" || true
  echo "$(date '+%F %T') surveillant wg-quick bloqué : arrêt forcé"
}

restore_pass() {
  local file="$SHARE/dns-backup.tsv" service dns search
  while IFS= read -r service; do
    uses_tunnel_dns "$service" || continue
    dns=$(awk -F '\t' -v s="$service" '$1 == s { print $2 }' "$file" 2>/dev/null || true)
    search=$(awk -F '\t' -v s="$service" '$1 == s { print $3 }' "$file" 2>/dev/null || true)
    # Découpage volontaire : plusieurs adresses possibles
    networksetup -setdnsservers "$service" ${dns:-Empty} || continue
    networksetup -setsearchdomains "$service" ${search:-Empty} || continue
    echo "$(date '+%F %T') DNS restaurés : $service"
  done < <(services)
}

polluted_services() {
  local service
  while IFS= read -r service; do
    if uses_tunnel_dns "$service"; then echo "$service"; fi
  done < <(services)
}

# À appeler après avoir coupé un tunnel
restore_dns() {
  wait_monitors
  for _ in 1 2 3; do
    restore_pass
    sleep 2
    [ -z "$(polluted_services)" ] && return 0
  done
  echo "$(date '+%F %T') ÉCHEC : DNS du VPN encore présents"
}

# Si le fichier ne donne qu'une adresse IPv4, wg-quick ne peut pas router
# l'IPv6 dans le tunnel, et ce trafic sortirait avec la vraie adresse. Ces deux
# routes le refusent, les applications repassent aussitôt en IPv4 (donc dans le
# VPN). Non permanentes : un redémarrage les efface. Le réseau local reste joignable.
ipv6_reject_route() {
  netstat -rn -f inet6 2>/dev/null |
    awk -v d="$1" '$1 == d && $2 == "::1" && $3 ~ /R/ { found = 1 } END { exit !found }'
}

# À appeler une fois le tunnel monté ; sans effet s'il transporte déjà l'IPv6
block_ipv6() {
  local net
  for net in ::/1 8000::/1; do
    if netstat -rn -f inet6 2>/dev/null |
      awk -v d="$net" '$1 == d { found = 1 } END { exit !found }'; then
      continue
    fi
    if route -q -n add -inet6 "$net" ::1 -reject >/dev/null 2>&1 && ipv6_reject_route "$net"; then
      echo "$(date '+%F %T') IPv6 hors tunnel bloqué : $net"
    else
      echo "$(date '+%F %T') ÉCHEC : IPv6 non bloqué : $net"
    fi
  done
}

# N'enlève que les routes de refus posées par block_ipv6
unblock_ipv6() {
  local net
  for net in ::/1 8000::/1; do
    ipv6_reject_route "$net" || continue
    if route -q -n delete -inet6 "$net" >/dev/null 2>&1; then
      echo "$(date '+%F %T') IPv6 rétabli : $net"
    else
      echo "$(date '+%F %T') ÉCHEC : IPv6 toujours bloqué : $net"
    fi
  done
}

# Blocage hors VPN (kill switch) : règles du pare-feu pf de macOS, chargées
# dans une ancre que /etc/pf.conf inclut déjà. Seuls passent le tunnel actif,
# les serveurs WireGuard (pour monter le tunnel suivant) et le réseau local.
# Non permanent : un redémarrage l'efface, la rotation le remet au démarrage.
PF_ANCHOR="com.apple/250.VPNRotate"

# Adresse et port UDP de chaque serveur, un par ligne : "adresse port".
# Les noms sont résolus tout de suite, tant que le réseau est ouvert.
endpoints() {
  local files=("${1:-$DIR}"/*.conf) value host port
  [ -e "${files[0]}" ] || return 0
  awk -F= 'tolower($1) ~ /^[ \t]*endpoint[ \t]*$/ { v = $2; gsub(/[ \t\r]/, "", v); print v }' \
    "${files[@]}" 2>/dev/null | sort -u |
  while IFS= read -r value; do
    case "$value" in
      \[*\]:*) host=${value#\[}; host=${host%%\]*}; port=${value##*\]:} ;;
      *:*) host=${value%:*}; port=${value##*:} ;;
      *) continue ;;
    esac
    [[ "$port" =~ ^[0-9]{1,5}$ ]] || continue
    if [[ "$host" =~ ^[0-9.]+$ || "$host" =~ ^[0-9A-Fa-f:]+$ ]]; then
      echo "$host $port"
    elif [[ "$host" =~ ^[A-Za-z0-9.-]+$ ]]; then
      dscacheutil -q host -a name "$host" 2>/dev/null |
        awk -v p="$port" '/^ip(v6)?_address:/ { print $2, p }'
    fi
  done | sort -u
}

# Règles pf ; lit les serveurs sur l'entrée. Sans interface : tout est coupé
# sauf les serveurs et le réseau local (moment du changement de serveur).
pf_rules() {
  local iface="$1" ip port
  echo "pass out quick on lo0 all"
  if [ -n "$iface" ]; then echo "pass out quick on $iface all"; fi
  while read -r ip port; do
    if [ -n "$port" ]; then echo "pass out quick proto udp to $ip port $port"; fi
  done
  echo "pass out quick inet to { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, 224.0.0.0/4, 255.255.255.255 }"
  echo "pass out quick inet proto udp from any port 68 to any port 67"
  echo "pass out quick inet6 to { fe80::/10, ff00::/8 }"
  echo "block return out quick all"
}

# Identifie le démarrage en cours : un jeton pf ne survit pas au redémarrage
boot_id() {
  sysctl -n kern.boottime 2>/dev/null | sed -n 's/^{ sec = \([0-9]*\).*/\1/p'
}

# killswitch_on [interface du tunnel] [dossier des .conf]
killswitch_on() {
  local iface="$1" dir="${2:-$DIR}" token="" saved="" boot
  if [ -n "$iface" ] && ! [[ "$iface" =~ ^utun[0-9]+$ ]]; then
    echo "$(date '+%F %T') ÉCHEC : interface du tunnel inattendue ($iface)"
    iface=""
  fi
  if ! endpoints "$dir" | pf_rules "$iface" | pfctl -q -a "$PF_ANCHOR" -f - 2>/dev/null; then
    echo "$(date '+%F %T') ÉCHEC : blocage hors VPN impossible (pfctl)"
    return 1
  fi
  boot=$(boot_id)
  { read -r token saved < "$H/pf-token"; } 2>/dev/null || true
  # pf est activé une seule fois par démarrage ; le jeton permet de rendre
  # la main sans couper pf s'il sert aussi à autre chose
  if [ -z "$token" ] || [ "$saved" != "$boot" ] ||
    ! pfctl -s info 2>/dev/null | grep -q '^Status: Enabled'; then
    token=$(pfctl -E 2>&1 | awk '/^Token/ { print $NF }')
    printf '%s %s\n' "$token" "$boot" > "$H/pf-token"
    chmod 600 "$H/pf-token"
    echo "$(date '+%F %T') blocage hors VPN activé"
  fi
}

killswitch_off() {
  local token="" saved=""
  pfctl -q -a "$PF_ANCHOR" -F all 2>/dev/null || true
  [ -f "$H/pf-token" ] || return 0
  { read -r token saved < "$H/pf-token"; } 2>/dev/null || true
  if [ -n "$token" ] && [ "$saved" = "$(boot_id)" ]; then
    pfctl -q -X "$token" 2>/dev/null || true
  fi
  rm -f "$H/pf-token"
  echo "$(date '+%F %T') blocage hors VPN retiré"
}

killswitch_enabled() {
  [ "$(cat "$DIR/killswitch" 2>/dev/null)" = on ]
}

# État du réseau après l'arrêt, consigné dans le journal
diagnostic() {
  local dns=OK ip=KO name=KO iface
  [ -z "$(polluted_services)" ] || dns=KO
  iface=$(route -n get default 2>/dev/null | awk '/interface:/ { print $2 }') || true
  if ping -c 1 -t 3 1.1.1.1 >/dev/null 2>&1; then ip=OK; fi
  if dscacheutil -q host -a name apple.com 2>/dev/null | grep -q ip_address; then name=OK; fi
  echo "$(date '+%F %T') vérification : DNS $dns, accès IP $ip, résolution $name, interface ${iface:-aucune}"
}
