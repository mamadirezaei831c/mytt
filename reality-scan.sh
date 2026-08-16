#!/usr/bin/env bash
#
# reality-scan.sh — Reality target (dest / serverName) scanner
# ============================================================
# Finds good Reality "dest" targets for your VLESS Reality config.
# For each candidate domain it checks:
#   * DNS resolvable from *your* network
#   * reachable on 443/TCP
#   * TLS 1.3 + X25519 capable  (both are REQUIRED by the Reality
#     handshake: the proxy relays the real ServerHello from the dest)
#   * low total latency (DNS + connect + handshake)
#
# Run it from the machine that will actually use the config
# (e.g. from Iran), so the results reflect what your ISP allows
# and what your connection to the proxy will look like.
#
# Usage:
#   bash reality-scan.sh                 # built-in list of well-known sites
#   bash reality-scan.sh -f list.txt     # your own list (one domain per line)
#   bash reality-scan.sh --add more.txt  # append a list to the built-in one
#   bash reality-scan.sh -c 30 -t 6      # 30 parallel probes, 6s timeout each
#   bash reality-scan.sh -n 20           # show top 20 serverNames
#   bash reality-scan.sh -q -n 5         # quiet: only the final list
#
# Requirements: bash 3.2+, openssl 1.1.1+ (with TLS 1.3), a DNS
# client (dig / getent / nslookup / host — any one is enough).
# On macOS the bundled LibreSSL lacks TLS 1.3; install openssl via
# Homebrew first if `openssl s_client -tls1_3` does not work.
#
# NOTE (honest): with Reality, user traffic flows client <-> proxy;
# the dest only takes part in the TLS handshake. So this scanner
# ranks targets by reachability / blocking / latency — it does NOT
# measure "upload speed". A dest that is reachable and unthrottled
# from your network is what keeps your Reality connection unblocked;
# actual throughput depends on the client <-> proxy path (the
# Railway region) and your ISP.
# ============================================================

set -euo pipefail

# ---------------------------------------------------------------
# defaults
# ---------------------------------------------------------------
CONC=12          # parallel probes
TIMEOUT_S=6      # per-probe timeout (seconds)
TOPN=15          # how many serverNames to suggest
QUIET=0
LIST_FILE=""
ADD_FILES=()

# ---------------------------------------------------------------
# built-in candidate list (well-known, mostly CDN-fronted sites)
# ---------------------------------------------------------------
BUILTIN_DOMAINS=(
  # wikimedia
  www.wikipedia.org en.wikipedia.org fa.wikipedia.org www.wikidata.org
  commons.wikimedia.org upload.wikimedia.org
  # big tech / CDN-backed
  www.google.com www.youtube.com www.instagram.com www.facebook.com www.x.com
  www.whatsapp.com mail.google.com maps.google.com developers.google.com
  www.gstatic.com storage.googleapis.com fonts.googleapis.com
  www.cloudflare.com www.fastly.com www.akamai.com
  cdn.jsdelivr.net unpkg.com cdnjs.cloudflare.com
  github.com raw.githubusercontent.com gist.github.com www.gitlab.com bitbucket.org
  www.microsoft.com www.apple.com www.icloud.com www.amazon.com www.netflix.com
  www.spotify.com www.twitch.tv www.reddit.com www.linkedin.com www.tumblr.com
  www.pinterest.com www.ebay.com www.aliexpress.com www.booking.com www.airbnb.com
  www.uber.com www.paypal.com www.adobe.com www.salesforce.com www.shopify.com
  www.wordpress.com www.medium.com www.quora.com www.duckduckgo.com
  www.bing.com www.yahoo.com www.msn.com www.dropbox.com www.box.com
  www.office.com www.live.com www.outlook.com www.zoom.us www.slack.com
  www.discord.com www.tiktok.com www.telegram.org web.telegram.org t.me
  www.signal.org www.torproject.org www.eff.org www.mozilla.org developer.mozilla.org
  www.python.org nodejs.org www.docker.com www.kubernetes.io www.npmjs.com pypi.org
  www.stackoverflow.com stackexchange.com www.archive.org www.openstreetmap.org
  # international media (allowed & reachable from Iran)
  www.bbc.com www.bbc.co.uk www.dw.com www.france24.com www.aljazeera.com
  www.cnn.com www.nytimes.com www.theguardian.com www.reuters.com apnews.com
  www.voanews.com www.radiofarda.com www.iranintl.com www.rfi.fr www.euronews.com
  www.trtworld.com www.alarabiya.net www.bloomberg.com www.cnbc.com www.forbes.com
  www.npr.org www.cbc.ca www.abc.net.au www.nhk.or.jp www.straitstimes.com
  www.spiegel.de www.lemonde.fr www.elpais.com www.ft.com www.wsj.com
  # organizations
  www.un.org www.who.int www.imf.org www.worldbank.org www.oecd.org
  www.nasa.gov www.spacex.com www.airbus.com www.boeing.com
  www.europa.eu www.gov.uk www.whitehouse.gov www.state.gov
  # Iranian services (always unblocked; good if TLS 1.3)
  www.digikala.com www.aparat.com www.varzesh3.com www.irna.ir www.isna.ir
  www.farsnews.ir www.tasnimnews.com www.khabaronline.ir www.telewebion.com
  www.filimo.com www.namava.ir www.snapp.ir
  # misc global
  www.samsung.com www.sony.com www.lg.com www.intel.com www.amd.com www.nvidia.com
  www.tesla.com www.bmw.com www.mercedes-benz.com www.toyota.com
  www.emirates.com www.qatarairways.com www.turkishairlines.com www.lufthansa.com
  www.united.com www.delta.com www.ryanair.com
  www.vk.com www.qq.com www.baidu.com www.taobao.com www.alibaba.com www.jd.com
  www.rakuten.co.jp www.tripadvisor.com www.expedia.com
)

# ---------------------------------------------------------------
# helpers
# ---------------------------------------------------------------
now_ms() {
  local v
  v=$(date +%s%3N 2>/dev/null || true)
  if [ -n "$v" ] && [ "${v//[0-9]/}" = "" ]; then
    printf '%s' "$v"
    return
  fi
  perl -MTime::HiRes=time -e 'printf "%.0f\n", time()*1000' 2>/dev/null || printf '0'
}

resolve() {
  local d="$1" ip=""
  if command -v dig >/dev/null 2>&1; then
    ip=$(dig +short +time=2 +tries=1 "$d" A 2>/dev/null \
      | grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' | head -n1 || true)
  fi
  if [ -z "$ip" ] && command -v getent >/dev/null 2>&1; then
    ip=$(getent ahostsv4 "$d" 2>/dev/null | awk 'NR==1{print $1}' || true)
  fi
  if [ -z "$ip" ] && command -v nslookup >/dev/null 2>&1; then
    ip=$(nslookup "$d" 2>/dev/null \
      | awk '/^Address: /{if ($2 ~ /^[0-9.]+$/) {print $2; exit}}' || true)
  fi
  if [ -z "$ip" ] && command -v host >/dev/null 2>&1; then
    ip=$(host -t A "$d" 2>/dev/null | awk '/has address/{print $NF; exit}' || true)
  fi
  printf '%s' "$ip"
}

# probe a single domain: TLS 1.3 + X25519 handshake with latency
probe() {
  local domain="$1" ip="$2"
  local tf pid waited t0 t1 ms ok_tls subject
  tf=$(mktemp "${TMPDIR:-/tmp}/rs.XXXXXX") || return 1
  t0=$(now_ms)
  ( echo | openssl s_client -connect "${ip}:443" -servername "${domain}" \
        -tls1_3 -groups X25519 -alpn h2,http/1.1 -verify_quiet -showcerts \
        >"$tf" 2>/dev/null ) &
  pid=$!
  waited=0
  while [ "$waited" -lt $((TIMEOUT_S * 10)) ] && kill -0 "$pid" 2>/dev/null; do
    sleep 0.1
    waited=$((waited + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then kill "$pid" 2>/dev/null; fi
  wait "$pid" 2>/dev/null || true
  t1=$(now_ms)
  ms=$((t1 - t0)); [ "$ms" -lt 0 ] && ms=0

  ok_tls=0
  if grep -Eq "TLSv1\.3" "$tf" 2>/dev/null && grep -Eq "TLS_AES|TLS_CHACHA" "$tf" 2>/dev/null; then
    ok_tls=1
  fi
  subject=$(grep -m1 'subject' "$tf" 2>/dev/null | sed -E 's/^ *subject *= *//' || true)
  rm -f "$tf"

  if [ "$ok_tls" -eq 1 ]; then
    printf '%s\t%s\tOK\t%s\t%s\n' "$domain" "$ip" "$ms" "$subject"
  else
    printf '%s\t%s\tFAIL\t%s\t-\n' "$domain" "$ip" "$ms"
  fi
}

usage() {
  sed -n '1,40p' "$0" | sed -n 's/^# \{0,1\}//p'
  exit 0
}

# ---------------------------------------------------------------
# args
# ---------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    -f|--file)        LIST_FILE="${2:?missing argument for $1}"; shift 2 ;;
    --add)            ADD_FILES+=("${2:?missing argument for $1}"); shift 2 ;;
    -c|--concurrency) CONC="${2:?missing argument for $1}"; shift 2 ;;
    -t|--timeout)     TIMEOUT_S="${2:?missing argument for $1}"; shift 2 ;;
    -n|--top)         TOPN="${2:?missing argument for $1}"; shift 2 ;;
    -q|--quiet)       QUIET=1; shift ;;
    -h|--help)        usage ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$CONC" in (*[!0-9]*|'') CONC=12 ;; esac
case "$TOPN" in  (*[!0-9]*|'') TOPN=15  ;; esac
case "$TIMEOUT_S" in (*[!0-9]*|'') TIMEOUT_S=6 ;; esac

command -v openssl >/dev/null 2>&1 || { echo "[!] openssl not found" >&2; exit 1; }

# ---------------------------------------------------------------
# build domain list
# ---------------------------------------------------------------
all_domains=()
if [ -n "$LIST_FILE" ]; then
  [ -r "$LIST_FILE" ] || { echo "[!] cannot read list file: $LIST_FILE" >&2; exit 1; }
fi
read_domains() {
  local f="$1" line
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    line=$(printf '%s' "$line" | tr -d '[:space:]')
    case "$line" in ""|\#*) continue ;; esac
    all_domains+=("$line")
  done < "$f"
}
if [ -n "$LIST_FILE" ]; then
  read_domains "$LIST_FILE"
else
  all_domains=("${BUILTIN_DOMAINS[@]}")
fi
for f in "${ADD_FILES[@]}"; do
  [ -r "$f" ] || { echo "[!] cannot read list file: $f" >&2; exit 1; }
  read_domains "$f"
done

uniq_count=$(printf '%s\n' "${all_domains[@]}" | sort -u | grep -c . || true)
if [ "$uniq_count" -eq 0 ]; then
  echo "[!] no domains to scan" >&2
  exit 1
fi

RESULT_FILE=$(mktemp "${TMPDIR:-/tmp}/reality-scan.XXXXXX")
trap 'rm -f "$RESULT_FILE"' EXIT

export TIMEOUT_S RESULT_FILE
export -f now_ms resolve probe

if [ "$QUIET" -eq 0 ]; then
  echo "reality-scan: ${uniq_count} unique targets | ${CONC} parallel | ${TIMEOUT_S}s timeout"
  echo "  (openssl $(openssl version | awk '{print $1, $2}'))"
  echo ""
  echo "scanning... (DNSFAIL = blocked/unresolvable from here)"
fi

SECONDS=0
printf '%s\n' "${all_domains[@]}" | sort -u | xargs -P "$CONC" -I{} bash -c '
  d="$1"
  t0=$(now_ms)
  ip=$(resolve "$d")
  t1=$(now_ms)
  if [ -z "$ip" ]; then
    printf "%s\t-\tDNSFAIL\t%s\t-\n" "$d" "$((t1 - t0))" >> "$RESULT_FILE"
    exit 0
  fi
  probe "$d" "$ip" >> "$RESULT_FILE"
' _ {}

# ---------------------------------------------------------------
# report
# ---------------------------------------------------------------
total=$(grep -c . "$RESULT_FILE" || true)
passed=$(awk -F'\t' '$3=="OK"{c++} END{print c+0}' "$RESULT_FILE")
elapsed=$SECONDS

echo ""
echo "== summary: ${passed} OK / ${total} targets  (${elapsed}s) =="

if [ "$passed" -gt 0 ]; then
  echo ""
  echo "Best targets, sorted by total latency (DNS + connect + TLS1.3 handshake):"
  awk -F'\t' '$3=="OK"' "$RESULT_FILE" | sort -t$'\t' -k4,4n \
    | awk -F'\t' '{ s=$5; if (length(s)>34) s=substr(s,1,34);
                    printf "  %-34s %-16s OK  %6d ms  %s\n", $1, $2, $4, s }'
  echo ""
  echo "Top ${TOPN} serverName suggestions (paste into the panel's Reality settings):"
  n=0
  while IFS= read -r line && [ "$n" -lt "$TOPN" ]; do
    d=$(printf '%s' "$line" | cut -f1)
    printf '  %s\n' "$d"
    n=$((n + 1))
  done < <(awk -F'\t' '$3=="OK"' "$RESULT_FILE" | sort -t$'\t' -k4,4n)
else
  echo "  no usable target found — try a larger list (-f), or check your DNS/network."
fi

if [ "$passed" -lt "$total" ]; then
  echo ""
  echo "Unusable targets:"
  awk -F'\t' '$3!="OK"{printf "  %-34s %s  %s\n", $1, $3, ($4!="-" ? $4" ms" : "")}' "$RESULT_FILE"
fi
