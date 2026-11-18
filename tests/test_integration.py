"""Sandboxed CLI, menu, installer, and trust-boundary checks. No live network operations."""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / "vpn-split"


class Integration(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="vpn-split-integration-", dir=os.environ.get("TMPDIR"))
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        self.home = self.base / "home with 'quote"
        self.conf = self.home / ".config/vpn-split"
        self.bin = self.base / "mocks"
        self.plugin = self.home / "menu plugins"
        self.conf.mkdir(parents=True)
        self.bin.mkdir()
        self.env = dict(os.environ, HOME=str(self.home), VPN_SPLIT_CONF_DIR=str(self.conf),
                        VPN_SPLIT_UID=str(os.getuid()), PLUGIN_DIR=str(self.plugin),
                        CALL_LOG=str(self.base / "calls"), PATH=f"{self.bin}:{os.environ['PATH']}",
                        CURL_MODE="fail", VPN_MODE="none")
        self.script("defaults", 'printf "%s\\n" "$PLUGIN_DIR"')
        self.script("sudo", 'printf "sudo\\n" >> "$CALL_LOG"; exit 99')
        self.script("launchctl", 'printf "launchctl\\n" >> "$CALL_LOG"; exit 99')
        self.script("ipconfig", 'printf "192.0.2.44\\n"')
        self.script("dscacheutil", 'printf "ip_address: 203.0.113.20\\n"')
        self.script("netstat", '''[ "${NETSTAT_FAIL:-no}" != yes ] || exit 1
[ "$VPN_MODE" != none ] || exit 0
printf 'Routing tables\nInternet:\nDestination Gateway Flags Netif Expire\n0/1 10.8.0.1 UGSc utun7\n'
if [ "$VPN_MODE" = mismatch ]; then printf '128.0/1 10.9.0.1 UGSc utun8\n'; else printf '128.0/1 10.8.0.1 UGSc utun7\n'; fi''')
        self.script("ifconfig", "printf 'utun7: flags=8051<UP,POINTOPOINT,RUNNING>\\n    inet 10.8.0.2 --> 10.8.0.1 netmask 0xffffffff\\n'")
        self.script("route", '''if [ "$1 $2" = '-n get' ]; then printf 'interface: en0\n'; else printf 'unexpected route mutation\n' >> "$CALL_LOG"; exit 99; fi''')
        self.script("scutil", '''printf '%s\n' "$*" >> "$CALL_LOG"
[ "$1 $2" != '--nc status' ] || printf 'Disconnected\n' ''')
        self.script("curl", '''case "$CURL_MODE" in
 probe) printf 'ip=203.0.113.7\nVS_REMOTE 198.51.100.8 0.025\n';;
 httpfail) printf '10000000 1.0 198.51.100.8 503';;
 *) exit 7;; esac''')

    def script(self, name, body):
        path = self.bin / name
        path.write_text("#!/bin/sh\n" + body + "\n")
        path.chmod(0o755)
        return path

    def run_cli(self, *args, ok=True):
        result = subprocess.run([str(CLI), *args], env=self.env, capture_output=True, text=True, timeout=15)
        if ok:
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0)
        return result

    def source(self, code, ok=True):
        result = subprocess.run(["/bin/bash", "-c", 'source "$1"; ' + code, "test", str(CLI)],
                                env=self.env, capture_output=True, text=True, timeout=15)
        if ok:
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0)
        return result

    def test_hooks_are_explicit_and_status_does_not_connect(self):
        start = self.script("start hook", 'printf "start\\n" >> "$CALL_LOG"')
        stop = self.script("stop hook", 'printf "stop\\n" >> "$CALL_LOG"')
        self.run_cli("config", "hooks", str(start), str(stop))
        self.run_cli("status")
        self.assertFalse((self.base / "calls").exists())
        self.run_cli("connect")
        self.run_cli("disconnect")
        self.assertEqual((self.base / "calls").read_text(), "start\nstop\n")

    def test_config_failure_is_atomic(self):
        self.run_cli("config", "manual")
        before = (self.conf / "provider.conf").read_bytes()
        self.run_cli("config", "hooks", "/missing/start", "/missing/stop", ok=False)
        self.assertEqual((self.conf / "provider.conf").read_bytes(), before)
        self.run_cli("config", "scutil", "first\nkind=hooks", ok=False)
        self.assertEqual((self.conf / "provider.conf").read_bytes(), before)

    def test_no_vpn_menu_and_quoted_actions(self):
        self.run_cli("add", "example.org", "192.0.2.0/24")
        self.env["VPN_SPLIT_BIN"] = str(CLI)
        result = subprocess.run([str(ROOT / "vpn-split.1m.sh")], env=self.env,
                                capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("VPN：未連線", result.stdout)
        self.assertIn("目前出口 IP：取得失敗", result.stdout)
        for label in ("手動模式，請至 VPN App 連線", "新增網域或 IP", "編輯清單", "直連測速（10 MB）", "測試清單目標的 HTTPS 連線", "192.0.2.0/24"):
            self.assertIn(label, result.stdout)
        edit = next(line for line in result.stdout.splitlines() if line.startswith("編輯清單"))
        attrs = dict(token.split("=", 1) for token in shlex.split(edit.split("|", 1)[1]))
        self.assertEqual(attrs["param2"], str(self.conf / "hosts.txt"))
        remove = next(line for line in result.stdout.splitlines() if "param1=remove" in line)
        attrs = dict(token.split("=", 1) for token in shlex.split(remove.split("|", 1)[1]))
        self.assertEqual(attrs["bash"], str(CLI))
        self.assertIn(attrs["param2"], ("example.org", "192.0.2.0/24"))

    def menu(self, targets="", **fields):
        info = dict(connected="no", iface="", mode="split", applied_mode="none", daemon="stopped",
                    provider="manual", lan_ip="192.0.2.44", current_ip="203.0.113.7", current_iface="en0")
        info.update(fields)
        text = "".join(f"{k}={v}\n" for k, v in info.items()) + targets
        fake = self.script("menu cli", "printf '%s' " + shlex.quote(text))
        env = dict(self.env, VPN_SPLIT_BIN=str(fake))
        result = subprocess.run([str(ROOT / "vpn-split.1m.sh")], env=env,
                                capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def test_menu_disconnected_is_concise_and_manual_is_not_an_action(self):
        out = self.menu()
        self.assertEqual(out.count("VPN：未連線"), 1)
        self.assertIn("分流：未啟用\n", out)
        self.assertIn("直連出口 IP：203.0.113.7\n", out)
        self.assertIn("尚未新增網域或 IP | disabled=true", out)
        self.assertIn("手動模式，請至 VPN App 連線 | disabled=true", out)
        for unwanted in ('param1="connect"', 'param1="disconnect"', "背景服務", "想要", "對方看到", "VPN 出口 IP"):
            self.assertNotIn(unwanted, out)
        self.assertIn("目前出口 IP：取得失敗", self.menu(current_ip=""))
        self.assertIn("（路徑未確認）", self.menu(current_iface="utun99"))

    def test_menu_modes_use_actual_applied_state(self):
        base = dict(connected="yes", iface="utun7", daemon="running", vpn_ip="198.51.100.99")
        for mode, label, next_mode in (("split", "僅清單目標走 VPN", "full"), ("full", "全部走 VPN", "split")):
            with self.subTest(mode=mode):
                out = self.menu(**base, mode=mode, applied_mode=mode)
                self.assertIn(f"路由模式：{label}\n", out)
                self.assertIn(f"param2={next_mode}", out)
                self.assertIn("手動模式，請至 VPN App 中斷 | disabled=true", out)
                self.assertNotIn('param1="disconnect"', out)
        out = self.menu(**base, mode="full", applied_mode="split")
        self.assertIn("路由模式：僅清單目標走 VPN（待切換）", out)
        self.assertIn("分流：未啟用", self.menu(**base, applied_mode="none"))
        self.assertIn("分流：未啟用", self.menu(connected="yes", applied_mode="split", daemon="stopped"))
        out = self.menu(**base, current_iface="utun7", current_ip="198.51.100.99")
        self.assertEqual(out.count("VPN 出口 IP：198.51.100.99"), 1)
        self.assertNotIn("直連出口 IP", out)
        self.assertIn("VPN 出口 IP：未測得", self.menu(connected="yes", iface="utun7"))

    def test_menu_configured_providers_keep_connection_actions(self):
        for provider in ("scutil", "hooks"):
            for connected, command in (("yes", "disconnect"), ("no", "connect")):
                with self.subTest(provider=provider, connected=connected):
                    out = self.menu(provider=provider, connected=connected)
                    line = next(line for line in out.splitlines() if f'param1="{command}"' in line)
                    attrs = dict(token.split("=", 1) for token in shlex.split(line.split("|", 1)[1]))
                    self.assertEqual(attrs["param1"], command)
                    self.assertEqual(attrs["terminal"], "true")

    def test_menu_diagnostics_are_submenu_actions(self):
        out = self.menu(targets="domain=example.org direct 192.0.2.80\n")
        lines = out.splitlines()
        index = lines.index("診斷")
        expected = (("status", ""), ("health", ""), ("speedtest", "direct"), ("speedtest", "vpn"), ("doctor", ""))
        for line, (command, mode) in zip(lines[index + 1:index + 6], expected):
            self.assertTrue(line.startswith("--"), line)
            attrs = dict(token.split("=", 1) for token in shlex.split(line.split("|", 1)[1]))
            if mode == "vpn":
                self.assertEqual(line, "--VPN 測速（10 MB） | disabled=true")
                continue
            self.assertEqual(attrs["param1"], command)
            if mode:
                self.assertEqual(attrs["param2"], mode)
            self.assertEqual(attrs["terminal"], "true")
        self.assertEqual(lines[index + 6], "重新整理 | refresh=true")
        self.assertIn("走 VPN 的網域與 IP", out)
        self.assertIn("✗ example.org\n--目前直連", out)
        self.assertNotIn("尚未新增網域或 IP", out)

    def test_menu_enables_vpn_speedtest_only_for_live_tunnel(self):
        out = self.menu(connected="yes", iface="utun7")
        line = next(line for line in out.splitlines() if line.startswith("--VPN 測速"))
        self.assertIn("param1=speedtest param2=vpn", line)

    def test_info_reports_provider_for_menu(self):
        self.assertIn("provider=manual\n", self.run_cli("info").stdout)
        self.run_cli("config", "scutil", "Test VPN")
        self.assertIn("provider=scutil\n", self.run_cli("info").stdout)
        start = self.script("start hook", "exit 0")
        stop = self.script("stop hook", "exit 0")
        self.run_cli("config", "hooks", str(start), str(stop))
        self.assertIn("provider=hooks\n", self.run_cli("info").stdout)

    def speed_fixtures(self):
        self.env.update(SPEED_OUTPUT="10000000 2.000 198.51.100.8 200 192.0.2.44",
                        SPEED_CURL_EXIT="0", SPEED_ROUTE_IFACE="en0", SPEED_ROUTE_EXIT="0",
                        SPEED_IFCONFIG_EXIT="0", SPEED_DEFAULT="en0", SPEED_CHANGE="no",
                        SPEED_MARK=str(self.base / "speed-done"))
        self.script("netstat", '''printf 'Routing tables\nInternet:\nDestination Gateway Flags Netif Expire\n'
if [ "$SPEED_CHANGE" = yes ] && [ -f "$SPEED_MARK" ]; then exit 0; fi
case "$SPEED_DEFAULT" in
 none) ;;
 multiple) printf 'default 192.0.2.1 UGSc en0\ndefault 192.0.2.2 UGSc en1\n';;
 *) printf 'default 192.0.2.1 UGSc %s\n' "$SPEED_DEFAULT";;
esac
if [ "$VPN_MODE" = supported ]; then printf '0/1 10.8.0.1 UGSc utun7\n128.0/1 10.8.0.1 UGSc utun7\n'; fi''')
        self.script("ifconfig", '''if [ "$1" = en0 ]; then
 printf 'en0: flags=8863<UP>\n    inet 192.0.2.44 netmask 0xffffff00\n    inet 192.0.2.45 netmask 0xffffff00\n'
else
 printf 'utun7: flags=8051<UP,POINTOPOINT,RUNNING>\n    inet 10.8.0.2 --> 10.8.0.1 netmask 0xffffffff\n'
fi
exit "$SPEED_IFCONFIG_EXIT"''')
        self.script("curl", '''printf 'curl\n' >> "$CALL_LOG"
printf '%s\n' "$@" > "$SPEED_MARK"
for key in http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY; do
 eval 'value=${'"$key"'-}'
 [ -z "$value" ] || exit 91
done
printf '%s' "$SPEED_OUTPUT"
exit "$SPEED_CURL_EXIT"''')
        self.script("route", '''[ "$1 $2 $3" = '-n get -ifscope' ] || exit 99
printf 'scope:%s:%s\n' "$4" "$5" >> "$CALL_LOG"
printf 'interface: %s\n' "$SPEED_ROUTE_IFACE"
exit "$SPEED_ROUTE_EXIT"''')

    def test_speedtest_binds_each_path_and_checks_full_download(self):
        self.speed_fixtures()
        for kind, iface, local, label in (("direct", "en0", "192.0.2.44", "直連"),
                                           ("vpn", "utun7", "10.8.0.2", "VPN")):
            with self.subTest(kind=kind):
                self.env.update(VPN_MODE="supported", SPEED_ROUTE_IFACE=iface,
                                SPEED_OUTPUT=f"10000000 2.000 198.51.100.8 200 {local}")
                out = self.run_cli("speedtest", kind).stdout
                self.assertEqual(out, f"{label} 測速：介面 {iface}，下載 10000000 bytes，耗時 2.000 s，平均 40.0 Mbps\n")
                args = (self.base / "speed-done").read_text().splitlines()
                self.assertEqual(args[0], "-q")
                self.assertEqual(args[args.index("--interface") + 1], "if!" + iface)
                self.assertEqual(args[args.index("--noproxy") + 1], "*")
                self.assertIn("https://speed.cloudflare.com/__down?bytes=10000000", args)
                self.assertIn(f"scope:{iface}:198.51.100.8", (self.base / "calls").read_text())
        self.assertNotIn("sudo", (self.base / "calls").read_text())
        self.assertNotIn("launchctl", (self.base / "calls").read_text())
        self.assertFalse(self.conf.joinpath("hosts.txt").exists())
        self.assertFalse(self.conf.joinpath("mode").exists())

    def test_speedtest_rejects_unavailable_paths_before_downloading(self):
        self.speed_fixtures()
        for args, default in ((("vpn",), "en0"), (("direct",), "none"),
                              (("direct",), "multiple"), (("direct",), "utun99"),
                              (("unknown",), "en0"), (("direct", "extra"), "en0")):
            with self.subTest(args=args, default=default):
                self.env["SPEED_DEFAULT"] = default
                result = self.run_cli("speedtest", *args, ok=False)
                self.assertNotIn("Mbps", result.stdout)
                self.assertFalse((self.base / "speed-done").exists())

    def test_vpn_speedtest_requires_tunnel_route_to_speed_host(self):
        self.speed_fixtures()
        for overrides in ({"SPEED_ROUTE_IFACE": "", "SPEED_ROUTE_EXIT": "1"}, {"SPEED_ROUTE_IFACE": "en0"}):
            with self.subTest(overrides=overrides):
                self.env.update(VPN_MODE="supported", SPEED_ROUTE_IFACE="utun7", SPEED_ROUTE_EXIT="0")
                self.env.update(overrides)
                (self.base / "speed-done").unlink(missing_ok=True)
                result = self.run_cli("speedtest", "vpn", ok=False)
                self.assertIn("vpn-split add speed.cloudflare.com", result.stderr)
                self.assertFalse((self.base / "speed-done").exists())

    def test_speedtest_rejects_invalid_transfers_without_fallback(self):
        self.speed_fixtures()
        for output, exit_code in (("10000000 2 198.51.100.8 503 192.0.2.44", "0"),
                                  ("999 2 198.51.100.8 200 192.0.2.44", "0"),
                                  ("10000000 0 198.51.100.8 200 192.0.2.44", "0"),
                                  ("10000000 bad 198.51.100.8 200 192.0.2.44", "0"),
                                  ("10000000 2 invalid 200 192.0.2.44", "0"),
                                  ("10000000 2 198.51.100.8 200 invalid", "0"),
                                  ("", "7")):
            with self.subTest(output=output, exit_code=exit_code):
                self.env.update(SPEED_OUTPUT=output, SPEED_CURL_EXIT=exit_code)
                result = self.run_cli("speedtest", "direct", ok=False)
                self.assertNotIn("Mbps", result.stdout)
        self.assertEqual((self.base / "calls").read_text().splitlines(), ["curl"] * 7)

    def test_speedtest_rejects_unverified_or_changed_interface(self):
        self.speed_fixtures()
        cases = ({"SPEED_OUTPUT": "10000000 2 198.51.100.8 200 10.8.0.2"},
                 {"SPEED_ROUTE_IFACE": "utun99"}, {"SPEED_ROUTE_IFACE": ""},
                 {"SPEED_ROUTE_EXIT": "1"}, {"SPEED_IFCONFIG_EXIT": "1"},
                 {"SPEED_CHANGE": "yes"})
        for overrides in cases:
            with self.subTest(overrides=overrides):
                self.env.update(SPEED_OUTPUT="10000000 2 198.51.100.8 200 192.0.2.44",
                                SPEED_ROUTE_IFACE="en0", SPEED_ROUTE_EXIT="0",
                                SPEED_IFCONFIG_EXIT="0", SPEED_CHANGE="no")
                self.env.update(overrides)
                (self.base / "speed-done").unlink(missing_ok=True)
                result = self.run_cli("speedtest", "direct", ok=False)
                self.assertNotIn("Mbps", result.stdout)
        self.env.update(SPEED_CHANGE="yes", VPN_MODE="supported",
                        SPEED_OUTPUT="10000000 2 198.51.100.8 200 10.8.0.2", SPEED_ROUTE_IFACE="utun7")
        (self.base / "speed-done").unlink()
        self.run_cli("speedtest", "vpn", ok=False)

    def test_speedtest_suppresses_proxy_environment(self):
        self.speed_fixtures()
        for key in ("http_proxy", "https_proxy", "all_proxy", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY"):
            self.env[key] = "http://127.0.0.1:9"
        self.assertIn("直連 測速", self.run_cli("speedtest").stdout)

    def test_current_probe_is_not_falsely_labeled_vpn(self):
        self.env["CURL_MODE"] = "probe"
        info = self.run_cli("info").stdout
        self.assertIn("current_ip=203.0.113.7", info)
        self.assertIn("current_ms=25", info)
        self.assertIn("current_iface=en0", info)
        self.assertIn("vpn_ip=\n", info)
        self.env["CURL_MODE"] = "httpfail"
        self.run_cli("speedtest", ok=False)

    def test_vpn_exit_ip_comes_from_listed_echo_host_through_tunnel(self):
        self.env.update(VPN_MODE="supported", ECHO_IFACE="utun7")
        self.script("curl", '''case "$*" in
 *api.ipify.org*) printf 'echo\\n' >> "$CALL_LOG"; printf '198.51.100.99\\nVS_REMOTE 192.0.2.80\\n';;
 *) printf 'ip=203.0.113.7\\nVS_REMOTE 198.51.100.8 0.025\\n';; esac''')
        self.script("route", '''[ "$1 $2" = '-n get' ] || exit 99
if [ "$3" = 192.0.2.80 ]; then printf 'interface: %s\\n' "$ECHO_IFACE"; else printf 'interface: en0\\n'; fi''')
        self.assertIn("vpn_ip=\n", self.run_cli("info").stdout)
        self.assertFalse((self.base / "calls").exists(), "echo host must not be contacted unless listed")
        self.run_cli("add", "api.ipify.org")
        self.assertIn("vpn_ip=198.51.100.99\n", self.run_cli("info").stdout)
        self.env["ECHO_IFACE"] = "en0"
        self.assertIn("vpn_ip=\n", self.run_cli("info").stdout)

    def render(self, **fields):
        info = dict(connected="yes", iface="utun4", mode="split", applied_mode="split", daemon="running",
                    lan_if="en0", lan_ip="192.0.2.44", current_ip="203.0.113.7", current_iface="en0",
                    current_ms="13", vpn_ip="198.51.100.99")
        info.update(fields)
        text = "".join(f"{k}={v}\n" for k, v in info.items())
        text += "domain=dash.example.com vpn 192.0.2.80\ndomain=b.example.org direct 203.0.113.20\n"
        return self.source(f"render_status <<< {shlex.quote(text)}").stdout

    def test_status_separates_exit_ips_from_site_server_ips(self):
        self.assertEqual(self.render(), """分流：已套用（VPN utun4，背景服務運作中）

出口 IP（對方看到的你）
  直連：203.0.113.7（en0，延遲 13 ms）
  VPN：198.51.100.99（utun4）

清單網站（網站 → 伺服器 IP）
  ✓ VPN   dash.example.com  192.0.2.80
  ✗ 直連  b.example.org     203.0.113.20

區網 IP：192.0.2.44（en0）
""")

    def test_status_spells_out_unapplied_state_and_failed_probe(self):
        out = self.render(connected="no", iface="", applied_mode="none", daemon="stopped",
                          current_ip="", current_iface="", current_ms="", vpn_ip="")
        for line in ("VPN：未連線", "模式：想要 分流，目前已套用 無", "背景服務：未執行",
                     "  目前路徑：取得失敗", "  VPN：未連線"):
            self.assertIn(line + "\n", out)

    def test_status_labels_probe_through_tunnel_as_vpn(self):
        out = self.render(mode="full", applied_mode="full", current_iface="utun4", vpn_ip="203.0.113.7")
        self.assertIn("全隧道：已套用", out)
        self.assertIn("  直連：未測得（測試流量走 VPN）\n", out)
        self.assertIn("  VPN：203.0.113.7（utun4，延遲 13 ms）\n", out)
        self.assertIn("  VPN：未測得（清單加入 api.ipify.org 即可顯示）\n", self.render(vpn_ip=""))

    def test_vpn_probe_handles_large_list_without_sigpipe(self):
        self.script("curl", "printf '198.51.100.99\\nVS_REMOTE 192.0.2.80\\n'")
        self.script("route", "printf 'interface: utun7\\n'")
        out = self.source("entries() { local i; printf '%s\\n' api.ipify.org; for ((i=0;i<12000;i++)); do printf '%s\\n' example.org || return; done; }; vpn_probe utun7")
        self.assertEqual(out.stdout, "198.51.100.99\n")

    def test_status_does_not_call_another_tunnel_direct(self):
        for iface in ("utun99", "ipsec0", "unknown", ""):
            with self.subTest(iface=iface):
                out = self.render(current_iface=iface)
                self.assertNotIn("  直連：203.0.113.7", out)
                self.assertIn("  目前路徑：203.0.113.7", out)

    def test_real_tunnel_parser_rejects_mismatched_halves(self):
        self.env["VPN_MODE"] = "supported"
        self.assertEqual(self.source("tunnel").stdout.strip(), "10.8.0.1 utun7")
        self.env["VPN_MODE"] = "mismatch"
        self.source("tunnel", ok=False)
        self.run_cli("routing-plan", ok=False)

    def test_interface_scoped_defaults_do_not_count_as_default_route(self):
        # VM/container bridges add ifscope defaults (flag I) beside the real one.
        self.script("netstat", '''printf 'Routing tables\\nInternet:\\nDestination Gateway Flags Netif Expire\\n'
printf 'default 192.0.2.1 UGScg en0\\ndefault link#21 UCSIg bridge100 !\\n0/1 10.8.0.1 UGSc utun7\\n'
''')
        self.assertEqual(self.source("exact_route 0.0.0.0/0").stdout, "192.0.2.1 en0\n")

    def test_waits_for_launchd_to_unload_before_reinstall(self):
        # launchd keeps a booted-out job listed briefly; bootstrapping then fails with EIO.
        pending = self.base / "pending"
        self.script("launchctl", f'''[ "$1" = print ] || exit 99
n=$(cat {shlex.quote(str(pending))}); [ "$n" -gt 0 ] || exit 113
echo $((n - 1)) > {shlex.quote(str(pending))}''')
        pending.write_text("3\n")
        self.source("sleep() { :; }; wait_service_unloaded")
        self.assertEqual(pending.read_text(), "0\n")
        pending.write_text("1000\n")
        self.source("sleep() { :; }; wait_service_unloaded", ok=False)

    def test_launchd_query_error_is_not_treated_as_unloaded(self):
        self.script("launchctl", "exit 99")
        self.source("wait_service_unloaded", ok=False)

    def test_uninstall_wait_failure_keeps_helper_and_plist(self):
        self.script("launchctl", "exit 0")
        plist = self.base / "service.plist"
        plist.write_text("fixture")
        self.env["TEST_PLIST"] = str(plist)
        self.env["TEST_STATE"] = str(self.base / "no-state")
        code = 'PLIST=$TEST_PLIST; STATE=$TEST_STATE; ROOT_BIN=$HOME/no-helper; sudo() { printf "sudo:%s\\n" "$*" >> "$CALL_LOG"; }; wait_service_unloaded() { printf "wait\\n" >> "$CALL_LOG"; return 1; }; cmd_uninstall_routing'
        self.source(code, ok=False)
        log = (self.base / "calls").read_text()
        self.assertIn("sudo:launchctl bootout", log)
        self.assertIn("wait\n", log)
        self.assertNotIn("sudo:rm", log)
        self.assertTrue(plist.is_file())

    def test_missing_service_is_idempotent_but_query_errors_are_not(self):
        self.script("launchctl", "exit 113")
        self.source("stop_routing_service")
        self.assertFalse((self.base / "calls").exists())
        self.script("launchctl", "exit 99")
        self.source("stop_routing_service", ok=False)
        self.assertFalse((self.base / "calls").exists())

    def test_reinstall_wait_timeout_does_not_replace_helper_or_bootstrap(self):
        self.run_cli("add", "example.org")
        self.script("launchctl", "exit 0")
        self.script("sudo", 'printf "%s\\n" "$*" >> "$CALL_LOG"')
        self.source("sleep() { :; }; cmd_install_routing", ok=False)
        calls = (self.base / "calls").read_text().splitlines()
        self.assertEqual(calls, ["launchctl bootout system/local.vpn-split"])

    def test_secure_config_rejects_symlinks_and_writable_files(self):
        self.run_cli("add", "example.org")
        self.source("secure_config")
        hosts = self.conf / "hosts.txt"
        hosts.chmod(0o666)
        self.source("secure_config", ok=False)
        hosts.chmod(0o600)
        moved = self.conf / "other"
        hosts.rename(moved)
        hosts.symlink_to(moved)
        self.source("secure_config", ok=False)

    def test_root_daemon_identity_is_readable_without_signaling(self):
        self.script("ps", 'printf "%s %s\\n" "$MOCK_UID" "$MOCK_PROCESS"')
        run = self.base / "run"
        (run / "lock").mkdir(parents=True)
        (run / "lock/pid").write_text("12345\n")
        self.env.update(TEST_RUN=str(run), MOCK_UID="0",
                        MOCK_PROCESS="/bin/bash /Library/PrivilegedHelperTools/local.vpn-split daemon")
        self.source('RUN_DIR=$TEST_RUN; daemon_running')
        self.env["MOCK_UID"] = str(os.getuid())
        self.source('RUN_DIR=$TEST_RUN; daemon_running', ok=False)
        self.env.update(MOCK_UID="0", MOCK_PROCESS="/sbin/launchd")
        self.source('RUN_DIR=$TEST_RUN; daemon_running', ok=False)

    def test_failed_route_query_preserves_recovery_journal(self):
        state = self.base / "recovery-state"
        journal = "gw=10.8.0.1\niface=utun7\napplied=pending\nremoved=0.0.0.0/1\nowned=192.0.2.0/24\n"
        state.write_text(journal)
        self.env["TEST_STATE"] = str(state)
        self.env["NETSTAT_FAIL"] = "yes"
        self.source('STATE=$TEST_STATE; restore_routes', ok=False)
        self.assertEqual(state.read_text(), journal)
        self.assertFalse((self.base / "calls").exists())

    def test_installer_seeds_defaults_only_when_hosts_file_is_absent(self):
        expected = b"speed.cloudflare.com\napi.ipify.org\n"
        cases = {
            "fresh": None,
            "custom": b"custom.example\n# retained comment\n",
            "comments": b"# intentionally empty\n# no defaults\n",
            "empty": b"",
        }
        for name, initial in cases.items():
            with self.subTest(name=name):
                conf = self.base / name / "config"
                conf.mkdir(parents=True)
                hosts = conf / "hosts.txt"
                if initial is not None:
                    hosts.write_bytes(initial)
                env = dict(self.env, VPN_SPLIT_CONF_DIR=str(conf),
                           VPN_SPLIT_BIN_DIR=str(self.base / name / "bin"))
                command = [str(ROOT / "install.command")]
                result = subprocess.run(command, env=env, capture_output=True,
                                        text=True, timeout=15)
                self.assertEqual(result.returncode, 0, result.stderr)
                seeded = hosts.read_bytes()
                self.assertEqual(seeded, expected if initial is None else initial)
                result = subprocess.run(command, env=env, capture_output=True,
                                        text=True, timeout=15)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(hosts.read_bytes(), seeded)
        self.assertFalse((self.base / "calls").exists(),
                         "installer invoked privilege or host networking")

    def test_sandbox_install_upgrade_uninstall(self):
        self.run_cli("add", "example.org")
        (self.conf / "mode").write_text("full\n")
        before = (self.conf / "hosts.txt").read_bytes()
        for _ in range(2):
            result = subprocess.run([str(ROOT / "install.command")], env=self.env,
                                    capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.conf / "hosts.txt").read_bytes(), before)
        self.assertEqual((self.conf / "mode").read_text(), "full\n")
        self.assertEqual((self.home / ".local/bin/vpn-split").read_bytes(), CLI.read_bytes())
        self.assertTrue((self.plugin / "vpn-split.1m.sh").is_file())
        result = subprocess.run([str(ROOT / "uninstall.command")], env=self.env,
                                capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.home / ".local/bin/vpn-split").exists())
        self.assertFalse((self.plugin / "vpn-split.1m.sh").exists())
        self.assertEqual((self.conf / "hosts.txt").read_bytes(), before)
        self.assertFalse((self.base / "calls").exists(), "installer invoked privilege or host networking")


if __name__ == "__main__":
    if os.getuid() == 0:
        raise SystemExit("Tests must run as a non-root user")
    unittest.main(verbosity=2)
