#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")" && pwd)
usage(){ printf 'Usage: %s [--routing]\nInstalls the user CLI and SwiftBar plugin. --routing opts into privileged routing installation.\n' "$0"; }
routing=no
case ${1:-} in '') ;; --help|-h) usage; exit 0;; --routing) routing=yes;; *) usage >&2; exit 2;; esac
BIN_DIR=${VPN_SPLIT_BIN_DIR:-"$HOME/.local/bin"}
CONF_DIR=${VPN_SPLIT_CONF_DIR:-"$HOME/.config/vpn-split"}
PLUGIN_DIR=$(defaults read com.ameba.SwiftBar PluginDirectory 2>/dev/null || :)
[[ -n $PLUGIN_DIR ]] || PLUGIN_DIR="$HOME/.config/swiftbar"
mkdir -p "$BIN_DIR" "$CONF_DIR" "$PLUGIN_DIR"
[[ -f $CONF_DIR/hosts.txt ]] || printf 'speed.cloudflare.com\napi.ipify.org\n' > "$CONF_DIR/hosts.txt"
[[ -f $CONF_DIR/mode ]] || printf 'split\n' > "$CONF_DIR/mode"
install -m 755 "$ROOT/vpn-split" "$BIN_DIR/vpn-split"
install -m 755 "$ROOT/vpn-split.1m.sh" "$PLUGIN_DIR/vpn-split.1m.sh"
if [[ $routing == yes ]]; then "$BIN_DIR/vpn-split" install-routing; else printf 'User CLI and SwiftBar plugin installed. No daemon or privileged routes installed.\n'; fi
