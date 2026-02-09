#!/usr/bin/env bash

set -euo pipefail

# Automatic pulling of spam lists to block IP's
# Copyright (C) 2013 David @cowgill
# Copyright (C) 2014 Vincent Koc @koconder
# Copyright (C) 2014 Volkan @volkan-k
# Copyright (C) 2016 Anasxrt @Anasxrt

# based off the following two scripts
# http://www.theunsupported.com/2012/07/block-malicious-ip-addresses/
# http://www.cyberciti.biz/tips/block-spamming-scanning-with-iptables.html

# Runtime defaults
QUIET=0
LOG_FILE="/var/log/autosecure.log"
TMP_DIR="/tmp/autosecure"
STATE_DIR="/var/lib/autosecure"
CACHE_FILE="${STATE_DIR}/blocked_ips.txt"
DOWNLOADER=""
IPTABLES_BIN=""
IP6TABLES_BIN=""
XTABLES_WAIT="${XTABLES_WAIT:-5}"
RULE_POSITION="${RULE_POSITION:-append}"
IPV6_ENABLE="${IPV6_ENABLE:-0}"

# Outbound (egress) filtering is optional.
EGF="${EGF:-1}"

# iptables custom chain for Bad IPs
CHAIN="Autosecure"
# iptables custom chain for actions
CHAINACT="AutosecureAct"

# logger from @phracker
_log() {
    if [ "$QUIET" -eq 0 ]; then
        printf "%s: %s\n" "$(date "+%Y-%m-%d %H:%M:%S.%N")" "$*" | tee -a "$LOG_FILE"
    fi
}

_die() {
    _log "ERROR: $*"
    exit 1
}

_require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        _die "Required command not found: $1"
    fi
}

_select_downloader() {
    if command -v wget >/dev/null 2>&1; then
        DOWNLOADER="wget"
    elif command -v curl >/dev/null 2>&1; then
        DOWNLOADER="curl"
    else
        _die "Required downloader not found: install wget or curl."
    fi
}

_download_file() {
    local url="$1"
    local output="$2"

    if [ "$DOWNLOADER" = "wget" ]; then
        wget -q -O "$output" "$url"
    else
        curl -fsSL "$url" -o "$output"
    fi
}

_parse_dshield_file() {
    local file="$1"
    awk '/^[0-9]/ { print $1 "/" $3 }' "$file" | sort -u
}

_parse_static_blocklist_file() {
    local file="$1"
    grep -E -v '^(;|#|$)' "$file" | awk '{ print $1 }' | sort -u
}

_is_valid_ip_or_cidr() {
    local ip="$1"
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/([0-9]|[1-2][0-9]|3[0-2]))?$ ]]; then
        return 0
    fi

    if [[ "$ip" =~ ^[0-9A-Fa-f:]+(/([0-9]|[1-9][0-9]|1[01][0-9]|12[0-8]))?$ ]]; then
        return 0
    fi

    return 1
}

_ip_matches_family() {
    local family="$1"
    local ip="$2"

    if [ "$family" = "v4" ]; then
        [[ "$ip" != *:* ]]
    else
        [[ "$ip" == *:* ]]
    fi
}

_fw_cmd() {
    local family="$1"
    shift

    if [ "$family" = "v4" ]; then
        "$IPTABLES_BIN" -w "$XTABLES_WAIT" "$@"
    else
        "$IP6TABLES_BIN" -w "$XTABLES_WAIT" "$@"
    fi
}

_ensure_chain() {
    local family="$1"
    local chain="$2"

    if _fw_cmd "$family" -L "$chain" -n >/dev/null 2>&1; then
        _fw_cmd "$family" -F "$chain" >/dev/null 2>&1
    else
        _fw_cmd "$family" -N "$chain" >/dev/null 2>&1
    fi
}

_ensure_jump() {
    local family="$1"
    local from_chain="$2"
    local to_chain="$3"

    if ! _fw_cmd "$family" -C "$from_chain" -j "$to_chain" >/dev/null 2>&1; then
        if [ "$RULE_POSITION" = "top" ]; then
            _fw_cmd "$family" -I "$from_chain" -j "$to_chain" >/dev/null 2>&1
        else
            _fw_cmd "$family" -A "$from_chain" -j "$to_chain" >/dev/null 2>&1
        fi
    fi
}

_add_block_rules() {
    local family="$1"
    local ip="$2"

    _fw_cmd "$family" -A "$CHAIN" -s "$ip" -j "$CHAINACT"

    if [ "$EGF" -ne 0 ]; then
        _fw_cmd "$family" -A "$CHAIN" -d "$ip" -j "$CHAINACT"
    fi
}

_prepare_chains_for_family() {
    local family="$1"

    if _fw_cmd "$family" -L "$CHAIN" -n >/dev/null 2>&1; then
        _log "[$family] Flushed old rules. Applying updated Autosecure list..."
    else
        _log "[$family] Chain not detected. Creating new chain and adding Autoblock list..."
    fi

    _ensure_chain "$family" "$CHAIN"
    _ensure_chain "$family" "$CHAINACT"

    _ensure_jump "$family" INPUT "$CHAIN"
    _ensure_jump "$family" FORWARD "$CHAIN"
    if [ "$EGF" -ne 0 ]; then
        _ensure_jump "$family" OUTPUT "$CHAIN"
    fi

    _fw_cmd "$family" -A "$CHAINACT" -j LOG --log-prefix "[AUTOSECURE BLOCK] " -m limit --limit 3/min --limit-burst 10 >/dev/null 2>&1
    _fw_cmd "$family" -A "$CHAINACT" -j DROP >/dev/null 2>&1
}

_apply_list_to_family() {
    local family="$1"
    local list_file="$2"
    local count=0

    _prepare_chains_for_family "$family"

    while IFS= read -r ip; do
        [ -n "$ip" ] || continue
        if ! _ip_matches_family "$family" "$ip"; then
            continue
        fi
        _add_block_rules "$family" "$ip"
        count=$((count + 1))
    done < "$list_file"

    _log "[$family] Applied ${count} block entries."
}

_collect_feed_data() {
    local output_file="$1"

    # list of known spammers
    # DShield based on earlier work from:
    # http://wiki.brokenpoet.org/wiki/Get_DShield_Blocklist
    # https://github.com/koconder/dshield_automatic_iptables
    local urls=(
        "https://www.spamhaus.org/drop/drop.txt"
        "https://www.spamhaus.org/drop/edrop.txt"
        "http://feeds.dshield.org/block.txt"
    )

    local files=(
        "${TMP_DIR}/spamhaus_drop.txt"
        "${TMP_DIR}/spamhaus_edrop.txt"
        "${TMP_DIR}/dshield_drop.txt"
    )

    : > "$output_file"

    for idx in "${!urls[@]}"; do
        local url="${urls[$idx]}"
        local file="${files[$idx]}"

        _log "Downloading ${url} to ${file} using ${DOWNLOADER}..."
        if ! _download_file "$url" "$file"; then
            _log "Failed to download ${url}. Skipping this source."
            continue
        fi

        if [ ! -s "$file" ]; then
            _log "Downloaded file is empty: ${file}. Skipping."
            rm -f "$file"
            continue
        fi

        _log "Parsing hosts in ${file}..."

        if [ "$idx" -eq 2 ]; then
            while IFS= read -r ip; do
                [ -n "$ip" ] || continue
                if _is_valid_ip_or_cidr "$ip"; then
                    printf '%s\n' "$ip" >> "$output_file"
                fi
            done < <(_parse_dshield_file "$file")
        else
            while IFS= read -r ip; do
                [ -n "$ip" ] || continue
                if _is_valid_ip_or_cidr "$ip"; then
                    printf '%s\n' "$ip" >> "$output_file"
                fi
            done < <(_parse_static_blocklist_file "$file")
        fi

        _log "Done parsing ${file}. Removing..."
        rm -f "$file"
    done

    sort -u -o "$output_file" "$output_file"
}

_validate_settings() {
    case "$RULE_POSITION" in
        append|top) ;;
        *) _die "RULE_POSITION must be 'append' or 'top' (got: ${RULE_POSITION})" ;;
    esac

    case "$IPV6_ENABLE" in
        0|1) ;;
        *) _die "IPV6_ENABLE must be 0 or 1 (got: ${IPV6_ENABLE})" ;;
    esac

    case "$EGF" in
        0|1) ;;
        *) _die "EGF must be 0 or 1 (got: ${EGF})" ;;
    esac

    if ! [[ "$XTABLES_WAIT" =~ ^[0-9]+$ ]]; then
        _die "XTABLES_WAIT must be an integer (got: ${XTABLES_WAIT})"
    fi
}

main() {
    if [ "${1:-}" = "-q" ]; then
        QUIET=1
        shift
    fi

    if [ "${EUID:-$(id -u)}" -ne 0 ]; then
        _die "This script must run as root."
    fi

    _validate_settings
    _require_cmd iptables
    _require_cmd awk
    _require_cmd grep
    _require_cmd sort
    _require_cmd mkdir
    _select_downloader

    IPTABLES_BIN="$(command -v iptables)"

    if [ "$IPV6_ENABLE" -eq 1 ]; then
        _require_cmd ip6tables
        IP6TABLES_BIN="$(command -v ip6tables)"
    fi

    mkdir -p "$TMP_DIR" "$STATE_DIR"

    local staged_list="${TMP_DIR}/blocked_ips.new"
    local active_list="$staged_list"

    _collect_feed_data "$staged_list"

    if [ ! -s "$staged_list" ]; then
        if [ -s "$CACHE_FILE" ]; then
            active_list="$CACHE_FILE"
            _log "No valid new feed data; using cached blocklist from ${CACHE_FILE}."
        else
            _die "No valid feed data and no cache available. Existing firewall rules left unchanged."
        fi
    else
        cp "$staged_list" "$CACHE_FILE"
        _log "Cached latest blocklist to ${CACHE_FILE}."
    fi

    _apply_list_to_family v4 "$active_list"

    if [ "$IPV6_ENABLE" -eq 1 ]; then
        _apply_list_to_family v6 "$active_list"
    fi

    _log "Completed."
}

if [[ "${BASH_SOURCE[0]}" = "$0" ]]; then
    main "$@"
fi
