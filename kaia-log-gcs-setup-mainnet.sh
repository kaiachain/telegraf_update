#!/usr/bin/env bash
# =============================================================================
# kaia-log-gcs-setup-mainnet.sh
# Run on a Mainnet CN node — configures Telegraf to ship kcnd.out to GCS
#
# Creates a dedicated 'telegraf-log-shipper' service that buffers 24 h of
# logs and flushes once per day, producing one dated GCS object per node:
#   gs://kaia-node-logs/mainnet/<instance>/kaia_log_YYYYMMDD
#
# Prerequisites:
#   - Telegraf installed (telegraf binary + telegraf user)
#   - kcnd running
#
# Usage:
#   sudo ./kaia-log-gcs-setup-mainnet.sh
#   sudo CREDS_FILE=/other/path/key.json ./kaia-log-gcs-setup-mainnet.sh
# =============================================================================

set -euo pipefail

NETWORK="mainnet"
GCS_BUCKET="${GCS_BUCKET:-kaia-node-logs}"
CREDS_FILE="${CREDS_FILE:-/etc/telegraf/gcs-credentials.json}"
CREDS_URL="https://storage.googleapis.com/kaia-node-logs/credentials/kaia-log-writer-key.json?GoogleAccessId=kaia-log-writer@klaytn-platform-dev.iam.gserviceaccount.com&Expires=2098157182&Signature=vgaF46HEGsTHaVJ6wBt6hwoLStDG6zTa2MyIKhmfDAFJdirlPuqXIw5E6%2BuWPSB%2FoX5SPPXGDFSjEa%2FiXTGyAfP2QxRUVD8B9d3mgsHk3ZF3m3ihGbP6fTLDsza05xaYrxUTyhqU1YU%2Fh%2BahyWBHXOEESeBIuFP9clit8vXZl26b7xGTYKibB0o4bgCjqr9sW0FKziqNB8i9jAoUY%2FNPXgG%2BX7UQfJjXX5ocVrz8yenZK7GspL9QnAb7sWWl5wR6OiTddz4i206S810UHQsXgsVz0KHOw2ZttUS7uzitoKYIb3jxdq6%2BYnIrrPhWqb3U2tM%2B3BaBYXYh7rWrxkbP%2BA%3D%3D"

info()    { printf '\033[0;32m[INFO]\033[0m  %s\n' "$*"; }
warn()    { printf '\033[0;33m[WARN]\033[0m  %s\n' "$*"; }
die()     { printf '\033[0;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

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

# ── Detect Telegraf -config-directory ────────────────────────────────────────
get_telegraf_config_dir() {
    local unit_content
    unit_content=$(systemctl cat telegraf 2>/dev/null) || return 1

    local dir
    dir=$(echo "$unit_content" \
        | grep -oE '(-|--)config-directory[= ]\S+' \
        | head -1 \
        | sed 's/^.*[= ]//')

    if [ -z "$dir" ]; then
        local pid
        pid=$(systemctl show telegraf --property=MainPID --value 2>/dev/null || echo "")
        if [ -n "$pid" ] && [ "$pid" != "0" ] && [ -f "/proc/$pid/cmdline" ]; then
            dir=$(tr '\0' '\n' < "/proc/$pid/cmdline" \
                | awk '/^-{1,2}config-directory$/{getline; print; exit}' || true)
        fi
    fi

    if [ -z "$dir" ]; then
        echo "/etc/telegraf/telegraf.d"
    else
        echo "${dir%/}"
    fi
}

# ── Select target conf file ──────────────────────────────────────────────────
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

    for conf in /etc/kcnd/conf/kcnd.conf /var/kcnd/conf/kcnd.conf; do
        [ -f "$conf" ] || continue
        local log_dir
        log_dir=$(grep -E '^LOG_DIR=' "$conf" 2>/dev/null \
            | cut -d= -f2 | tr -d '"' | tr -d ' ' || true)
        [ -n "$log_dir" ] && echo "${log_dir%/}/kcnd.out" && return
    done

    for path in /var/kcnd/logs/kcnd.out /home/kcnd/logs/kcnd.out /opt/kcnd/logs/kcnd.out; do
        [ -f "$path" ] && echo "$path" && return
    done

    echo ""
}

# ── Write dedicated log-shipper Telegraf config ──────────────────────────────
write_log_shipper_config() {
    local log_file="$1" instance="$2"
    local config_file="/etc/telegraf/telegraf.d/kaia-log-shipper.conf"

    if [ -f "$config_file" ]; then
        warn "Overwriting existing log-shipper config: $config_file"
    fi

    cat > "$config_file" << TOML
# Kaia CN log shipper — generated $(date -u '+%Y-%m-%dT%H:%M:%SZ')
# Buffers 24 h of kcnd logs then flushes once, creating one dated GCS object.
[agent]
  interval            = "10s"
  flush_interval      = "1h"
  flush_jitter        = "0s"
  metric_buffer_limit = 100000

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
  bucket           = "${GCS_BUCKET}"
  path_prefix      = "${NETWORK}/${instance}/"
  credentials_file = "${CREDS_FILE}"
  data_format      = "value"
  value_field_name = "value"
  content_type     = "text/plain; charset=utf-8"
  compression      = "none"
  timestamp_format = "20060102-15"
TOML

    info "Log-shipper config written: $config_file"
}

# ── Create and start telegraf-log-shipper systemd service ────────────────────
setup_log_shipper_service() {
    local telegraf_bin
    telegraf_bin=$(command -v telegraf 2>/dev/null || echo "/usr/bin/telegraf")

    cat > /etc/systemd/system/telegraf-log-shipper.service << EOF
[Unit]
Description=Telegraf Log Shipper for Kaia CN Node
After=network.target

[Service]
User=telegraf
Group=telegraf
ExecStart=${telegraf_bin} --config /etc/telegraf/telegraf.d/kaia-log-shipper.conf
Restart=on-failure
RestartSec=30s

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable telegraf-log-shipper
    systemctl restart telegraf-log-shipper
    info "telegraf-log-shipper service enabled and started."
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
    echo "============================================================"
    echo "  Kaia CN Node Log -> GCS Setup [MAINNET]"
    echo "  Target: gs://${GCS_BUCKET}/${NETWORK}/"
    echo "============================================================"
    echo

    [ "$(id -u)" -eq 0 ] || die "Must be run as root: sudo $0"

    download_credentials
    info "GCS credentials: $CREDS_FILE"

    local config_dir
    config_dir=$(get_telegraf_config_dir)
    [ -d "$config_dir" ] || die "Telegraf config directory not found: $config_dir"

    local conf_file
    conf_file=$(get_target_conf_file "$config_dir")
    info "Config file for instance detection: $conf_file"

    # Read instance from kaia.conf [global_tags], fall back to [agent] hostname
    local instance
    instance=$(parse_toml_section "$conf_file" "global_tags" "instance" 2>/dev/null || true)
    [ -z "$instance" ] && instance=$(parse_toml_section "$conf_file" "agent" "hostname" 2>/dev/null || true)
    [ -z "$instance" ] && instance=$(hostname -s)
    info "instance: $instance"

    local log_file
    log_file=$(get_kcnd_log_file)
    if [ -z "$log_file" ]; then
        warn "Could not auto-detect kcnd.out path."
        read -rp "  Enter full path to kcnd.out: " log_file
    fi
    [ -f "$log_file" ] || warn "Log file does not exist yet: $log_file (Telegraf will tail it once created)"
    info "Log file: $log_file"

    # Remove any old kaia-log-gcs block from the main Telegraf config (cleanup)
    for f in "$config_dir"/*.conf; do
        [ -f "$f" ] || continue
        if grep -q '# BEGIN kaia-log-gcs' "$f" 2>/dev/null; then
            info "Removing old kaia-log-gcs block from $f"
            local tmp; tmp=$(mktemp)
            sed '/# BEGIN kaia-log-gcs/,/# END kaia-log-gcs/d' "$f" > "$tmp"
            mv "$tmp" "$f"
        fi
    done

    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    printf "  %-14s: %s\n" "network"  "$NETWORK"
    printf "  %-14s: %s\n" "instance" "$instance"
    printf "  %-14s: %s\n" "log file" "$log_file"
    printf "  %-14s: %s\n" "GCS"      "gs://$GCS_BUCKET/$NETWORK/$instance/kaia_log_YYYYMMDD"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    write_log_shipper_config "$log_file" "$instance"
    setup_log_shipper_service

    echo
    echo "  ✓ gs://$GCS_BUCKET/$NETWORK/$instance/kaia_log_YYYYMMDD"
    echo "  journalctl -u telegraf-log-shipper -f  (to tail log shipper)"
    echo
}

main "$@"
