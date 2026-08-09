#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INIT="$ROOT/openwrt/files/tg-ws-proxy.init"
[[ -f "$INIT" ]] || { printf 'FAIL: missing openwrt/files/tg-ws-proxy.init\n' >&2; exit 1; }

declare -A CFG=()
declare -A LISTS=()
declare -a EVENTS=()
declare -a ENVS=()
TEST_RUNTIME="$(mktemp -d)"
export TG_WS_PROXY_RUNTIME_DIR="$TEST_RUNTIME"
trap 'rm -rf "$TEST_RUNTIME"' EXIT

config_load() { EVENTS+=("config_load:$1"); }
config_get() {
    local __out="$1" section="$2" option="$3" default="${4-}"
    local __value="${CFG[$section.$option]-$default}"
    printf -v "$__out" '%s' "$__value"
}
config_get_bool() {
    local __out="$1" section="$2" option="$3" default="${4-0}" __value
    __value="${CFG[$section.$option]-$default}"
    case "$__value" in 1|true|yes|on|enabled) __value=1;; *) __value=0;; esac
    printf -v "$__out" '%s' "$__value"
}
config_list_foreach() {
    local section="$1" option="$2" callback="$3" value
    while IFS= read -r value; do
        if [[ -n "$value" ]]; then "$callback" "$value"; fi
    done <<< "${LISTS[$section.$option]-}"
}
procd_open_instance() { EVENTS+=("open:${1-}"); }
procd_set_param() {
    local kind="$1"; shift
    EVENTS+=("set:$kind:$*")
    if [[ "$kind" == env ]]; then ENVS+=("$@"); fi
}
procd_append_param() {
    local kind="$1"; shift
    EVENTS+=("append:$kind:$*")
    if [[ "$kind" == env ]]; then ENVS+=("$@"); fi
}
procd_close_instance() { EVENTS+=("close"); }
procd_add_reload_trigger() { EVENTS+=("trigger:$1"); }
uci() {
    local key
    EVENTS+=("uci:$*")
    if [[ "${1-}" == -q && "${2-}" == get ]]; then
        key="${3#tg-ws-proxy.}"
        [[ -v "CFG[$key]" ]]
        return
    fi
}
logger() { EVENTS+=("logger:$*"); }

# shellcheck source=/dev/null
source "$INIT"

has_event() {
    local expected="$1" item
    for item in "${EVENTS[@]-}"; do [[ "$item" == "$expected" ]] && return 0; done
    return 1
}
has_env() {
    local expected="$1" item
    for item in "${ENVS[@]-}"; do [[ "$item" == "$expected" ]] && return 0; done
    return 1
}

# Disabled by default: loading config is allowed, but procd must not be opened.
CFG[main.enabled]=0
start_service
if has_event 'open:tg-ws-proxy.main'; then
    printf 'FAIL: disabled service opened a procd instance\n' >&2
    exit 1
fi

EVENTS=(); ENVS=(); CFG=(); LISTS=()
CFG[main.enabled]=1
CFG[main.host]=0.0.0.0
CFG[main.port]=3443
CFG[main.secret]=0123456789abcdef0123456789abcdef
CFG[main.link_ip]=proxy.example.test
CFG[main.listen_faketls_domain]=www.google.com
CFG[main.outbound_proxy]=socks5h://127.0.0.1:5330
CFG[main.log_level]=trace
CFG[main.cf_priority]=1
LISTS[main.dc_ip]=$'2:149.154.167.220\n4:149.154.167.220'
LISTS[main.cf_domain]=$'one.example\ntwo.example'
LISTS[main.cf_worker_domain]=$'worker-one.example\nworker-two.example'
printf 'legacy current log' > "$TEST_RUNTIME/tg-ws-proxy.log"
printf 'legacy rotated log' > "$TEST_RUNTIME/tg-ws-proxy.log.1"

start_service
has_event 'open:tg-ws-proxy.main' || { printf 'FAIL: enabled service did not open procd\n' >&2; exit 1; }
has_event 'set:command:/usr/bin/tg-ws-proxy' || { printf 'FAIL: wrong procd command\n' >&2; exit 1; }
for expected in \
    'TG_HOST=0.0.0.0' \
    'TG_PORT=3443' \
    'TG_SECRET=0123456789abcdef0123456789abcdef' \
    'TG_LINK_IP=proxy.example.test' \
    'TG_LISTEN_FAKETLS_DOMAIN=www.google.com' \
    'TG_OUTBOUND_PROXY=socks5h://127.0.0.1:5330' \
    'TG_CF_WORKER_DOMAIN=worker-one.example,worker-two.example' \
    'RUST_LOG=warn,tg_ws_proxy=trace,tg_ws_proxy_rs=trace' \
    'TG_CF_PRIORITY=true' \
    'TG_CF_DOMAIN=one.example,two.example'; do
    has_env "$expected" || { printf 'FAIL: missing env %s\n' "$expected" >&2; exit 1; }
done
[[ ! -e "$TEST_RUNTIME/tg-ws-proxy.log" && ! -e "$TEST_RUNTIME/tg-ws-proxy.log.1" ]] || {
    printf 'FAIL: legacy runtime logs were not removed\n' >&2
    exit 1
}
for legacy_env in TG_LOG_FILE TG_VERBOSE TG_QUIET; do
    for item in "${ENVS[@]}"; do
        [[ "$item" != "$legacy_env="* ]] || { printf 'FAIL: legacy env %s is still passed\n' "$legacy_env" >&2; exit 1; }
    done
done
has_event 'append:command:--dc-ip 2:149.154.167.220' || { printf 'FAIL: missing DC2 command argument\n' >&2; exit 1; }
has_event 'append:command:--dc-ip 4:149.154.167.220' || { printf 'FAIL: missing DC4 command argument\n' >&2; exit 1; }

# A scalar cf_worker_domain from an earlier local package remains accepted.
EVENTS=(); ENVS=(); CFG=(); LISTS=()
CFG[main.enabled]=1
CFG[main.secret]=0123456789abcdef0123456789abcdef
CFG[main.cf_worker_domain]=legacy-worker.example
start_service
has_env 'TG_CF_WORKER_DOMAIN=legacy-worker.example' || {
    printf 'FAIL: legacy scalar Worker domain was not preserved\n' >&2
    exit 1
}

# Existing UCI with legacy quiet/verbose options is mapped to native Rust levels.
EVENTS=(); ENVS=(); CFG=(); LISTS=()
CFG[main.enabled]=1
CFG[main.secret]=0123456789abcdef0123456789abcdef
CFG[main.verbose]=1
start_service
has_env 'RUST_LOG=warn,tg_ws_proxy=debug,tg_ws_proxy_rs=debug' || { printf 'FAIL: legacy verbose=1 did not map to app-only debug\n' >&2; exit 1; }
has_event 'uci:-q set tg-ws-proxy.main.log_level=debug' || { printf 'FAIL: debug level was not persisted\n' >&2; exit 1; }
has_event 'uci:-q delete tg-ws-proxy.main.verbose' || { printf 'FAIL: legacy verbose option was not removed\n' >&2; exit 1; }
has_event 'uci:-q commit tg-ws-proxy' || { printf 'FAIL: logging migration was not committed\n' >&2; exit 1; }

EVENTS=(); ENVS=(); CFG=(); LISTS=()
CFG[main.enabled]=1
CFG[main.secret]=0123456789abcdef0123456789abcdef
CFG[main.verbose]=1
CFG[main.quiet]=1
start_service
has_env 'RUST_LOG=off' || { printf 'FAIL: legacy quiet=1 did not take precedence as off\n' >&2; exit 1; }
has_event 'uci:-q set tg-ws-proxy.main.log_level=off' || { printf 'FAIL: off level was not persisted\n' >&2; exit 1; }
has_event 'uci:-q delete tg-ws-proxy.main.quiet' || { printf 'FAIL: legacy quiet option was not removed\n' >&2; exit 1; }

# A missing secret must become a persistent 32-hex UCI value.
EVENTS=(); ENVS=(); CFG=(); LISTS=()
CFG[main.enabled]=1
CFG[main.host]=127.0.0.1
CFG[main.port]=1443
start_service
generated=''
for item in "${ENVS[@]}"; do
    case "$item" in TG_SECRET=*) generated="${item#TG_SECRET=}";; esac
done
[[ "$generated" =~ ^[0-9a-f]{32}$ ]] || { printf 'FAIL: generated secret is not 32 lowercase hex chars\n' >&2; exit 1; }
has_event "uci:-q set tg-ws-proxy.main.secret=$generated" || { printf 'FAIL: generated secret was not written to UCI\n' >&2; exit 1; }
has_event 'uci:-q commit tg-ws-proxy' || { printf 'FAIL: generated secret was not committed\n' >&2; exit 1; }

EVENTS=()
service_triggers
has_event 'trigger:tg-ws-proxy' || { printf 'FAIL: reload trigger missing\n' >&2; exit 1; }

printf 'PASS: init/UCI mapping\n'
