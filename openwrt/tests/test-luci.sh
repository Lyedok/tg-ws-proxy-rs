#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LUCI="$ROOT/openwrt/luci-app"
VIEW="$LUCI/htdocs/luci-static/resources/view/tg-ws-proxy/settings.js"
MENU="$LUCI/root/usr/share/luci/menu.d/luci-app-tg-ws-proxy.json"
ACL="$LUCI/root/usr/share/rpcd/acl.d/luci-app-tg-ws-proxy.json"
UCITRACK="$LUCI/root/usr/share/ucitrack/luci-app-tg-ws-proxy.json"
MAKEFILE="$LUCI/Makefile"
CONFIG="$ROOT/openwrt/files/tg-ws-proxy.config"
BUILDER="$ROOT/openwrt/build-package.sh"
INSTALLER="$ROOT/install.sh"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

for path in "$VIEW" "$MENU" "$ACL" "$UCITRACK" "$MAKEFILE"; do
    [[ -f "$path" ]] || fail "missing ${path#"$ROOT/"}"
done

python3 -m json.tool "$MENU" >/dev/null
python3 -m json.tool "$ACL" >/dev/null
python3 -m json.tool "$UCITRACK" >/dev/null

python3 - "$MENU" "$ACL" "$UCITRACK" <<'PY'
import json, sys
menu = json.load(open(sys.argv[1]))
acl = json.load(open(sys.argv[2]))["luci-app-tg-ws-proxy"]
track = json.load(open(sys.argv[3]))
entry = menu.get("admin/services/tg-ws-proxy")
assert entry, "Services menu entry is missing"
assert entry["action"] == {"type": "view", "path": "tg-ws-proxy/settings"}
assert "luci-app-tg-ws-proxy" in entry["depends"]["acl"]
assert entry["depends"]["uci"] == {"tg-ws-proxy": True}
assert "tg-ws-proxy" in acl["read"]["uci"]
assert "tg-ws-proxy" in acl["write"]["uci"]
assert "list" in acl["read"]["ubus"]["service"]
assert "init" in acl["write"]["ubus"]["rc"]
assert track["config"] == "tg-ws-proxy"
assert track["init"] == "tg-ws-proxy"
PY

if command -v node >/dev/null 2>&1; then
    node --check "$VIEW"
fi

grep -Fq "new form.Map('tg-ws-proxy'" "$VIEW" || fail "view is not bound to tg-ws-proxy UCI"
grep -Fq "o.password = true" "$VIEW" || fail "secret is not rendered as a password"
grep -Fq "object: 'service'" "$VIEW" || fail "service status RPC is missing"
grep -Fq "object: 'rc'" "$VIEW" || fail "init action RPC is missing"
grep -Fq "'require fs';" "$VIEW" || fail "live log does not load the LuCI fs API"
grep -Fq "fs.exec_direct('/sbin/logread', ['-e', SERVICE], 'text')" "$VIEW" || fail "live log does not read the filtered OpenWrt logd buffer"
grep -Fq 'function formatLogLine(line)' "$VIEW" || fail "logd/tracing line formatter is missing"
grep -Fq "poll.add" "$VIEW" || fail "live log/status polling is missing"
grep -Fq "id: 'tg_ws_proxy_live_log'" "$VIEW" || fail "live log output element is missing"
grep -Fq "form.ListValue, 'log_level'" "$VIEW" || fail "single Rust log-level selector is missing"
grep -Fq 'function validateSecrets(sectionId, value)' "$VIEW" || fail "multi-secret validator is missing"
grep -Fq 'function validateDcIp(sectionId, value)' "$VIEW" || fail "strict DC:IP validator is missing"
grep -Fq "form.DynamicList, 'cf_worker_domain'" "$VIEW" || fail "Cloudflare Worker domains are not repeatable"
for level in off error warn info debug trace; do
    grep -Fq "o.value('$level'" "$VIEW" || fail "Rust log level $level is missing"
done
if grep -Fq "addFlag(s, 'logging', 'verbose'" "$VIEW" || grep -Fq "addFlag(s, 'logging', 'quiet'" "$VIEW"; then
    fail "legacy quiet/verbose checkboxes are still exposed"
fi
if grep -Fq 'fs.read_direct' "$VIEW" || grep -Fq 'fs.write' "$VIEW" || grep -Fq "_('Clean log')" "$VIEW"; then
    fail "dedicated-file log viewer or cleaner is still present"
fi
grep -Fq '"cgi-io": [ "exec" ]' "$ACL" || fail "direct logread CGI exec ACL is missing"
grep -Fq '"/sbin/logread -e tg-ws-proxy": [ "exec" ]' "$ACL" || fail "filtered logread exec ACL is missing"
if grep -Fq '/var/run/tg-ws-proxy/tg-ws-proxy.log' "$ACL"; then
    fail "legacy runtime log file ACL is still present"
fi
grep -Fq "option log_level 'info'" "$CONFIG" || fail "native Rust info log level is not the UCI default"
grep -Fq "list cf_worker_domain ''" "$CONFIG" || fail "Cloudflare Worker domains are not stored as a UCI list"
if grep -Eq 'option (quiet|verbose|log_file) ' "$CONFIG"; then
    fail "legacy logging options are still packaged in UCI defaults"
fi
# shellcheck disable=SC2016 # Source-contract assertion intentionally matches a literal variable.
grep -Fq 'procd_append_param env "RUST_LOG=$log_filter"' "$ROOT/openwrt/files/tg-ws-proxy.init" || fail "init does not pass the native Rust log filter"
if grep -Fq 'prepare_runtime_log' "$ROOT/openwrt/files/tg-ws-proxy.init"; then
    fail "startup-only file rotation is still present"
fi
if grep -Fq 'set_from_env TG_LOG_FILE log_file' "$INSTALLER"; then
    fail "installer can migrate the retired runtime log file back into UCI"
fi

node - "$VIEW" <<'JS'
const fs = require('fs');
const net = require('net');
const vm = require('vm');
const path = process.argv[2];
let source = fs.readFileSync(path, 'utf8');
source = source.replace('return view.extend({', [
    'globalThis.__formatLogLine = formatLogLine;',
    'globalThis.__validateSecrets = validateSecrets;',
    'globalThis.__validateDcIp = validateDcIp;',
    'return view.extend({'
].join('\n'));
const context = {
    _: (value) => value,
    L: { hasViewPermission: () => true },
    rpc: { declare: () => () => Promise.resolve({}) },
    validation: {
        types: {
            ipaddr: function(nomask) {
                return this.assert(this.apply('ip4addr', null, [nomask]) || this.apply('ip6addr', null, [nomask]));
            },
            ip4addr: function(nomask) { return this.assert((!nomask || !this.value.includes('/')) && net.isIP(this.value) === 4); },
            ip6addr: function(nomask) { return this.assert((!nomask || !this.value.includes('/')) && net.isIP(this.value) === 6); }
        }
    },
    view: { extend: (value) => value }
};
vm.createContext(context);
vm.runInContext(`(function() { ${source} })()`, context);
const own = 'Sun Aug  9 12:17:51 2026 daemon.info tg-ws-proxy[22567]: 2026-08-09T10:17:51.386442Z DEBUG tg_ws_proxy_rs::pool: WS pool warmup complete';
const dependency = 'Sun Aug  9 12:17:51 2026 daemon.info tg-ws-proxy[22567]: 2026-08-09T10:17:51.309393Z DEBUG rustls::client::hs: Using ciphersuite TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256';
if (context.__formatLogLine(own) !== 'Aug  9 12:17:51 [DEBUG] tg_ws_proxy_rs::pool — WS pool warmup complete')
    throw new Error('own log line was not normalized');
if (context.__formatLogLine(dependency) !== null)
    throw new Error('dependency debug noise was not filtered');
if (context.__validateSecrets(null, '11111111111111111111111111111111,22222222222222222222222222222222') !== true)
    throw new Error('comma-separated proxy secrets were rejected');
if (context.__validateSecrets(null, 'not-hex') === true)
    throw new Error('invalid proxy secret was accepted');
if (context.__validateDcIp(null, '2:149.154.167.220') !== true)
    throw new Error('valid DC:IPv4 was rejected');
if (context.__validateDcIp(null, '-2:149.154.167.220') === true)
    throw new Error('negative DC was accepted');
if (context.__validateDcIp(null, '2:999.154.167.220') === true)
    throw new Error('invalid IPv4 was accepted');
if (context.__validateDcIp(null, '2:149.154.167.220/24') === true)
    throw new Error('CIDR prefix was accepted where a host IP is required');
JS

for action in start stop restart; do
    grep -Fq "'$action'" "$VIEW" || fail "$action action is missing"
done

while read -r kind option _; do
    case "$kind" in option|list)
        grep -Eq "['\"]${option}['\"]" "$VIEW" || fail "UCI option $option is not exposed"
    esac
done < "$CONFIG"

grep -Fq 'LUCI_PKGARCH:=all' "$MAKEFILE" || fail "LuCI package is not noarch/all"
grep -Eq 'LUCI_DEPENDS.*luci-base' "$MAKEFILE" || fail "luci-base dependency is missing"
grep -Eq 'LUCI_DEPENDS.*tg-ws-proxy' "$MAKEFILE" || fail "tg-ws-proxy dependency is missing"

grep -Fq 'luci-app-tg-ws-proxy' "$BUILDER" || fail "builder does not produce LuCI companion package"
# shellcheck disable=SC2016 # Source-contract assertions intentionally match literal variable names.
grep -Fq 'mkdir -p "$stage/www"' "$BUILDER" || fail "builder does not map LuCI htdocs to /www"
# shellcheck disable=SC2016 # Source-contract assertions intentionally match literal variable names.
grep -Fq 'cp -a "$LUCI_DIR/htdocs/." "$stage/www/"' "$BUILDER" || fail "builder copies LuCI htdocs outside /www"
grep -Fq 'run_with_root_ownership' "$BUILDER" || fail "builder does not normalize package ownership under fakeroot"
grep -Fq -- '--owner=0 --group=0' "$BUILDER" || fail "IPK tar ownership is not normalized to root:root"
# shellcheck disable=SC2016 # Source-contract assertion intentionally matches a literal command.
grep -Fq 'chown -R 0:0 "$stage"' "$BUILDER" || fail "APK payload is not normalized to root:root"
grep -Fq 'LUCI_PACKAGE_FILE' "$INSTALLER" || fail "installer does not resolve a LuCI companion package"
grep -Fq 'install_luci_package' "$INSTALLER" || fail "installer does not install the LuCI companion package"
grep -Fq 'rm -f /etc/config/tg-ws-proxy.apk-new' "$INSTALLER" || fail "installer does not clean the inactive package-default UCI copy"

printf 'PASS: LuCI package contract\n'
