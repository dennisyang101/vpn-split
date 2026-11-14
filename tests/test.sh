#!/bin/bash
set -uo pipefail
((EUID != 0)) || { printf 'Tests must run as a non-root user.\n' >&2; exit 1; }
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/vpn-split-test.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" VPN_SPLIT_CONF_DIR="$TMP/config with spaces"
mkdir -p "$HOME" "$VPN_SPLIT_CONF_DIR" "$TMP/bin"
MOCKBIN=$TMP/bin
export PATH="$MOCKBIN:/usr/bin:/bin"
export SCUTIL_LOG=$TMP/scutil.log
: > "$SCUTIL_LOG"
CLI=$ROOT/vpn-split
count=0
failures=0
check() { count=$((count+1)); if (( $1 != 0 )); then printf 'FAIL: %s\n' "$2" >&2; failures=$((failures+1)); fi; }
contains() { printf '%s\n' "$1" | grep -Fqx -- "$2"; }

# Stub every command that could touch network, host routes, VPN state, or privilege.
cat >"$MOCKBIN/curl" <<'MOCK'
#!/bin/sh
case "${CURL_MODE:-fail}" in
 probe) printf 'ip=203.0.113.7\n\nVS_REMOTE 198.51.100.8 0.025\n';;
 http) printf '198.51.100.9 503 0.125';;
 speed) printf '10000000 2.000 198.51.100.8 200';;
 truncated) printf '1234 0.500 198.51.100.8 200';;
 *) exit 7;;
esac
MOCK
cat >"$MOCKBIN/scutil" <<'MOCK'
#!/bin/sh
printf '%s\n' "$*" >> "$SCUTIL_LOG"
case "$1 $2" in
  '--nc status') printf '%s\n' "${SCUTIL_STATUS:-Disconnected}";;
  *) exit 0;;
esac
MOCK
cat >"$MOCKBIN/route" <<'MOCK'
#!/bin/sh
[ "$1" = -n ] && [ "$2" = get ] && { printf 'interface: %s\n' "${ROUTE_IFACE:-en0}"; exit 0; }
exit 1
MOCK
cat >"$MOCKBIN/netstat" <<'MOCK'
#!/bin/sh
exit 0
MOCK
cat >"$MOCKBIN/ifconfig" <<'MOCK'
#!/bin/sh
printf 'utun7: flags=8051<UP,POINTOPOINT,RUNNING>\n'
MOCK
cat >"$MOCKBIN/ipconfig" <<'MOCK'
#!/bin/sh
printf '192.0.2.44\n'
MOCK
cat >"$MOCKBIN/dscacheutil" <<'MOCK'
#!/bin/sh
[ "${DNS_MODE:-ok}" != empty ] || exit 0
printf 'ip_address: 203.0.113.20\nip_address: invalid\n'
MOCK
cat >"$MOCKBIN/sudo" <<'MOCK'
#!/bin/sh
printf 'unexpected sudo call\n' >&2
exit 99
MOCK
chmod +x "$MOCKBIN"/*

# Load core without dispatching its CLI. Routing commands and route-table are memory-only.
# shellcheck source=../vpn-split
source "$CLI"
RUN_DIR=$TMP/run; STATE=$RUN_DIR/state; HOSTS=$VPN_SPLIT_CONF_DIR/hosts.txt; CONFIG=$VPN_SPLIT_CONF_DIR/provider.conf; MODE_FILE=$VPN_SPLIT_CONF_DIR/mode
mkdir -p "$RUN_DIR"
route_fixture=$TMP/routes
: > "$route_fixture"
route_table() { cat "$route_fixture"; }
exact_route() { awk -v d="$1" '$1==d {print $2, $3}' "$route_fixture"; }
route_add() {
  local dest=$1 gw=$2
  [[ ${FAIL_ADD:-} != "$dest" ]] || return 1
  printf '%s %s %s\n' "$dest" "$gw" "$TUN_IFACE" >> "$route_fixture"
}
route_delete() {
  local dest=$1 gw=$2 tmp=$TMP/routes.new
  [[ ${FAIL_DELETE:-} != "$dest" ]] || return 1
  awk -v d="$dest" -v g="$gw" '!($1==d && $2==g)' "$route_fixture" > "$tmp" && mv "$tmp" "$route_fixture"
}
iface_for_gw() { printf '%s\n' "$TUN_IFACE"; }
TUN_IFACE=utun7; GW=10.8.0.1
reset_routes() {
  printf '0.0.0.0/0 192.0.2.1 en0\n' > "$route_fixture"
  printf '0.0.0.0/1 %s %s\n128.0.0.0/1 %s %s\n' "$GW" "$TUN_IFACE" "$GW" "$TUN_IFACE" >> "$route_fixture"
  rm -f "$STATE" "$STATE.new" "$STATE.applied" "$STATE.restored"
}

# Input normalization, canonicalization, comments, case, and final unterminated line.
if [[ $(normalize "HTTPS://Example.COM:8443/path?q=1") == example.com ]]; then check 0 'URL port/path normalization'; else check 1 'URL port/path normalization'; fi
if [[ $(normalize "192.0.2.7/24") == 192.0.2.7/24 ]]; then check 0 'valid CIDR normalization'; else check 1 'valid CIDR normalization'; fi
if [[ $(canonical "192.0.2.99/24") == 192.0.2.0/24 ]]; then check 0 'CIDR network canonicalization'; else check 1 'CIDR network canonicalization'; fi
if [[ $(canonical "192.0.2.9") == 192.0.2.9/32 ]]; then check 0 'IP canonicalization'; else check 1 'IP canonicalization'; fi
if ! normalize 256.2.3.4 >/dev/null 2>&1; then check 0 'reject out-of-range IPv4'; else check 1 'reject out-of-range IPv4'; fi
if ! normalize 01.2.3.4 >/dev/null 2>&1; then check 0 'reject leading-zero IPv4'; else check 1 'reject leading-zero IPv4'; fi
if ! normalize 192.0.2.1/33 >/dev/null 2>&1; then check 0 'reject oversized prefix'; else check 1 'reject oversized prefix'; fi
if ! normalize bad..example >/dev/null 2>&1; then check 0 'reject malformed domain'; else check 1 'reject malformed domain'; fi
printf '  # comment\nHTTPS://Example.Org:443/path # inline\n192.0.2.1' > "$HOSTS"
if [[ $(entries | wc -l | tr -d " ") == 2 ]]; then check 0 'entries strip comments, normalize case, keep unterminated last line'; else check 1 'entries strip comments, normalize case, keep unterminated last line'; fi

# CLI edits and invalid config must preserve existing provider bytes.
printf 'kind=scutil\nservice=Office VPN (work)\n' > "$CONFIG"
before=$(cksum "$CONFIG")
if ! "$CLI" config nonsense >/dev/null 2>&1; then check 0 'reject invalid provider config'; else check 1 'reject invalid provider config'; fi
if [[ $(cksum "$CONFIG") == "$before" ]]; then check 0 'invalid config does not modify existing config'; else check 1 'invalid config does not modify existing config'; fi
"$CLI" add "HTTPS://EXAMPLE.com:443/a" >/dev/null 2>&1
if [[ $(grep -c "^example.com$" "$HOSTS") == 1 ]]; then check 0 'add normalizes and avoids duplicate entries'; else check 1 'add normalizes and avoids duplicate entries'; fi
"$CLI" remove example.org >/dev/null 2>&1
if ! grep -qi example.org "$HOSTS"; then check 0 'remove matches normalized entries with inline comments'; else check 1 'remove matches normalized entries with inline comments'; fi
if [[ $(config_get service) == "Office VPN (work)" ]]; then check 0 'config preserves service names with spaces'; else check 1 'config preserves service names with spaces'; fi
invalid_config() { local CONFIG=$TMP/bad.conf; printf 'kind=scutil\nservice=-bad\n' > "$CONFIG"; ! validate_config >/dev/null 2>&1; }
if invalid_config; then check 0 'reject unsafe scutil service'; else check 1 'reject unsafe scutil service'; fi

# Provider status matching is exact, and status/info survive failed probes and no VPN.
printf 'kind=scutil\nservice=Office VPN (work)\n' > "$CONFIG"
SCUTIL_STATUS=Connected; export SCUTIL_STATUS
if [[ $(connected_state) == yes ]]; then check 0 'scutil exact Connected status'; else check 1 'scutil exact Connected status'; fi
SCUTIL_STATUS=Disconnected; export SCUTIL_STATUS
if [[ $(connected_state) == no ]]; then check 0 'scutil exact Disconnected status'; else check 1 'scutil exact Disconnected status'; fi
SCUTIL_STATUS="Not Connected"; export SCUTIL_STATUS
if [[ $(connected_state) == unknown ]]; then check 0 'scutil partial status is not treated as disconnected'; else check 1 'scutil partial status is not treated as disconnected'; fi
"$CLI" connect >/dev/null 2>&1
"$CLI" disconnect >/dev/null 2>&1
if grep -qx -- "--nc start Office VPN (work)" "$SCUTIL_LOG"; then check 0 'connect invokes scutil with exact service name'; else check 1 'connect invokes scutil with exact service name'; fi
if grep -qx -- "--nc stop Office VPN (work)" "$SCUTIL_LOG"; then check 0 'disconnect invokes scutil with exact service name'; else check 1 'disconnect invokes scutil with exact service name'; fi
CURL_MODE=fail; export CURL_MODE
info=$("$CLI" info 2>/dev/null)
if contains "$info" "connected=unknown"; then check 0 'info renders scutil state with failed probe'; else check 1 'info renders scutil state with failed probe'; fi
if contains "$info" "current_ip="; then check 0 'info still emits remote probe field on failure'; else check 1 'info still emits remote probe field on failure'; fi
if contains "$("$CLI" status 2>/dev/null)" "  目前路徑：取得失敗"; then check 0 'status renders failed probe'; else check 1 'status renders failed probe'; fi
if ! "$CLI" daemon >/dev/null 2>&1; then check 0 'daemon refuses non-root caller'; else check 1 'daemon refuses non-root caller'; fi

# Probe must report the remote address, observed interface, and latency. HTTP errors and short downloads fail.
CURL_MODE=probe; ROUTE_IFACE=utun7; export CURL_MODE ROUTE_IFACE
if [[ $(probe) == "203.0.113.7 198.51.100.8 utun7 25" ]]; then check 0 'probe reports actual public/remote IP, interface, and milliseconds'; else check 1 'probe reports actual public/remote IP, interface, and milliseconds'; fi
CURL_MODE=http; export CURL_MODE
if check_host example.org >/dev/null 2>&1; then check 0 'health check reports reachable HTTP error response'; else check 1 'health check reports reachable HTTP error response'; fi
CURL_MODE=fail; export CURL_MODE
if ! check_host example.org >/dev/null 2>&1; then check 0 'health check reports transport failure'; else check 1 'health check reports transport failure'; fi
CURL_MODE=speed; export CURL_MODE
if cmd_speedtest >/dev/null 2>&1; then check 0 'speed test accepts exact complete download'; else check 1 'speed test accepts exact complete download'; fi
CURL_MODE=truncated; export CURL_MODE
if ! cmd_speedtest >/dev/null 2>&1; then check 0 'speed test rejects truncated download'; else check 1 'speed test rejects truncated download'; fi

# Routing transaction tests use only the in-memory route fixture and temporary state.
reset_routes
printf '203.0.113.99/24\n' > "$HOSTS"
if apply_split "$GW" "$TUN_IFACE"; then check 0 'apply split installs destination and removes both VPN halves'; else check 1 'apply split installs destination and removes both VPN halves'; fi
if [[ $(exact_route 203.0.113.0/24) == "$GW $TUN_IFACE" && -z $(exact_route 0.0.0.0/1) && -z $(exact_route 128.0.0.0/1) ]]; then check 0 'successful split has complementary halves removed and target installed'; else check 1 'successful split has complementary halves removed and target installed'; fi
if [[ $(state_get applied) == split ]]; then check 0 'successful split state recorded'; else check 1 'successful split state recorded'; fi
if apply_split "$GW" "$TUN_IFACE"; then check 0 'second apply is successful'; else check 1 'second apply is successful'; fi
if [[ $(grep -c "^owned=" "$STATE") == 1 ]]; then check 0 'idempotent reapply preserves ownership without duplicate journal'; else check 1 'idempotent reapply preserves ownership without duplicate journal'; fi
if restore_routes; then check 0 'restore split routes'; else check 1 'restore split routes'; fi
if [[ $(exact_route 0.0.0.0/1) == "$GW $TUN_IFACE" && $(exact_route 128.0.0.0/1) == "$GW $TUN_IFACE" && -z $(exact_route 203.0.113.0/24) ]]; then check 0 'restore reconstitutes halves and deletes owned target'; else check 1 'restore reconstitutes halves and deletes owned target'; fi
if [[ $(state_get applied) == full ]]; then check 0 'restore marks full mode'; else check 1 'restore marks full mode'; fi

reset_routes
printf '203.0.113.0/24\n' > "$HOSTS"
printf '203.0.113.0/24 192.0.2.1 en0\n' >> "$route_fixture"
if ! apply_split "$GW" "$TUN_IFACE" >/dev/null 2>&1; then check 0 'conflicting preexisting target aborts'; else check 1 'conflicting preexisting target aborts'; fi
if [[ $(wc -l < "$route_fixture" | tr -d " ") == 4 && ! -e $STATE ]]; then check 0 'conflict aborts before route mutation or journaling'; else check 1 'conflict aborts before route mutation or journaling'; fi

reset_routes
printf '203.0.113.0/24\n198.51.100.0/24\n' > "$HOSTS"
FAIL_ADD=203.0.113.0/24
if ! apply_split "$GW" "$TUN_IFACE" >/dev/null 2>&1; then check 0 'failed destination add aborts'; else check 1 'failed destination add aborts'; fi
unset FAIL_ADD
if [[ -z $(exact_route 203.0.113.0/24) && -z $(exact_route 198.51.100.0/24) && $(exact_route 0.0.0.0/1) == "$GW $TUN_IFACE" && $(exact_route 128.0.0.0/1) == "$GW $TUN_IFACE" ]]; then check 0 'failed add rolls back all additions and restores halves'; else check 1 'failed add rolls back all additions and restores halves'; fi

reset_routes
printf '203.0.113.0/24\n' > "$HOSTS"
FAIL_DELETE=128.0.0.0/1
if ! apply_split "$GW" "$TUN_IFACE" >/dev/null 2>&1; then check 0 'failed second half removal aborts'; else check 1 'failed second half removal aborts'; fi
unset FAIL_DELETE
if [[ -z $(exact_route 203.0.113.0/24) && $(exact_route 0.0.0.0/1) == "$GW $TUN_IFACE" && $(exact_route 128.0.0.0/1) == "$GW $TUN_IFACE" ]]; then check 0 'failed half removal rolls back target and both halves'; else check 1 'failed half removal rolls back target and both halves'; fi

reset_routes
printf '203.0.113.0/24\n' > "$HOSTS"
printf '203.0.113.0/24 %s %s\n' "$GW" "$TUN_IFACE" >> "$route_fixture"
if apply_split "$GW" "$TUN_IFACE"; then check 0 'matching preexisting route permits split'; else check 1 'matching preexisting route permits split'; fi
if ! grep -q "^owned=203.0.113.0/24$" "$STATE"; then check 0 'matching preexisting route remains unowned'; else check 1 'matching preexisting route remains unowned'; fi
if restore_routes; then check 0 'restore with preexisting route succeeds'; else check 1 'restore with preexisting route succeeds'; fi
if [[ $(exact_route 203.0.113.0/24) == "$GW $TUN_IFACE" ]]; then check 0 'restore preserves preexisting matching route'; else check 1 'restore preserves preexisting matching route'; fi

reset_routes
printf '203.0.113.0/24\n' > "$HOSTS"
if apply_split "$GW" "$TUN_IFACE"; then check 0 'initial apply before changed-tunnel test'; else check 1 'initial apply before changed-tunnel test'; fi
if [[ $(state_get iface) == "$TUN_IFACE" ]]; then check 0 'journal owns original tunnel identity'; else check 1 'journal owns original tunnel identity'; fi
# Validate route ownership guard when an owned route was replaced by another interface.
awk '$1!="203.0.113.0/24"' "$route_fixture" > "$TMP/routes.other"
printf '203.0.113.0/24 192.0.2.9 en0\n' >> "$TMP/routes.other"; mv "$TMP/routes.other" "$route_fixture"
if restore_routes >/dev/null 2>&1; then check 0 'restore does not delete route replaced by another interface'; else check 1 'restore does not delete route replaced by another interface'; fi
if [[ $(exact_route 203.0.113.0/24) == "192.0.2.9 en0" ]]; then check 0 'route takeover is preserved'; else check 1 'route takeover is preserved'; fi

reset_routes
printf '203.0.113.0/24\n' > "$HOSTS"
if apply_split "$GW" "$TUN_IFACE"; then check 0 'initial apply before removed-target cleanup'; else check 1 'initial apply before removed-target cleanup'; fi
printf '198.51.100.0/24\n' > "$HOSTS"
if apply_split "$GW" "$TUN_IFACE"; then check 0 'changed target list reapplies'; else check 1 'changed target list reapplies'; fi
if [[ -z $(exact_route 203.0.113.0/24) && $(exact_route 198.51.100.0/24) == "$GW $TUN_IFACE" ]]; then check 0 'reapply removes stale owned destinations'; else check 1 'reapply removes stale owned destinations'; fi

reset_routes
printf '0.0.0.0/0\n' > "$HOSTS"
if ! apply_split "$GW" "$TUN_IFACE" >/dev/null 2>&1; then check 0 'reject /0 destination'; else check 1 'reject /0 destination'; fi
if [[ $(wc -l < "$route_fixture" | tr -d " ") == 3 ]]; then check 0 '/0 rejection preserves both halves'; else check 1 '/0 rejection preserves both halves'; fi

reset_routes
printf 'example.org\n' > "$HOSTS"
DNS_MODE=empty; export DNS_MODE
if ! apply_split "$GW" "$TUN_IFACE" >/dev/null 2>&1; then check 0 'DNS resolution failure aborts apply'; else check 1 'DNS resolution failure aborts apply'; fi
if [[ $(wc -l < "$route_fixture" | tr -d " ") == 3 ]]; then check 0 'resolution failure preserves VPN halves'; else check 1 'resolution failure preserves VPN halves'; fi

reset_routes
printf '0.0.0.0/1 %s %s\n' "$GW" "$TUN_IFACE" > "$route_fixture"
if ! tunnel >/dev/null 2>&1; then check 0 'one ambiguous half does not qualify as tunnel'; else check 1 'one ambiguous half does not qualify as tunnel'; fi

# CLI command refuses root-only install, and external operations remain stubbed.
if ! "$CLI" restore >/dev/null 2>&1; then check 0 'restore refuses non-root caller'; else check 1 'restore refuses non-root caller'; fi



reset_routes
printf '203.0.113.0/24\n' > "$HOSTS"
printf '203.0.113.9/32 192.0.2.1 en0\n' >> "$route_fixture"
if ! apply_split "$GW" "$TUN_IFACE" >/dev/null 2>&1; then check 0 'more-specific third-party route blocks split'; else check 1 'more-specific third-party route blocks split'; fi
if [[ ! -e $STATE && $(exact_route 203.0.113.9/32) == '192.0.2.1 en0' ]]; then check 0 'more-specific conflict does not mutate or acquire route'; else check 1 'more-specific conflict does not mutate or acquire route'; fi
reset_routes
awk '$1!="0.0.0.0/0"' "$route_fixture" > "$TMP/no-default"; mv "$TMP/no-default" "$route_fixture"
if ! apply_split "$GW" "$TUN_IFACE" >/dev/null 2>&1; then check 0 'missing physical default blocks split'; else check 1 'missing physical default blocks split'; fi

# Fail journal writes after a successful mutation. Recovery must not lose ownership.
journal() {
  [[ ${FAIL_JOURNAL:-} != "$1:$2" ]] || return 1
  printf '%s=%s\n' "$1" "$2" >> "$STATE"
}
reset_routes
printf '192.0.2.0/24\n198.51.100.0/24\n' > "$HOSTS"
FAIL_JOURNAL=owned:198.51.100.0/24
if ! apply_split "$GW" "$TUN_IFACE" >/dev/null 2>&1; then check 0 'journal failure aborts after an earlier route add'; else check 1 'journal failure aborts after an earlier route add'; fi
unset FAIL_JOURNAL
if [[ -z $(exact_route 192.0.2.0/24) && -z $(exact_route 198.51.100.0/24) && $(exact_route 0.0.0.0/1) == "$GW $TUN_IFACE" ]]; then check 0 'journal failure rolls back earlier additions'; else check 1 'journal failure rolls back earlier additions'; fi
reset_routes
printf '192.0.2.0/24\n' > "$HOSTS"
FAIL_JOURNAL=removed:128.0.0.0/1
if ! apply_split "$GW" "$TUN_IFACE" >/dev/null 2>&1; then check 0 'journal failure while removing halves aborts'; else check 1 'journal failure while removing halves aborts'; fi
unset FAIL_JOURNAL
if [[ -z $(exact_route 192.0.2.0/24) && $(exact_route 0.0.0.0/1) == "$GW $TUN_IFACE" && $(exact_route 128.0.0.0/1) == "$GW $TUN_IFACE" ]]; then check 0 'half journal failure restores all routes'; else check 1 'half journal failure restores all routes'; fi

# Lost/unknown route state cannot be treated as a successful cleanup.
reset_routes
printf '192.0.2.0/24\n' > "$HOSTS"
if apply_split "$GW" "$TUN_IFACE"; then check 0 'prepare interrupted cleanup'; else check 1 'prepare interrupted cleanup'; fi
printf 'applied=pending\n' >> "$STATE"
# This snapshot intentionally has duplicate applied keys; replace it with one pending marker.
grep -v '^applied=' "$STATE" > "$TMP/interrupted"
printf 'applied=pending\n' >> "$TMP/interrupted"; mv "$TMP/interrupted" "$STATE"
if apply_split "$GW" "$TUN_IFACE"; then check 0 'pending journal is recovered before reapply'; else check 1 'pending journal is recovered before reapply'; fi
if [[ $(grep -c '^owned=' "$STATE") == 1 ]]; then check 0 'recovered transaction retains exact ownership'; else check 1 'recovered transaction retains exact ownership'; fi
TUN_IFACE=''
if restore_routes; then check 0 'disconnected tunnel cleanup succeeds'; else check 1 'disconnected tunnel cleanup succeeds'; fi
if [[ -z $(exact_route 0.0.0.0/1) && -z $(exact_route 128.0.0.0/1) && -z $(exact_route 192.0.2.0/24) ]]; then check 0 'disconnect cleanup does not recreate stale VPN defaults'; else check 1 'disconnect cleanup does not recreate stale VPN defaults'; fi
TUN_IFACE=utun7

if (( failures )); then printf 'FAILED %d of %d assertions\n' "$failures" "$count" >&2; exit 1; fi
printf 'PASS %d assertions (all external network, provider, privilege, and route commands mocked)\n' "$count"
