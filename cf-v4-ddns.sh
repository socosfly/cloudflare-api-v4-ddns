#!/usr/bin/env bash
set -Eeuo pipefail

# Cloudflare DDNS (A/AAAA)
# Recommended: create an API Token with Zone:Read and DNS:Edit permissions,
# restricted to the zone being updated.

# ------------------------- configuration -------------------------
CF_API_TOKEN="${CF_API_TOKEN:-}"       # Recommended authentication
CF_API_KEY="${CF_API_KEY:-}"           # Legacy Global API Key
CF_API_EMAIL="${CF_API_EMAIL:-}"       # Required only with Global API Key
CFZONE_NAME="${CFZONE_NAME:-}"         # e.g. example.com
CFRECORD_NAME="${CFRECORD_NAME:-}"     # e.g. home.example.com or home
CFRECORD_TYPE="${CFRECORD_TYPE:-A}"    # A or AAAA
CFTTL="${CFTTL:-120}"                  # 1 (automatic), or 60-86400
FORCE="${FORCE:-false}"
CF_CACHE_DIR="${CF_CACHE_DIR:-${XDG_STATE_HOME:-${HOME}/.local/state}/cf-ddns}"
IPV4_SOURCE="${IPV4_SOURCE:-https://api4.ipify.org}"
IPV6_SOURCE="${IPV6_SOURCE:-https://api6.ipify.org}"
# -----------------------------------------------------------------

usage() {
  cat <<'EOF'
Usage:
  cf-v4-ddns-fixed.sh -T API_TOKEN -z example.com -h home.example.com [-t A|AAAA]
  cf-v4-ddns-fixed.sh -k GLOBAL_API_KEY -u EMAIL -z example.com -h home [-t A|AAAA]

Options:
  -T  Cloudflare API Token (recommended)
  -k  Legacy Cloudflare Global API Key
  -u  Cloudflare account email (required with -k)
  -z  Cloudflare zone, e.g. example.com
  -h  DNS record name; a short host name is expanded with the zone
  -t  A or AAAA (default: A)
  -f  true to update even when the cached IP is unchanged
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

command -v curl >/dev/null 2>&1 || die "curl is required"
command -v jq >/dev/null 2>&1 || die "jq is required"

while getopts ':T:k:u:z:h:t:f:' opt; do
  case "$opt" in
    T) CF_API_TOKEN=$OPTARG ;;
    k) CF_API_KEY=$OPTARG ;;
    u) CF_API_EMAIL=$OPTARG ;;
    z) CFZONE_NAME=$OPTARG ;;
    h) CFRECORD_NAME=$OPTARG ;;
    t) CFRECORD_TYPE=$(printf '%s' "$OPTARG" | tr '[:lower:]' '[:upper:]') ;;
    f) FORCE=$OPTARG ;;
    :) usage; die "option -$OPTARG requires a value" ;;
    \?) usage; die "unknown option: -$OPTARG" ;;
  esac
done

CFRECORD_TYPE=$(printf '%s' "$CFRECORD_TYPE" | tr '[:lower:]' '[:upper:]')
[[ -n "$CFZONE_NAME" ]] || die "CFZONE_NAME/-z is required"
[[ -n "$CFRECORD_NAME" ]] || die "CFRECORD_NAME/-h is required"
[[ "$CFRECORD_TYPE" == A || "$CFRECORD_TYPE" == AAAA ]] ||
  die "CFRECORD_TYPE must be A or AAAA"
[[ "$FORCE" == true || "$FORCE" == false ]] || die "FORCE/-f must be true or false"
[[ "$CFTTL" =~ ^[0-9]+$ ]] || die "CFTTL must be numeric"
(( CFTTL == 1 || (CFTTL >= 60 && CFTTL <= 86400) )) ||
  die "CFTTL must be 1 (automatic), or between 60 and 86400"

CFZONE_NAME=${CFZONE_NAME%.}
CFRECORD_NAME=${CFRECORD_NAME%.}
case "$CFRECORD_NAME" in
  "$CFZONE_NAME"|*."$CFZONE_NAME") ;;
  *) CFRECORD_NAME="${CFRECORD_NAME}.${CFZONE_NAME}" ;;
esac

AUTH_HEADERS=()
if [[ -n "$CF_API_TOKEN" ]]; then
  AUTH_HEADERS=(-H "Authorization: Bearer $CF_API_TOKEN")
elif [[ -n "$CF_API_KEY" && -n "$CF_API_EMAIL" ]]; then
  AUTH_HEADERS=(-H "X-Auth-Email: $CF_API_EMAIL" -H "X-Auth-Key: $CF_API_KEY")
else
  die "set CF_API_TOKEN/-T, or both CF_API_KEY/-k and CF_API_EMAIL/-u"
fi

api_errors() {
  jq -r '.errors[]? | "\(.code): \(.message)"' <<<"$1" 2>/dev/null || true
}

api_success() {
  jq -e '.success == true' >/dev/null 2>&1 <<<"$1"
}

valid_ipv4() {
  local ip=$1 part
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS=. read -r -a parts <<<"$ip"
  for part in "${parts[@]}"; do
    (( 10#$part <= 255 )) || return 1
  done
}

valid_ipv6() {
  local ip=$1
  [[ "$ip" == *:* && "$ip" =~ ^[0-9A-Fa-f:]+$ ]]
}

if [[ "$CFRECORD_TYPE" == A ]]; then
  WAN_IP=$(curl -4fsS --connect-timeout 10 --max-time 20 "$IPV4_SOURCE") ||
    die "failed to retrieve IPv4 address from $IPV4_SOURCE"
  WAN_IP=${WAN_IP//$'\r'/}
  WAN_IP=${WAN_IP//$'\n'/}
  valid_ipv4 "$WAN_IP" || die "IPv4 source returned an invalid address: $WAN_IP"
else
  WAN_IP=$(curl -6fsS --connect-timeout 10 --max-time 20 "$IPV6_SOURCE") ||
    die "failed to retrieve IPv6 address from $IPV6_SOURCE (check IPv6 connectivity)"
  WAN_IP=${WAN_IP//$'\r'/}
  WAN_IP=${WAN_IP//$'\n'/}
  valid_ipv6 "$WAN_IP" || die "IPv6 source returned an invalid address: $WAN_IP"
fi

mkdir -p "$CF_CACHE_DIR"
chmod 700 "$CF_CACHE_DIR" 2>/dev/null || true
SAFE_RECORD=${CFRECORD_NAME//[^A-Za-z0-9_.-]/_}
WAN_IP_FILE="$CF_CACHE_DIR/wan-ip-${CFRECORD_TYPE}-${SAFE_RECORD}.txt"
ID_FILE="$CF_CACHE_DIR/ids-${CFRECORD_TYPE}-${SAFE_RECORD}.txt"

OLD_WAN_IP=""
[[ -f "$WAN_IP_FILE" ]] && IFS= read -r OLD_WAN_IP <"$WAN_IP_FILE" || true
if [[ "$FORCE" == false && "$WAN_IP" == "$OLD_WAN_IP" ]]; then
  printf 'WAN IP unchanged (%s); no update needed.\n' "$WAN_IP"
  exit 0
fi

CFZONE_ID=""
CFRECORD_ID=""
IDS_FROM_CACHE=false

load_cached_ids() {
  [[ -f "$ID_FILE" ]] || return 1
  [[ $(wc -l <"$ID_FILE" | tr -d ' ') == 5 ]] || return 1
  [[ $(sed -n '3p' "$ID_FILE") == "$CFZONE_NAME" ]] || return 1
  [[ $(sed -n '4p' "$ID_FILE") == "$CFRECORD_NAME" ]] || return 1
  [[ $(sed -n '5p' "$ID_FILE") == "$CFRECORD_TYPE" ]] || return 1
  CFZONE_ID=$(sed -n '1p' "$ID_FILE")
  CFRECORD_ID=$(sed -n '2p' "$ID_FILE")
  [[ "$CFZONE_ID" =~ ^[0-9a-fA-F]{32}$ && "$CFRECORD_ID" =~ ^[0-9a-fA-F]{32}$ ]]
}

resolve_ids() {
  local zone_json record_json result_count tmp

  zone_json=$(curl -sS --connect-timeout 10 --max-time 30 --get \
    "https://api.cloudflare.com/client/v4/zones" \
    "${AUTH_HEADERS[@]}" -H "Content-Type: application/json" \
    --data-urlencode "name=$CFZONE_NAME" \
    --data-urlencode "status=active" \
    --data-urlencode "per_page=50") ||
    die "Cloudflare zone lookup request failed"
  api_success "$zone_json" ||
    die "Cloudflare zone lookup failed: $(api_errors "$zone_json")"
  result_count=$(jq '.result | length' <<<"$zone_json")
  (( result_count == 1 )) ||
    die "expected exactly one active zone named $CFZONE_NAME; found $result_count"
  CFZONE_ID=$(jq -r '.result[0].id' <<<"$zone_json")

  record_json=$(curl -sS --connect-timeout 10 --max-time 30 --get \
    "https://api.cloudflare.com/client/v4/zones/$CFZONE_ID/dns_records" \
    "${AUTH_HEADERS[@]}" -H "Content-Type: application/json" \
    --data-urlencode "type=$CFRECORD_TYPE" \
    --data-urlencode "name.exact=$CFRECORD_NAME" \
    --data-urlencode "match=all" \
    --data-urlencode "per_page=100") ||
    die "Cloudflare DNS record lookup request failed"
  api_success "$record_json" ||
    die "Cloudflare DNS record lookup failed: $(api_errors "$record_json")"

  # Compatibility fallback: older API behavior accepted name= rather than name.exact=.
  result_count=$(jq --arg type "$CFRECORD_TYPE" --arg name "$CFRECORD_NAME" \
    '[.result[] | select(.type == $type and (.name | ascii_downcase) == ($name | ascii_downcase))] | length' \
    <<<"$record_json")
  if (( result_count == 0 )); then
    record_json=$(curl -sS --connect-timeout 10 --max-time 30 --get \
      "https://api.cloudflare.com/client/v4/zones/$CFZONE_ID/dns_records" \
      "${AUTH_HEADERS[@]}" -H "Content-Type: application/json" \
      --data-urlencode "type=$CFRECORD_TYPE" \
      --data-urlencode "name=$CFRECORD_NAME" \
      --data-urlencode "match=all" \
      --data-urlencode "per_page=100") ||
      die "Cloudflare DNS record lookup request failed"
    api_success "$record_json" ||
      die "Cloudflare DNS record lookup failed: $(api_errors "$record_json")"
    result_count=$(jq --arg type "$CFRECORD_TYPE" --arg name "$CFRECORD_NAME" \
      '[.result[] | select(.type == $type and (.name | ascii_downcase) == ($name | ascii_downcase))] | length' \
      <<<"$record_json")
  fi
  (( result_count == 1 )) ||
    die "expected exactly one $CFRECORD_TYPE record named $CFRECORD_NAME; found $result_count"
  CFRECORD_ID=$(jq -r --arg type "$CFRECORD_TYPE" --arg name "$CFRECORD_NAME" \
    '.result[] | select(.type == $type and (.name | ascii_downcase) == ($name | ascii_downcase)) | .id' \
    <<<"$record_json")

  tmp="${ID_FILE}.tmp.$$"
  printf '%s\n%s\n%s\n%s\n%s\n' \
    "$CFZONE_ID" "$CFRECORD_ID" "$CFZONE_NAME" "$CFRECORD_NAME" "$CFRECORD_TYPE" >"$tmp"
  mv "$tmp" "$ID_FILE"
}

if load_cached_ids; then
  IDS_FROM_CACHE=true
else
  printf 'Resolving Cloudflare Zone ID and Record ID...\n'
  resolve_ids
fi

update_record() {
  local body
  body=$(jq -cn \
    --arg type "$CFRECORD_TYPE" \
    --arg name "$CFRECORD_NAME" \
    --arg content "$WAN_IP" \
    --argjson ttl "$CFTTL" \
    '{type:$type, name:$name, content:$content, ttl:$ttl}')
  curl -sS --connect-timeout 10 --max-time 30 \
    -X PATCH "https://api.cloudflare.com/client/v4/zones/$CFZONE_ID/dns_records/$CFRECORD_ID" \
    "${AUTH_HEADERS[@]}" -H "Content-Type: application/json" --data "$body"
}

printf 'Updating %s %s to %s...\n' "$CFRECORD_TYPE" "$CFRECORD_NAME" "$WAN_IP"
RESPONSE=$(update_record) || die "Cloudflare update request failed"

# A stale cached Record ID is common after deleting/recreating a DNS record.
if ! api_success "$RESPONSE" && [[ "$IDS_FROM_CACHE" == true ]]; then
  printf 'Cached IDs were rejected; resolving IDs and retrying once...\n'
  resolve_ids
  RESPONSE=$(update_record) || die "Cloudflare update retry failed"
fi

if api_success "$RESPONSE" &&
  [[ $(jq -r '.result.content // empty' <<<"$RESPONSE") == "$WAN_IP" ]]; then
  tmp="${WAN_IP_FILE}.tmp.$$"
  printf '%s\n' "$WAN_IP" >"$tmp"
  mv "$tmp" "$WAN_IP_FILE"
  printf 'Updated successfully. Cache: %s\n' "$WAN_IP_FILE"
else
  printf 'ERROR: Cloudflare did not confirm the update.\n' >&2
  api_errors "$RESPONSE" >&2
  printf 'Response: %s\n' "$(jq -c . <<<"$RESPONSE" 2>/dev/null || printf '%s' "$RESPONSE")" >&2
  exit 1
fi
