#!/usr/bin/env bash
# =============================================================================
# kaia-log-telegraf-setup-kairos.sh
# Run on a Kairos CN node — installs Telegraf log config
#
# Usage:
#   curl -sSL https://raw.githubusercontent.com/kaiachain/telegraf_update/main/kaia-log-telegraf-setup-kairos.sh | sudo bash
# =============================================================================

set -euo pipefail

NETWORK="kairos"
INFLUX_URL="${INFLUX_URL:-http://node.kaia.io:45560}"
INFLUX_DB="kairos-log"
CONF_FILE="/etc/telegraf/telegraf.d/kaia_log.conf"

info() { printf '\033[0;32m[INFO]\033[0m  %s\n' "$*"; }
warn() { printf '\033[0;33m[WARN]\033[0m  %s\n' "$*"; }
die()  { printf '\033[0;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

# ── Detect kcnd --log.file path ──────────────────────────────────────────────
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

main() {
    echo "============================================================"
    echo "  Kaia CN Telegraf Log Config Setup [KAIROS]"
    echo "  Target DB: ${INFLUX_URL}/${INFLUX_DB}"
    echo "============================================================"
    echo

    [ "$(id -u)" -eq 0 ] || die "Must be run as root: sudo $0"
    command -v telegraf >/dev/null 2>&1 || die "telegraf not found"

    local log_file
    log_file=$(get_kcnd_log_file)
    if [ -z "$log_file" ]; then
        warn "Could not auto-detect kcnd log file path."
        read -rp "  Enter full path to kcnd log file (--log.file): " log_file </dev/tty
    fi
    [ -f "$log_file" ] || warn "Log file does not exist yet: $log_file"
    info "Log file: $log_file"

    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    printf "  %-12s: %s\n" "network"  "$NETWORK"
    printf "  %-12s: %s\n" "log file" "$log_file"
    printf "  %-12s: %s\n" "influxdb" "${INFLUX_URL}  db=${INFLUX_DB}"
    printf "  %-12s: %s\n" "conf"     "$CONF_FILE"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo

    cat > "$CONF_FILE" << EOF
[[inputs.tail]]
  files = ["${log_file}"]
  from_beginning = false
  watch_method = "inotify"
  name_override = "kaia_log"
  data_format = "value"
  data_type = "string"

[[outputs.influxdb]]
  urls = ["${INFLUX_URL}"]
  database = "${INFLUX_DB}"
  namepass = ["kaia_log"]
EOF

    info "Config written: $CONF_FILE"

    if systemctl is-active telegraf >/dev/null 2>&1; then
        systemctl reload telegraf \
            && info "telegraf reloaded" \
            || { warn "reload failed, trying restart..."; systemctl restart telegraf && info "telegraf restarted"; }
    else
        warn "telegraf is not running — start it manually: systemctl start telegraf"
    fi

    info "Done."
}

main "$@"
