#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LUCI="$ROOT/openwrt/luci-app"
VIEW="$LUCI/htdocs/luci-static/resources/view/tg-ws-proxy/settings.js"
MENU="$LUCI/root/usr/share/luci/menu.d/luci-app-tg-ws-proxy.json"
ACL="$LUCI/root/usr/share/rpcd/acl.d/luci-app-tg-ws-proxy.json"
UCITRACK="$LUCI/root/usr/share/ucitrack/luci-app-tg-ws-proxy.json"
CONFIG="$LUCI/root/etc/config/tg-ws-proxy"
INIT="$LUCI/root/etc/init.d/tg-ws-proxy"
MAKEFILE="$LUCI/Makefile"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
for path in "$VIEW" "$MENU" "$ACL" "$UCITRACK" "$CONFIG" "$INIT" "$MAKEFILE"; do
    [[ -f "$path" ]] || fail "missing ${path#"$ROOT/"}"
done

node --check "$VIEW"
python3 - "$MENU" "$ACL" "$UCITRACK" <<'PY'
import json, sys
menu = json.load(open(sys.argv[1]))
acl = json.load(open(sys.argv[2]))["luci-app-tg-ws-proxy"]
track = json.load(open(sys.argv[3]))
entry = menu["admin/services/tg-ws-proxy"]
assert entry["action"] == {"type": "view", "path": "tg-ws-proxy/settings"}
assert entry["depends"]["uci"] == {"tg-ws-proxy": True}
assert "luci-app-tg-ws-proxy" in entry["depends"]["acl"]
assert "tg-ws-proxy" in acl["read"]["uci"]
assert "tg-ws-proxy" in acl["write"]["uci"]
assert "list" in acl["read"]["ubus"]["service"]
assert "rc" not in acl["write"].get("ubus", {})
service_commands = acl["write"]["file"]
assert set(service_commands) == {
    "/etc/init.d/tg-ws-proxy start",
    "/etc/init.d/tg-ws-proxy restart",
    "/etc/init.d/tg-ws-proxy stop",
}
assert all(actions == ["exec"] for actions in service_commands.values())
assert track == {"config": "tg-ws-proxy", "init": "tg-ws-proxy"}
PY

grep -Fq "new form.Map('tg-ws-proxy'" "$VIEW" || fail 'view is not bound to UCI'
grep -Fq "o.password = true" "$VIEW" || fail 'secret is not a password field'
grep -Fq "form.ListValue, 'log_level'" "$VIEW" || fail 'log-level selector is missing'
grep -Fq "fs.exec_direct('/sbin/logread', ['-e', SERVICE], 'text')" "$VIEW" || fail 'filtered live log is missing'
grep -Fq "node.textContent = visible || _('Log is empty.')" "$VIEW" || fail 'log output is not rendered as text'
grep -Fq "node.textContent = _('Log is not available yet: %s').format(error.message)" "$VIEW" || fail 'log errors are not rendered as text'
if grep -Fq 'dom.content(node, visible' "$VIEW"; then fail 'untrusted log output still reaches dom.content'; fi
grep -Fq 'statusPollRegistered' "$VIEW" || fail 'service status poller is not guarded against duplicate registration'
grep -Fq "fs.exec('/etc/init.d/tg-ws-proxy', [action])" "$VIEW" || fail 'service controls do not use the scoped init script'
grep -Fq "form.DynamicList, 'cf_worker_domain'" "$VIEW" || fail 'Worker domains are not repeatable'
for action in start stop restart; do
    grep -Fq "'$action'" "$VIEW" || fail "$action action is missing"
done

while read -r kind option _; do
    case "$kind" in option|list)
        grep -Eq "['\"]${option}['\"]" "$VIEW" || fail "UCI option $option is not exposed"
        grep -Eq "(^|[[:space:]])${option}([[:space:]]|$)" "$INIT" || fail "UCI option $option is not mapped by init"
    esac
done < "$CONFIG"

grep -Eq '^[[:space:]]*PKGARCH:=all$' "$MAKEFILE" || fail 'package is not architecture-independent'
grep -Fq 'DEPENDS:=+luci-base' "$MAKEFILE" || fail 'luci-base dependency is missing'
if grep -Fq '+tg-ws-proxy' "$MAKEFILE"; then fail 'architecture-independent LuCI package must not depend on a core package'; fi

printf 'PASS: LuCI contract\n'
