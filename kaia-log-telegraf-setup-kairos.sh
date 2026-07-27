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
INFLUX_DB="kairos_logs"
CONF_FILE="/etc/telegraf/telegraf.d/kaia_log.conf"

info() { printf '\033[0;32m[INFO]\033[0m  %s\n' "$*"; }
warn() { printf '\033[0;33m[WARN]\033[0m  %s\n' "$*"; }
die()  { printf '\033[0;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

# ── Detect kaia daemon (cn=kcnd, pn=kpnd, en=kend) and its --log.file path ──
# Kaia nodes come in three types, each with its own daemon/log naming:
#   cn -> kcnd -> kcnd.out   pn -> kpnd -> kpnd.out   en -> kend -> kend.out
# Sets DAEMON and LOG_FILE directly (not via echo/$(...)) since a command
# substitution would run this in a subshell and silently drop DAEMON.
DAEMON=""
LOG_FILE=""
detect_kaia_log_file() {
    local svc pid
    for svc in kcnd kpnd kend; do
        pid=$(systemctl show "$svc" --property=MainPID --value 2>/dev/null || echo "")
        if [ -n "$pid" ] && [ "$pid" != "0" ] && [ -f "/proc/$pid/cmdline" ]; then
            local lf
            lf=$(tr '\0' '\n' < "/proc/$pid/cmdline" \
                | awk '/^--log\.file$/{getline; print; exit}' || true)
            if [ -n "$lf" ] && [[ "$lf" != --* ]]; then
                DAEMON="$svc"; LOG_FILE="$lf"; return
            fi
        fi
    done
    for svc in kcnd kpnd kend; do
        for conf in "/etc/${svc}/conf/${svc}.conf" "/var/${svc}/conf/${svc}.conf"; do
            [ -f "$conf" ] || continue
            local log_dir
            log_dir=$(grep -E '^LOG_DIR=' "$conf" 2>/dev/null \
                | cut -d= -f2 | tr -d '" ' || true)
            if [ -n "$log_dir" ]; then
                DAEMON="$svc"; LOG_FILE="${log_dir%/}/${svc}.out"; return
            fi
        done
    done
    for svc in kcnd kpnd kend; do
        for path in "/var/${svc}/logs/${svc}.out" "/home/${svc}/logs/${svc}.out" "/opt/${svc}/logs/${svc}.out"; do
            if [ -f "$path" ]; then
                DAEMON="$svc"; LOG_FILE="$path"; return
            fi
        done
    done
}

# ── Prevent kaia_log from also flowing into the existing metrics DB ─────────
# Existing kaia.conf/klaytn.conf has its own [[outputs.influxdb]] (procstat/
# prometheus -> kairos/mainnet metrics DB). Telegraf sends every input's
# metrics to every output unless filtered, so without a namedrop there the
# new kaia_log data would also land in the metrics DB. Patch it in-place
# (only the first [[outputs.influxdb]] block found; idempotent).
patch_metrics_output() {
    local target=""
    for f in /etc/telegraf/telegraf.d/kaia.conf /etc/telegraf/telegraf.d/klaytn.conf; do
        [ -f "$f" ] && { target="$f"; break; }
    done
    if [ -z "$target" ]; then
        warn "kaia.conf/klaytn.conf not found — skip metrics-output patch"
        return
    fi
    if ! grep -q '\[\[outputs\.influxdb\]\]' "$target"; then
        warn "$target has no [[outputs.influxdb]] block — skip patch"
        return
    fi
    if awk '
        /\[\[outputs\.influxdb\]\]/ { in_block=1; next }
        in_block && /^[ \t]*\[/ { in_block=0 }
        in_block && /^[ \t]*namedrop[ \t]*=/ && /kaia_log/ { found=1 }
        END { exit !found }
    ' "$target"; then
        info "$target already has namedrop=[\"kaia_log\"] — skip"
        return
    fi

    local tmp backup
    tmp=$(mktemp)
    backup="${target}.bak.$(date +%Y%m%d%H%M%S)"
    awk '
        BEGIN { in_block=0; patched=0 }
        /\[\[outputs\.influxdb\]\]/ { in_block=1; print; next }
        in_block && /^[ \t]*\[/ {
            if (!patched) print "  namedrop = [\"kaia_log\"]"
            in_block=0
            print
            next
        }
        in_block && /^[ \t]*namedrop[ \t]*=/ {
            if ($0 !~ /kaia_log/) sub(/\][ \t]*$/, ", \"kaia_log\"]")
            patched=1
            print
            next
        }
        { print }
        END { if (in_block && !patched) print "  namedrop = [\"kaia_log\"]" }
    ' "$target" > "$tmp"

    cp "$target" "$backup"
    # cp (not mv/rename) so $target keeps its original mode/owner/SELinux
    # context — cp writes into the existing inode, whereas mv would replace
    # it with the mktemp temp file's (0600, tmpfs context), which telegraf's
    # unprivileged service user then can't read.
    cp "$tmp" "$target"
    rm -f "$tmp"
    info "Patched $target: added namedrop=[\"kaia_log\"] to existing [[outputs.influxdb]] (backup: $backup)"
}

main() {
    echo "============================================================"
    echo "  Kaia CN Telegraf Log Config Setup [KAIROS]"
    echo "  Target DB: ${INFLUX_URL}/${INFLUX_DB}"
    echo "============================================================"
    echo

    (( EUID == 0 )) || die "Must be run as root: sudo $0"
    command -v telegraf >/dev/null 2>&1 || die "telegraf not found"

    detect_kaia_log_file
    local log_file="$LOG_FILE"
    if [ -z "$log_file" ]; then
        warn "Could not auto-detect kaia daemon (kcnd/kpnd/kend) log file path."
        read -rp "  Enter full path to log file (--log.file): " log_file </dev/tty
    fi
    [ -f "$log_file" ] || warn "Log file does not exist yet: $log_file"
    info "Daemon: ${DAEMON:-unknown}  Log file: $log_file"

    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    printf "  %-12s: %s\n" "network"  "$NETWORK"
    printf "  %-12s: %s\n" "daemon"   "${DAEMON:-unknown}"
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

    patch_metrics_output

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
