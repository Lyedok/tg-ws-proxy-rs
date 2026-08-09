#!/bin/sh
# Standalone tg-ws-proxy installer for OpenWrt APK/opkg systems.
# Installs matching local artifacts or resolves CI-published GitHub Release packages.

G='\033[0;32m'; R='\033[0;31m'; Y='\033[0;33m'; C='\033[0;36m'; N='\033[0m'
ok()   { printf "${G}%s${N}\n" "$1"; }
info() { printf "${C}%s${N}\n" "$1"; }
warn() { printf "${Y}%s${N}\n" "$1"; }
die()  { printf "${R}error: %s${N}\n" "$1" >&2; exit 1; }

REPOSITORY="${TG_WS_PROXY_REPOSITORY:-valnesfjord/tg-ws-proxy-rs}"
CHANNEL="${TG_WS_PROXY_RELEASE_CHANNEL:-stable}"
PACKAGE_FILE=""
PACKAGE_URL=""
LUCI_PACKAGE_FILE=""
LUCI_PACKAGE_URL=""
CHECKSUMS_FILE=""
PACKAGE_ISA=""
DRY_RUN=0
ARCH_OVERRIDE=""
PM_OVERRIDE=""
PM=""
EXT=""
ARCH=""
TMP_DIR=""
BACKUP_DIR=""
OLD_CONFIG=0
OLD_PACKAGE=0
OLD_LUCI_PACKAGE=0
OLD_RUNNING=0
OLD_ENABLED=0

usage() {
	cat <<'EOF'
Usage: sh install.sh [options]

Options:
  --package PATH              Install a locally built .apk or .ipk
  --luci-package PATH         Install the matching local LuCI companion package
  --dry-run                   Resolve package manager/architecture only
  --channel stable|beta       Select latest stable (default) or beta release
  --arch ARCH                 Override detected package architecture
  --package-manager apk|opkg  Override package manager (primarily for tests)
  -h, --help                  Show this help

Without --package, the installer downloads the matching CPU-ISA package and the
architecture-independent LuCI package directly from GitHub Releases.
Set GH_MIRROR=https://mirror.example to retry GitHub downloads through a mirror.
TG_WS_PROXY_RELEASE_CHANNEL may also select stable or beta. Both apk (OpenWrt
25.12+) and opkg/IPK are supported.
EOF
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--package) [ "$#" -ge 2 ] || die "--package requires a path"; PACKAGE_FILE="$2"; shift 2 ;;
		--luci-package) [ "$#" -ge 2 ] || die "--luci-package requires a path"; LUCI_PACKAGE_FILE="$2"; shift 2 ;;
		--dry-run) DRY_RUN=1; shift ;;
		--channel) [ "$#" -ge 2 ] || die "--channel requires stable or beta"; CHANNEL="$2"; shift 2 ;;
		--arch) [ "$#" -ge 2 ] || die "--arch requires a value"; ARCH_OVERRIDE="$2"; shift 2 ;;
		--package-manager) [ "$#" -ge 2 ] || die "--package-manager requires a value"; PM_OVERRIDE="$2"; shift 2 ;;
		-h|--help) usage; exit 0 ;;
		*) die "unknown argument: $1" ;;
	esac
done

case "$CHANNEL" in stable|beta) ;; *) die "unsupported release channel: $CHANNEL";; esac

cleanup() {
	[ -n "$TMP_DIR" ] && rm -rf "$TMP_DIR"
}
if [ "${TG_WS_PROXY_TEST_MODE:-0}" != 1 ]; then
	trap cleanup EXIT INT TERM
fi

load_openwrt_release() {
	[ -r /etc/openwrt_release ] || return 1
	# shellcheck disable=SC1091
	. /etc/openwrt_release 2>/dev/null
	return 0
}

resolve_environment() {
	if [ -n "$PM_OVERRIDE" ]; then
		PM="$PM_OVERRIDE"
	elif command -v apk >/dev/null 2>&1; then
		PM=apk
	elif command -v opkg >/dev/null 2>&1; then
		PM=opkg
	else
		die "supported package manager not found (apk/opkg)"
	fi
	case "$PM" in apk) EXT=apk;; opkg) EXT=ipk;; *) die "unsupported package manager: $PM";; esac

	if [ -n "$ARCH_OVERRIDE" ]; then
		ARCH="$ARCH_OVERRIDE"
	elif load_openwrt_release && [ -n "${DISTRIB_ARCH:-}" ]; then
		ARCH="$DISTRIB_ARCH"
	elif [ "$PM" = apk ]; then
		ARCH="$(apk --print-arch 2>/dev/null || apk print-arch 2>/dev/null)"
	else
		die "cannot read package architecture from /etc/openwrt_release"
	fi
	[ -n "$ARCH" ] || die "cannot determine package architecture"
}

dl() {
	url="$1"
	out="$2"
	wget -qO "$out" --timeout=30 "$url" 2>/dev/null && [ -s "$out" ] && return 0
	if [ -n "${GH_MIRROR:-}" ]; then
		mirror_url="$(printf '%s' "$url" | sed "s#https://github.com#${GH_MIRROR}#")"
		wget -qO "$out" --timeout=30 "$mirror_url" 2>/dev/null && [ -s "$out" ] && return 0
	fi
	return 1
}

release_asset_urls() {
	json_file="$1"
	if command -v jsonfilter >/dev/null 2>&1; then
		jsonfilter -i "$json_file" -e '@.assets[*].browser_download_url'
	else
		# GitHub may compact the whole response onto one line. Split JSON fields
		# before sed so a greedy match cannot retain only the final asset URL.
		tr ',' '\n' < "$json_file" | \
			sed -n 's/.*"browser_download_url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
	fi
}

find_release_asset() {
	json_file="$1"
	prefix="$2"
	suffix="$3"
	release_asset_urls "$json_file" | while IFS= read -r url; do
		name="${url##*/}"
		if [ -z "$suffix" ]; then
			[ "$name" = "$prefix" ] && { printf '%s\n' "$url"; break; }
		else
			case "$name" in
				"$prefix"*"$suffix") printf '%s\n' "$url"; break ;;
			esac
		fi
	done
}

release_tags() {
	json_file="$1"
	if command -v jsonfilter >/dev/null 2>&1; then
		jsonfilter -i "$json_file" -e '@[*].tag_name'
	else
		tr '{' '\n' < "$json_file" | \
			sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
	fi
}

latest_beta_tag() {
	release_tags "$1" | while IFS= read -r tag; do
		case "$tag" in
			v*-beta.[1-9]* ) printf '%s\n' "$tag"; break ;;
		esac
	done
}

package_isa() {
	case "$1" in
		aarch64|aarch64_*) printf '%s' aarch64 ;;
		armv7|arm_cortex-a5_vfpv4|arm_cortex-a7_vfpv4|arm_cortex-a7_neon-vfpv4|\
		arm_cortex-a8_vfpv3|arm_cortex-a9_vfpv3-d16|arm_cortex-a9_neon|\
		arm_cortex-a15_neon-vfpv4) printf '%s' armv7 ;;
		mipsel|mipsel_24kc|mipsel_74kc) printf '%s' mipsel ;;
		mips|mips_24kc) printf '%s' mips ;;
		x86_64) printf '%s' x86_64 ;;
		*) return 1 ;;
	esac
}

resolve_remote_package() {
	TMP_DIR="$(mktemp -d /tmp/tg-ws-proxy-install.XXXXXX)" || die "cannot create temporary directory"
	api_file="$TMP_DIR/release.json"
	if [ "$CHANNEL" = beta ]; then
		releases_file="$TMP_DIR/releases.json"
		wget -qO "$releases_file" --timeout=30 \
			"https://api.github.com/repos/$REPOSITORY/releases?per_page=100" 2>/dev/null || \
			die "cannot query GitHub beta releases"
		release_tag="$(latest_beta_tag "$releases_file")"
		[ -n "$release_tag" ] || die "no beta release found"
		api_url="https://api.github.com/repos/$REPOSITORY/releases/tags/$release_tag"
	else
		api_url="https://api.github.com/repos/$REPOSITORY/releases/latest"
	fi
	wget -qO "$api_file" --timeout=30 "$api_url" 2>/dev/null || die "cannot query GitHub release API"
	PACKAGE_ISA="$(package_isa "$ARCH")" || die "unsupported package architecture: $ARCH"
	PACKAGE_URL="$(find_release_asset "$api_file" 'tg-ws-proxy_' "_${PACKAGE_ISA}.${EXT}")"
	[ -n "$PACKAGE_URL" ] || die "no ${EXT} package found for CPU ISA $PACKAGE_ISA"

	luci_arch=all
	[ "$PM" = apk ] && luci_arch=noarch
	LUCI_PACKAGE_URL="$(find_release_asset "$api_file" 'luci-app-tg-ws-proxy_' "_${luci_arch}.${EXT}")"
	[ -n "$LUCI_PACKAGE_URL" ] || die "no LuCI ${EXT} package found"

	checksums_url="$(find_release_asset "$api_file" SHA256SUMS '')"
	[ -n "$checksums_url" ] || die "release SHA256SUMS asset is missing"
	PACKAGE_FILE="$TMP_DIR/${PACKAGE_URL##*/}"
	LUCI_PACKAGE_FILE="$TMP_DIR/${LUCI_PACKAGE_URL##*/}"
	CHECKSUMS_FILE="$TMP_DIR/SHA256SUMS"
	dl "$PACKAGE_URL" "$PACKAGE_FILE" || die "cannot download package (set GH_MIRROR if GitHub is blocked)"
	dl "$LUCI_PACKAGE_URL" "$LUCI_PACKAGE_FILE" || die "cannot download LuCI package"
	dl "$checksums_url" "$CHECKSUMS_FILE" || die "cannot download SHA256SUMS"
}

resolve_luci_package() {
	[ -n "$LUCI_PACKAGE_FILE" ] && return 0
	luci_arch=all
	[ "$PM" = apk ] && luci_arch=noarch
	case "$PACKAGE_FILE" in */*) package_dir="${PACKAGE_FILE%/*}";; *) package_dir=.;; esac
	core_name="${PACKAGE_FILE##*/}"
	core_stem="${core_name#tg-ws-proxy_}"
	core_stem="${core_stem%."${EXT}"}"
	core_version="${core_stem%_*}"
	[ "$core_version" != "$core_stem" ] || die "cannot derive LuCI package version; use --luci-package"
	LUCI_PACKAGE_FILE="$package_dir/luci-app-tg-ws-proxy_${core_version}_${luci_arch}.${EXT}"
}

resolve_local_checksums() {
	[ -z "$CHECKSUMS_FILE" ] || return 0
	case "$PACKAGE_FILE" in */*) package_dir="${PACKAGE_FILE%/*}";; *) package_dir=.;; esac
	[ -f "$package_dir/SHA256SUMS" ] && CHECKSUMS_FILE="$package_dir/SHA256SUMS"
	return 0
}

verify_release_checksum() {
	file="$1"
	label="$2"
	name="${file##*/}"
	expected="$(while read -r sum listed; do
		listed="${listed#\*}"
		if [ "$listed" = "$name" ]; then printf '%s' "$sum"; break; fi
	done < "$CHECKSUMS_FILE")"
	[ -n "$expected" ] || die "$label is missing from release SHA256SUMS: $name"
	actual="$(sha256sum "$file" | sed 's/[[:space:]].*//')"
	[ "$expected" = "$actual" ] || die "$label SHA-256 mismatch"
}

verify_checksum() {
	checksum_file=""
	if [ -n "$CHECKSUMS_FILE" ]; then
		verify_release_checksum "$PACKAGE_FILE" package
		ok "SHA-256 verified."
		return 0
	elif [ -n "$PACKAGE_URL" ]; then
		checksum_file="$TMP_DIR/package.sha256"
		dl "$PACKAGE_URL.sha256" "$checksum_file" || checksum_file=""
	elif [ -f "$PACKAGE_FILE.sha256" ]; then
		checksum_file="$PACKAGE_FILE.sha256"
	fi
	if [ -z "$checksum_file" ]; then
		warn "No SHA-256 sidecar found; package signature/tool verification will be used."
		return 0
	fi
	expected="$(sed -n '1{s/[[:space:]].*//;p;}' "$checksum_file")"
	actual="$(sha256sum "$PACKAGE_FILE" | sed 's/[[:space:]].*//')"
	if [ -z "$expected" ] || [ "$expected" != "$actual" ]; then
		die "package SHA-256 mismatch"
	fi
	ok "SHA-256 verified."
}

verify_luci_checksum() {
	luci_checksum_file=""
	if [ -n "$CHECKSUMS_FILE" ]; then
		verify_release_checksum "$LUCI_PACKAGE_FILE" "LuCI package"
		ok "LuCI SHA-256 verified."
		return 0
	elif [ -n "$LUCI_PACKAGE_URL" ]; then
		luci_checksum_file="$TMP_DIR/luci-package.sha256"
		dl "$LUCI_PACKAGE_URL.sha256" "$luci_checksum_file" || luci_checksum_file=""
	elif [ -f "$LUCI_PACKAGE_FILE.sha256" ]; then
		luci_checksum_file="$LUCI_PACKAGE_FILE.sha256"
	fi
	if [ -z "$luci_checksum_file" ]; then
		warn "No LuCI SHA-256 sidecar found; package signature/tool verification will be used."
		return 0
	fi
	luci_expected="$(sed -n '1{s/[[:space:]].*//;p;}' "$luci_checksum_file")"
	luci_actual="$(sha256sum "$LUCI_PACKAGE_FILE" | sed 's/[[:space:]].*//')"
	if [ -z "$luci_expected" ] || [ "$luci_expected" != "$luci_actual" ]; then
		die "LuCI package SHA-256 mismatch"
	fi
	ok "LuCI SHA-256 verified."
}

backup_path() {
	path="$1"
	[ -e "$path" ] || return 0
	mkdir -p "$BACKUP_DIR$(dirname "$path")"
	cp -p "$path" "$BACKUP_DIR$path"
}

read_old_env() {
	name="$1"
	[ -f "$BACKUP_DIR/process.env" ] || return 0
	sed -n "s/^${name}=//p" "$BACKUP_DIR/process.env" | sed -n '1p'
}

set_from_env() {
	env_name="$1"
	option="$2"
	value="$(read_old_env "$env_name")"
	[ -n "$value" ] && uci -q set "tg-ws-proxy.main.$option=$value"
	return 0
}

set_list_from_env() {
	env_name="$1"
	option="$2"
	value="$(read_old_env "$env_name")"
	[ -n "$value" ] || return 0
	uci -q delete "tg-ws-proxy.main.$option"
	old_ifs="$IFS"; IFS=','
	for item in $value; do [ -n "$item" ] && uci -q add_list "tg-ws-proxy.main.$option=$item"; done
	IFS="$old_ifs"
}

migrate_log_level() {
	value="$(read_old_env RUST_LOG)"
	case "$value" in
		off|error|warn|info|debug|trace)
			uci -q set "tg-ws-proxy.main.log_level=$value"
			return 0
		;;
	esac

	quiet="$(read_old_env TG_QUIET)"
	verbose="$(read_old_env TG_VERBOSE)"
	case "$quiet" in
		1|true|yes|on) value=off ;;
		*) case "$verbose" in 1|true|yes|on) value=debug ;; *) value=info ;; esac ;;
	esac
	uci -q set "tg-ws-proxy.main.log_level=$value"
}

migrate_command_args() {
	[ -f "$BACKUP_DIR/process.cmd" ] || return 0
	pending=""
	dc_reset=0
	cf_worker_reset=0
	while IFS= read -r arg; do
		if [ -n "$pending" ]; then
			case "$pending" in
				cf_worker_domain)
					if [ "$cf_worker_reset" -eq 0 ]; then uci -q delete tg-ws-proxy.main.cf_worker_domain; cf_worker_reset=1; fi
					uci -q add_list "tg-ws-proxy.main.cf_worker_domain=$arg"
				;;
				dc_ip)
					if [ "$dc_reset" -eq 0 ]; then uci -q delete tg-ws-proxy.main.dc_ip; dc_reset=1; fi
					uci -q add_list "tg-ws-proxy.main.dc_ip=$arg"
				;;
			esac
			pending=""
			continue
		fi
		case "$arg" in
			--cf-worker-domain|--cfproxy-worker-domain) pending=cf_worker_domain ;;
			--dc-ip) pending=dc_ip ;;
		esac
	done < "$BACKUP_DIR/process.cmd"
}

migrate_manual_config() {
	uci -q get tg-ws-proxy.main >/dev/null 2>&1 || uci -q set tg-ws-proxy.main=tg-ws-proxy
	uci -q set tg-ws-proxy.main.enabled=1
	[ "$OLD_CONFIG" -eq 0 ] || { uci -q commit tg-ws-proxy; return 0; }

	set_from_env TG_HOST host
	set_from_env TG_PORT port
	set_from_env TG_SECRET secret
	set_from_env TG_LINK_IP link_ip
	set_from_env TG_LISTEN_FAKETLS_DOMAIN listen_faketls_domain
	set_from_env TG_BUF_KB buf_kb
	set_from_env TG_POOL_SIZE pool_size
	set_from_env TG_MAX_CONNECTIONS max_connections
	set_list_from_env TG_CF_WORKER_DOMAIN cf_worker_domain
	set_from_env TG_WS_CONNECT_TIMEOUT ws_connect_timeout
	set_from_env TG_WS_FAIL_PROBE_TIMEOUT ws_fail_probe_timeout
	set_from_env TG_WS_FAIL_COOLDOWN ws_fail_cooldown
	set_from_env TG_WS_REDIRECT_COOLDOWN ws_redirect_cooldown
	set_from_env TG_IP_FAIL_COOLDOWN ip_fail_cooldown
	set_from_env TG_HANDSHAKE_TIMEOUT handshake_timeout
	set_from_env TG_TCP_FALLBACK_TIMEOUT tcp_fallback_timeout
	set_from_env TG_UPSTREAM_CONNECT_TIMEOUT upstream_connect_timeout
	set_from_env TG_UPSTREAM_FAIL_COOLDOWN upstream_fail_cooldown
	set_from_env TG_CF_CONNECT_TIMEOUT cf_connect_timeout
	set_from_env TG_CF_FAIL_COOLDOWN cf_fail_cooldown
	set_from_env TG_FRONTING_DOMAIN fronting_domain
	set_from_env TG_FRONTING_COOLDOWN fronting_cooldown
	set_from_env TG_FRONTING_FAIL_COOLDOWN fronting_fail_cooldown
	set_from_env TG_POOL_MAX_AGE pool_max_age
	set_from_env TG_OUTBOUND_PROXY outbound_proxy
	set_from_env TG_NO_PROXY no_proxy
	set_from_env TG_SKIP_TLS_VERIFY danger_accept_invalid_certs
	set_from_env TG_CF_PRIORITY cf_priority
	set_from_env TG_CF_BALANCE cf_balance
	set_from_env TG_DEFAULT_DOMAINS default_domains
	set_from_env TG_NO_OUTBOUND_PROXY no_outbound_proxy
	set_list_from_env TG_MTPROTO_PROXY mtproto_proxy
	set_list_from_env TG_CF_DOMAIN cf_domain

	migrate_log_level
	migrate_command_args
	uci -q commit tg-ws-proxy
}

service_control() {
	/etc/init.d/tg-ws-proxy "$1"
}

remove_core_package() {
	if [ "$PM" = apk ]; then
		apk del tg-ws-proxy >/dev/null 2>&1 || true
	else
		opkg remove tg-ws-proxy >/dev/null 2>&1 || true
	fi
}

remove_luci_package() {
	if [ "$PM" = apk ]; then
		apk del luci-app-tg-ws-proxy >/dev/null 2>&1 || true
	else
		opkg remove luci-app-tg-ws-proxy >/dev/null 2>&1 || true
	fi
}

restore_backup_path() {
	path="$1"
	rm -f "$path"
	if [ -e "$BACKUP_DIR$path" ]; then
		mkdir -p "$(dirname "$path")"
		cp -p "$BACKUP_DIR$path" "$path"
	fi
}

restore_core_backup_files() {
	for path in \
		/usr/bin/tg-ws-proxy \
		/usr/bin/tg-ws-proxy-rs \
		/etc/init.d/tg-ws-proxy
	do
		restore_backup_path "$path"
	done
}

restore_luci_backup_files() {
	for path in \
		/usr/share/luci/menu.d/luci-app-tg-ws-proxy.json \
		/usr/share/rpcd/acl.d/luci-app-tg-ws-proxy.json \
		/usr/share/ucitrack/luci-app-tg-ws-proxy.json \
		/www/luci-static/resources/view/tg-ws-proxy/settings.js
	do
		restore_backup_path "$path"
	done
}

restore_config_backup() {
	if [ "$OLD_CONFIG" -eq 1 ] && [ -e "$BACKUP_DIR/etc/config/tg-ws-proxy" ]; then
		restore_backup_path /etc/config/tg-ws-proxy
	elif [ "$OLD_PACKAGE" -eq 0 ]; then
		rm -f /etc/config/tg-ws-proxy /etc/config/tg-ws-proxy.apk-new
	fi
}

restore_service_state() {
	[ -x /etc/init.d/tg-ws-proxy ] || return 0
	if [ "$OLD_ENABLED" -eq 1 ]; then
		service_control enable >/dev/null 2>&1 || true
	else
		service_control disable >/dev/null 2>&1 || true
	fi
	if [ "$OLD_RUNNING" -eq 1 ]; then
		service_control start >/dev/null 2>&1 || true
	else
		service_control stop >/dev/null 2>&1 || true
	fi
}

rollback() {
	warn "Installation failed; restoring the previous configuration and service state."
	service_control stop >/dev/null 2>&1 || true

	# A fresh/manual migration can be returned to its original files after the
	# newly introduced packages are removed. During an existing package upgrade,
	# never copy old package-owned files over the new package database: keep the
	# package transaction internally consistent and restore only UCI/service state.
	if [ "$OLD_LUCI_PACKAGE" -eq 0 ]; then
		remove_luci_package
		restore_luci_backup_files
	fi
	if [ "$OLD_PACKAGE" -eq 0 ]; then
		remove_core_package
		restore_core_backup_files
	fi
	restore_config_backup
	restore_service_state

	if [ "$OLD_PACKAGE" -eq 1 ] || [ "$OLD_LUCI_PACKAGE" -eq 1 ]; then
		warn "Package upgrades remain at the package-manager version; reinstall previous APK/IPK artifacts for a full downgrade."
	fi
	warn "Recovery files are retained in $BACKUP_DIR"
}

core_package_arch() {
	if [ "$PM" = apk ]; then
		apk adbdump "$PACKAGE_FILE" 2>/dev/null | sed -n 's/^  arch: //p' | sed -n '1p'
	else
		tar -xOzf "$PACKAGE_FILE" ./control.tar.gz 2>/dev/null | \
			tar -xzOf - ./control 2>/dev/null | \
			sed -n 's/^Architecture: //p' | sed -n '1p'
	fi
}

validate_core_package_arch() {
	[ -n "$PACKAGE_ISA" ] || PACKAGE_ISA="$(package_isa "$ARCH")" || \
		die "unsupported package architecture: $ARCH"
	metadata_arch="$(core_package_arch)"
	[ -n "$metadata_arch" ] || die "cannot read core package architecture"
	case "$metadata_arch" in
		"$PACKAGE_ISA"|"$ARCH") ;;
		*) die "package architecture $metadata_arch is incompatible with $ARCH ($PACKAGE_ISA)" ;;
	esac
}

install_package() {
	if [ "$PM" = apk ]; then
		apk --force-non-repository add "$PACKAGE_FILE" >/dev/null 2>&1 || \
			apk --force-non-repository --allow-untrusted add "$PACKAGE_FILE"
	else
		opkg --force-architecture install "$PACKAGE_FILE"
	fi
}

install_luci_package() {
	if [ "$PM" = apk ]; then
		apk --force-non-repository add "$LUCI_PACKAGE_FILE" >/dev/null 2>&1 || \
			apk --force-non-repository --allow-untrusted add "$LUCI_PACKAGE_FILE"
	else
		opkg install "$LUCI_PACKAGE_FILE"
	fi
}

verify_luci_files() {
	[ -s /usr/share/luci/menu.d/luci-app-tg-ws-proxy.json ] && \
	[ -s /usr/share/rpcd/acl.d/luci-app-tg-ws-proxy.json ] && \
	[ -s /www/luci-static/resources/view/tg-ws-proxy/settings.js ]
}

listener_ready() {
	port="$1"
	netstat -lnt 2>/dev/null | (
		while IFS= read -r line; do
			case "$line" in *":$port "*) exit 0;; esac
		done
		exit 1
	)
}

wait_ready() {
	port="$(uci -q get tg-ws-proxy.main.port)"
	[ -n "$port" ] || port=1443
	i=0
	while [ "$i" -lt 15 ]; do
		if /etc/init.d/tg-ws-proxy status >/dev/null 2>&1 && listener_ready "$port"; then
			return 0
		fi
		i=$((i + 1))
		sleep 1
	done
	return 1
}

main() {
resolve_environment
if [ -z "$PACKAGE_FILE" ]; then resolve_remote_package; fi
resolve_luci_package
resolve_local_checksums

if [ "$DRY_RUN" -eq 1 ]; then
	printf 'package_manager=%s\narchitecture=%s\npackage=%s\nluci_package=%s\n' \
		"$PM" "$ARCH" "$PACKAGE_FILE" "$LUCI_PACKAGE_FILE"
	exit 0
fi

[ "$(id -u)" = 0 ] || die "run as root"
load_openwrt_release || die "this is not OpenWrt"
if [ ! -f "$PACKAGE_FILE" ] || [ ! -s "$PACKAGE_FILE" ]; then
	die "package is missing or empty: $PACKAGE_FILE"
fi
case "$PACKAGE_FILE" in *.$EXT) ;; *) die "package extension does not match $PM: expected .$EXT";; esac
if [ ! -f "$LUCI_PACKAGE_FILE" ] || [ ! -s "$LUCI_PACKAGE_FILE" ]; then
	die "LuCI package is missing or empty: $LUCI_PACKAGE_FILE"
fi
case "$LUCI_PACKAGE_FILE" in *.$EXT) ;; *) die "LuCI package extension does not match $PM: expected .$EXT";; esac
verify_checksum
verify_luci_checksum
validate_core_package_arch

stamp="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="/root/tg-ws-proxy-backups/package-$stamp"
mkdir -p "$BACKUP_DIR"
chmod 0700 /root/tg-ws-proxy-backups "$BACKUP_DIR"

[ -e /etc/config/tg-ws-proxy ] && OLD_CONFIG=1
if [ "$PM" = apk ]; then apk info -e tg-ws-proxy >/dev/null 2>&1 && OLD_PACKAGE=1; else opkg status tg-ws-proxy 2>/dev/null | grep -q 'Status:.*installed' && OLD_PACKAGE=1; fi
if [ "$PM" = apk ]; then apk info -e luci-app-tg-ws-proxy >/dev/null 2>&1 && OLD_LUCI_PACKAGE=1; else opkg status luci-app-tg-ws-proxy 2>/dev/null | grep -q 'Status:.*installed' && OLD_LUCI_PACKAGE=1; fi
/etc/init.d/tg-ws-proxy status >/dev/null 2>&1 && OLD_RUNNING=1
/etc/init.d/tg-ws-proxy enabled >/dev/null 2>&1 && OLD_ENABLED=1

for path in \
	/usr/bin/tg-ws-proxy \
	/usr/bin/tg-ws-proxy-rs \
	/etc/init.d/tg-ws-proxy \
	/etc/config/tg-ws-proxy \
	/usr/share/luci/menu.d/luci-app-tg-ws-proxy.json \
	/usr/share/rpcd/acl.d/luci-app-tg-ws-proxy.json \
	/usr/share/ucitrack/luci-app-tg-ws-proxy.json \
	/www/luci-static/resources/view/tg-ws-proxy/settings.js
do
	backup_path "$path"
done
pid="$(pidof tg-ws-proxy 2>/dev/null || pidof tg-ws-proxy-rs 2>/dev/null || true)"
if [ -n "$pid" ]; then
	pid="${pid%% *}"
	tr '\0' '\n' < "/proc/$pid/environ" > "$BACKUP_DIR/process.env"
	tr '\0' '\n' < "/proc/$pid/cmdline" > "$BACKUP_DIR/process.cmd"
	chmod 0600 "$BACKUP_DIR/process.env" "$BACKUP_DIR/process.cmd"
fi

info "Backup: $BACKUP_DIR"
/etc/init.d/tg-ws-proxy stop >/dev/null 2>&1 || true
if [ "$OLD_PACKAGE" -eq 0 ]; then
	# /etc is protected by apk. Without removing the backed-up manual init,
	# apk installs the packaged procd script as .apk-new and restarts legacy code.
	rm -f /etc/init.d/tg-ws-proxy /etc/init.d/tg-ws-proxy.apk-new
fi
if ! install_package; then rollback; die "package manager failed"; fi
# Preserve the active UCI config and discard the package-default copy produced on upgrades.
rm -f /etc/config/tg-ws-proxy.apk-new
if ! migrate_manual_config; then rollback; die "UCI migration failed"; fi
/etc/init.d/tg-ws-proxy enable >/dev/null 2>&1 || { rollback; die "cannot enable service"; }
/etc/init.d/tg-ws-proxy restart >/dev/null 2>&1 || { rollback; die "cannot restart service"; }
if ! wait_ready; then rollback; die "service did not become ready"; fi

new_pid="$(pidof tg-ws-proxy 2>/dev/null || true)"
[ -n "$new_pid" ] || { rollback; die "new process is missing"; }
new_pid="${new_pid%% *}"
new_exe="$(readlink "/proc/$new_pid/exe" 2>/dev/null || true)"
[ "$new_exe" = /usr/bin/tg-ws-proxy ] || { rollback; die "unexpected running executable: $new_exe"; }

if ! install_luci_package; then rollback; die "LuCI package manager failed"; fi
rm -f /tmp/luci-indexcache
rm -rf /tmp/luci-modulecache
/etc/init.d/rpcd reload >/dev/null 2>&1 || { rollback; die "cannot reload rpcd"; }
if ! verify_luci_files; then rollback; die "LuCI package files are missing"; fi

# The package owns /usr/bin/tg-ws-proxy. Keep the legacy binary only in rollback backup.
rm -f /usr/bin/tg-ws-proxy-rs

ok "tg-ws-proxy installed and running."
ok "LuCI page installed under Services → Telegram WS Proxy."
info "Package manager: $PM | architecture: $ARCH | PID: $new_pid"
info "Rollback backup: $BACKUP_DIR"
}

if [ "${TG_WS_PROXY_TEST_MODE:-0}" != 1 ]; then
	main
fi
