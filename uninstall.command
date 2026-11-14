#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")" && pwd)
usage(){ printf 'Usage: %s [--routing]\nRemoves user CLI and SwiftBar plugin; configuration is retained.\n' "$0"; }
routing=no
case ${1:-} in '') ;; --help|-h) usage; exit 0;; --routing) routing=yes;; *) usage >&2; exit 2;; esac
BIN_DIR=${VPN_SPLIT_BIN_DIR:-"$HOME/.local/bin"}
PLUGIN_DIR=$(defaults read com.ameba.SwiftBar PluginDirectory 2>/dev/null || :)
[[ -n $PLUGIN_DIR ]] || PLUGIN_DIR="$HOME/.config/swiftbar"
if [[ $routing == yes ]]; then
  if [[ -x $BIN_DIR/vpn-split ]]; then "$BIN_DIR/vpn-split" uninstall-routing
  else "$ROOT/vpn-split" uninstall-routing; fi
fi
rm -f "$BIN_DIR/vpn-split" "$PLUGIN_DIR/vpn-split.1m.sh"
printf 'CLI and plugin removed. Configuration retained at %s.\n' "${VPN_SPLIT_CONF_DIR:-$HOME/.config/vpn-split}"
