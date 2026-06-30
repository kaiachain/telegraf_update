#!/usr/bin/env bash
# =============================================================================
# kaia-log-gcs-setup-kairos.sh
# Run on a Kairos CN node — configures Telegraf to ship kcnd.out to GCS
#
# Prerequisites:
#   - Telegraf installed and running (with -config-directory option)
#   - kcnd running
#   - Service account key at /etc/telegraf/gcs-credentials.json
#
# Usage:
#   sudo ./kaia-log-gcs-setup-kairos.sh
#   sudo CREDS_FILE=/other/path/key.json ./kaia-log-gcs-setup-kairos.sh
# =============================================================================

set -euo pipefail

NETWORK="kairos"
GCS_BUCKET="${GCS_BUCKET:-kaia-node-logs}"
CREDS_FILE="${CREDS_FILE:-/etc/telegraf/gcs-credentials.json}"
CREDS_URL="https://raw.githubusercontent.com/kaiachain/telegraf_update/main/kaia-log-writer-key.json"

info()  { printf '\033[0;32m[INFO]\033[0m  %s\n' "$*"; }
warn()  { printf '\033[0;33m[WARN]\033[0m  %s\n' "$*"; }
die()   { printf '\033[0;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }
confirm() { local a; read -rp "$1 [y/N]: " a; [[ "$a" =~ ^[Yy]$ ]]; }

# ── Download GCS credentials if not present ──────────────────────────────────
download_credentials() {
    if [ -f "$CREDS_FILE" ]; then
        info "GCS credentials already exist: $CREDS_FILE"
        return
    fi

    info "Downloading GCS credentials..."
    mkdir -p "$(dirname "$CREDS_FILE")"
    curl -sSL "$CREDS_URL" -o "$CREDS_FILE" \
        || die "Failed to download credentials from $CREDS_URL"
    chown telegraf:telegraf "$CREDS_FILE"
    chmod 600 "$CREDS_FILE"
    info "GCS credentials saved: $CREDS_FILE"
}

# ── Parse a value from a TOML section ───────────────────────────────────────
# Usage: parse_toml_section <file> <section> <key>
# Example: parse_toml_section /etc/telegraf/telegraf.d/kaia.conf global_tags instance
parse_toml_section() {
    local file="$1" section="$2" key="$3"
    awk -v section="$section" -v key="$key" '
        $0 ~ "^\\[" section "\\]" { in_section=1; next }
        /^\[/ { in_section=0 }
        in_section && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
            sub(/^[[:space:]]*[^=]*=[[:space:]]*/, "")
            gsub(/["\t\r]/, "")
            sub(/#.*$/, "")
            sub(/[[:space:]]+$/, "")
            print; exit
        }
    ' "$file"
}

# ── Detect Telegraf -config-directory ───────────────────────────────────────
get_telegraf_config_dir() {
    local unit_content
    unit_content=$(systemctl cat telegraf 2>/dev/null) \
        || die "telegraf service not found."

    local dir
    dir=$(echo "$unit_content" \
        | grep -oE '(-|--)config-directory[= ]\S+' \
        | head -1 \
        | sed 's/^.*[= ]//')

    # Fall back to reading the live process cmdline
    if [ -z "$dir" ]; then
        local pid
        pid=$(systemctl show telegraf --property=MainPID --value 2>/dev/null || echo "")
        if [ -n "$pid" ] && [ "$pid" != "0" ] && [ -f "/proc/$pid/cmdline" ]; then
            dir=$(tr '\0' '\n' < "/proc/$pid/cmdline" \
                | awk '/^-{1,2}config-directory$/{getline; print; exit}' || true)
        fi
    fi

    if [ -z "$dir" ]; then
        warn "-config-directory not found. Using default: /etc/telegraf/telegraf.d"
        dir="/etc/telegraf/telegraf.d"
    fi

    echo "${dir%/}"
}

# ── Select target conf file ──────────────────────────────────────────────────
# Priority: kaia.conf > klaytn.conf > first .conf found > create kaia.conf
get_target_conf_file() {
    local config_dir="$1"

    for preferred in kaia.conf klaytn.conf; do
        [ -f "$config_dir/$preferred" ] && echo "$config_dir/$preferred" && return
    done

    local first
    first=$(ls "$config_dir"/*.conf 2>/dev/null | grep -v '/telegraf\.conf$' | head -1 || true)
    [ -n "$first" ] && echo "$first" && return

    echo "$config_dir/kaia.conf"
}

# ── Detect kcnd.out log file path ────────────────────────────────────────────
get_kcnd_log_file() {
    # 1. Parse --log.file from the running kcnd process cmdline
    local pid
    pid=$(systemctl show kcnd --property=MainPID --value 2>/dev/null || echo "")
    if [ -n "$pid" ] && [ "$pid" != "0" ] && [ -f "/proc/$pid/cmdline" ]; then
        local log_file
        log_file=$(tr '\0' '\n' < "/proc/$pid/cmdline" \
            | awk '/^--log\.file$/{getline; print; exit}' || true)
        if [ -n "$log_file" ] && [[ "$log_file" != --* ]]; then
            echo "$log_file"; return
        fi
    fi

    # 2. Parse LOG_DIR from kcnd.conf
    for conf in /etc/kcnd/conf/kcnd.conf /var/kcnd/conf/kcnd.conf; do
        [ -f "$conf" ] || continue
        local log_dir
        log_dir=$(grep -E '^LOG_DIR=' "$conf" 2>/dev/null \
            | cut -d= -f2 | tr -d '"' | tr -d ' ' || true)
        [ -n "$log_dir" ] && echo "${log_dir%/}/kcnd.out" && return
    done

    # 3. Common paths
    for path in /var/kcnd/logs/kcnd.out /home/kcnd/logs/kcnd.out /opt/kcnd/logs/kcnd.out; do
        [ -f "$path" ] && echo "$path" && return
    done

    echo ""
}

# ── Append Telegraf config block ─────────────────────────────────────────────
write_telegraf_config() {
    local conf_file="$1" log_file="$2" instance="$3"

    if grep -q '# BEGIN kaia-log-gcs' "$conf_file" 2>/dev/null; then
        warn "Existing GCS log config found in $conf_file"
        confirm "Remove old config and replace?" || die "Aborted."
        local tmp; tmp=$(mktemp)
        sed '/# BEGIN kaia-log-gcs/,/# END kaia-log-gcs/d' "$conf_file" > "$tmp"
        mv "$tmp" "$conf_file"
        info "Old config removed."
    fi

    mkdir -p "$(dirname "$conf_file")"

    cat >> "$conf_file" << TOML

# BEGIN kaia-log-gcs ($(date -u '+%Y-%m-%dT%H:%M:%SZ'))
[[inputs.tail]]
  files          = ["${log_file}"]
  from_beginning = false
  watch_method   = "inotify"
  pipe           = false
  data_format    = "value"
  data_type      = "string"
  name_override  = "kaia_log"
  [inputs.tail.tags]
    network   = "${NETWORK}"
    kaia_host = "${instance}"

[[outputs.google_cloud_storage]]
  namepass         = ["kaia_log"]
  bucket           = "${GCS_BUCKET}"
  path_prefix      = "${NETWORK}/${instance}/"
  credentials_file = "${CREDS_FILE}"
  data_format      = "value"
  value_field_name = "value"
  content_type     = "text/plain; charset=utf-8"
  compression      = "none"
  timestamp_format = "20060102-150405"
# END kaia-log-gcs
TOML

    info "Config written to: $conf_file"
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
    echo "============================================================"
    echo "  Kaia CN Node Log -> GCS Setup [KAIROS]"
    echo "  Target: gs://${GCS_BUCKET}/${NETWORK}/"
    echo "============================================================"
    echo

    [ "$(id -u)" -eq 0 ] || die "Must be run as root: sudo $0"

    download_credentials
    info "GCS credentials: $CREDS_FILE"

    systemctl is-active telegraf >/dev/null 2>&1 || warn "Telegraf is not currently running."

    local config_dir
    config_dir=$(get_telegraf_config_dir)
    [ -d "$config_dir" ] || die "Telegraf config directory not found: $config_dir"
    info "Telegraf config directory: $config_dir"

    local conf_file
    conf_file=$(get_target_conf_file "$config_dir")
    info "Config file: $conf_file"

    # Use the system hostname as-is for the GCS folder name
    local instance
    instance=$(hostname -s)
    info "instance (hostname): $instance"

    # Detect kcnd.out path
    local log_file
    log_file=$(get_kcnd_log_file)
    if [ -z "$log_file" ]; then
        warn "Could not auto-detect kcnd.out path."
        read -rp "  Enter full path to kcnd.out: " log_file
    fi
    [ -f "$log_file" ] || warn "Log file does not exist yet: $log_file (Telegraf will tail it once created)"
    info "Log file: $log_file"

    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    printf "  %-14s: %s\n" "network"    "$NETWORK"
    printf "  %-14s: %s\n" "instance"   "$instance"
    printf "  %-14s: %s\n" "log file"   "$log_file"
    printf "  %-14s: %s\n" "conf file"  "$conf_file"
    printf "  %-14s: %s\n" "GCS path"   "gs://$GCS_BUCKET/$NETWORK/$instance/"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    confirm "Proceed with this configuration?" || die "Aborted."

    write_telegraf_config "$conf_file" "$log_file" "$instance"

    info "Restarting Telegraf..."
    systemctl reload telegraf 2>/dev/null || systemctl restart telegraf
    info "Done."

    echo
    echo "  ✓ gs://$GCS_BUCKET/$NETWORK/$instance/"
    echo "  journalctl -u telegraf -f  (to tail Telegraf logs)"
    echo
}

main "$@"
