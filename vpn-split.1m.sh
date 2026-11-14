#!/bin/bash
# <swiftbar.title>vpn-split</swiftbar.title>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
set -uo pipefail
BIN=${VPN_SPLIT_BIN:-"$HOME/.local/bin/vpn-split"}
SELF=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")
CONF_DIR=${VPN_SPLIT_CONF_DIR:-"$HOME/.config/vpn-split"}

quote() {
  local value=$1
  value=${value//\\/\\\\}; value=${value//\"/\\\"}
  printf '"%s"' "$value"
}
# SwiftBar uses | as the attribute delimiter, so do not emit unrepresentable paths.
for path in "$BIN" "$SELF" "$CONF_DIR"; do
  if [[ $path == *'|'* || $path == *$'\n'* || $path == *$'\r'* ]]; then
    printf 'VPN ?\n---\n路徑含不支援字元\n'; exit 1
  fi
done
[[ -x $BIN ]] || { printf 'VPN ? | sfimage=questionmark.circle\n---\n找不到 CLI\n'; exit 0; }
if [[ ${1:-} == add ]]; then
  input=$(/usr/bin/osascript -e 'text returned of (display dialog "要使用 VPN 的網域、網址或 IPv4：" default answer "" with title "vpn-split")' 2>/dev/null) || exit 0
  [[ -n $input ]] || exit 0
  message=$("$BIN" add "$input" 2>&1)
  /usr/bin/osascript -e 'on run argv' -e 'display notification (item 1 of argv) with title "vpn-split"' -e 'end run' "$message" >/dev/null 2>&1 || :
  exit 0
fi
if ! info=$("$BIN" info 2>/dev/null); then
  printf 'VPN ? | sfimage=exclamationmark.triangle\n---\n無法讀取狀態，請執行 doctor 檢查設定\n'
  printf '檢查設定 | bash=%s param1=doctor terminal=true\n' "$(quote "$BIN")"
  exit 0
fi
get() { awk -F= -v k="$1" '$1==k {sub(/^[^=]*=/, ""); print; exit}' <<< "$info"; }
action() {
  local title=$1 command=$2
  printf '%s | bash=%s param1=%s terminal=true refresh=true\n' "$title" "$(quote "$BIN")" "$(quote "$command")"
}
connected=$(get connected); desired=$(get mode); applied=$(get applied_mode)
case $connected in
  yes) printf 'VPN | sfimage=arrow.triangle.branch\n';;
  no) printf 'IP | sfimage=network\n';;
  *) printf 'VPN ? | sfimage=questionmark.circle\n';;
esac
printf '%s\n' '---'
case $connected in yes) printf 'VPN 已連線\n';; no) printf 'VPN 未連線\n';; *) printf 'VPN 狀態不明\n';; esac
printf '期望模式：%s，已套用：%s\n' "${desired:-未知}" "${applied:-none}"
printf '路由服務：%s\n' "$(get daemon)"
printf '區網 IP：%s（%s）\n' "$(get lan_ip)" "$(get lan_if)"
current=$(get current_ip); latency=$(get current_ms); vpn=$(get vpn_ip)
printf '目前出口 IP：%s\n' "${current:-取得失敗}"
printf '測試路徑：%s，TCP 延遲：%s ms\n' "$(get current_iface)" "${latency:-未知}"
printf 'VPN 出口 IP：%s\n' "${vpn:-無已驗證測試路徑}"
printf '%s\n' '---'
if [[ $connected == yes ]]; then action '中斷 VPN' disconnect; else action '連線 VPN' connect; fi
if [[ $desired == full ]]; then next='split'; else next='full'; fi
printf '切換到 %s | bash=%s param1=mode param2=%s terminal=false refresh=true\n' "$next" "$(quote "$BIN")" "$next"
printf '%s\n' '---' '分流清單'
while IFS= read -r line; do
  [[ $line == domain=* ]] || continue
  read -r name path ip <<< "${line#domain=}"
  [[ $name =~ ^[a-z0-9./-]+$ ]] || continue
  printf '%s（%s）\n' "$name" "$path"
  printf -- '--IP：%s | disabled=true\n' "$ip"
  printf -- '--從清單移除 | bash=%s param1=remove param2=%s terminal=false refresh=true\n' "$(quote "$BIN")" "$(quote "$name")"
done <<< "$info"
printf '加入網域… | bash=%s param1=add terminal=false refresh=true\n' "$(quote "$SELF")"
printf '編輯清單 | bash=/usr/bin/open param1=-t param2=%s terminal=false\n' "$(quote "$CONF_DIR/hosts.txt")"
printf '%s\n' '---'
action '完整狀態' status
action 'HTTPS 健康檢查' health
action '測速（下載 10 MB）' speedtest
action '設定與路由檢查' doctor
printf '重新整理 | refresh=true\n'
