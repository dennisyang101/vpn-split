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
  input=$(/usr/bin/osascript -e 'text returned of (display dialog "分流模式下走 VPN 的網域、網址、IPv4 或網段：" default answer "" with title "vpn-split")' 2>/dev/null) || exit 0
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
provider=$(get provider); iface=$(get iface); daemon=$(get daemon)
external_managed=no
if [[ $(get routing_supported) == no && -n $iface ]]; then external_managed=yes; fi
case $connected in
  yes) printf 'VPN | sfimage=arrow.triangle.branch\n';;
  no) printf 'IP | sfimage=network\n';;
  *) printf 'VPN ? | sfimage=questionmark.circle\n';;
esac
printf '%s\n' '---'
case $connected in
  yes) printf 'VPN：已連線\n';;
  no) printf 'VPN：未連線\n';;
  *) printf 'VPN：狀態不明\n';;
esac
mode_name() {
  case $1 in split) printf '僅清單目標走 VPN';; full) printf '全部走 VPN';; *) printf '未知模式';; esac
}
if [[ $external_managed == yes ]]; then
  printf '路由由 VPN App 管理（vpn-split 僅提供狀態與診斷）\n'
elif [[ $connected == yes && $daemon == running && ( $applied == split || $applied == full ) ]]; then
  printf '路由模式：%s' "$(mode_name "$applied")"
  if [[ $desired != "$applied" ]]; then printf '（待切換）'; fi
  printf '\n'
else
  printf '分流：未啟用\n'
fi
current=$(get current_ip); via=$(get current_iface); vpn=$(get vpn_ip)
if [[ -z $current ]]; then
  printf '目前出口 IP：取得失敗\n'
elif [[ -n $iface && $via == "$iface" ]]; then
  printf 'VPN 出口 IP：%s\n' "$current"
elif [[ $via =~ ^(en|bridge|bond|vlan)[0-9]+$ ]]; then
  printf '直連出口 IP：%s\n' "$current"
else
  printf '目前出口 IP：%s（路徑未確認）\n' "$current"
fi
if [[ -n $iface && ( -z $current || $via != "$iface" ) ]]; then
  printf 'VPN 出口 IP：%s\n' "${vpn:-未測得}"
fi
printf '區網 IP：%s\n' "$(get lan_ip)"
printf '%s\n' '---'
case $provider in
  manual|'')
    if [[ $connected == yes ]]; then label='手動模式，請至 VPN App 中斷'; else label='手動模式，請至 VPN App 連線'; fi
    printf '%s | disabled=true\n' "$label";;
  scutil|hooks)
    if [[ $connected == yes ]]; then action '中斷 VPN' disconnect
    elif [[ $connected == no ]]; then action '連線 VPN' connect; fi;;
esac
if [[ $external_managed == yes ]]; then
  printf '路由由 VPN App 管理，無法切換路由模式 | disabled=true\n'
else
  if [[ $desired == full ]]; then next='split'; else next='full'; fi
  printf '設定為%s | bash=%s param1=mode param2=%s terminal=false refresh=true\n' "$(mode_name "$next")" "$(quote "$BIN")" "$next"
fi
printf '%s\n' '---' '走 VPN 的網域與 IP'
if [[ $external_managed == yes ]]; then printf '清單目前唯讀（路由由 VPN App 管理） | disabled=true\n'; fi
targets=0
while IFS= read -r line; do
  [[ $line == domain=* ]] || continue
  read -r name path ip <<< "${line#domain=}"
  [[ $name =~ ^[a-z0-9./-]+$ ]] || continue
  targets=1
  case $path in vpn) mark='✓'; how='目前走 VPN';; direct) mark='✗'; how='目前直連';; *) mark='?'; how='路徑不明';; esac
  printf '%s %s\n' "$mark" "$name"
  printf -- '--%s | disabled=true\n' "$how"
  printf -- '--伺服器 IP：%s | disabled=true\n' "$ip"
  if [[ $external_managed == yes ]]; then printf '%s\n' '--無法移除（VPN App 管理路由） | disabled=true'
  else printf -- '--從清單移除 | bash=%s param1=remove param2=%s terminal=false refresh=true\n' "$(quote "$BIN")" "$(quote "$name")"; fi
done <<< "$info"
[[ $targets == 1 ]] || printf '尚未新增網域或 IP | disabled=true\n'
if [[ $external_managed == yes ]]; then
  printf '%s\n' '新增網域或 IP…（VPN App 管理路由） | disabled=true' '編輯清單（VPN App 管理路由） | disabled=true'
else
  printf '新增網域或 IP… | bash=%s param1=add terminal=false refresh=true\n' "$(quote "$SELF")"
  printf '編輯清單 | bash=/usr/bin/open param1=-t param2=%s terminal=false\n' "$(quote "$CONF_DIR/hosts.txt")"
fi
printf '%s\n' '---' '診斷'
action '--查看連線與分流狀態' status
action '--測試清單目標的 HTTPS 連線' health
if [[ $external_managed == yes ]]; then printf '%s\n' '--直連測速（10 MB，外部 VPN 管理模式停用） | disabled=true'
else printf -- '--直連測速（10 MB） | bash=%s param1=speedtest param2=direct terminal=true refresh=true\n' "$(quote "$BIN")"; fi
if [[ $connected == yes && $iface =~ ^utun[0-9]+$ ]]; then
  printf -- '--VPN 測速（10 MB） | bash=%s param1=speedtest param2=vpn terminal=true refresh=true\n' "$(quote "$BIN")"
else
  printf '%s\n' '--VPN 測速（10 MB） | disabled=true'
fi
action '--檢查設定與路由' doctor
printf '重新整理 | refresh=true\n'
