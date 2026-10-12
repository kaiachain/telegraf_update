#!/usr/bin/env bash
# =============================================================================
# kaia-cn-v3-telegrafupdate.sh
# Run on a Mainnet CN node — migrates telegraf.d/{kaia,klaytn}.conf to the v3
# format (fixed nodetype/network global tags, new metrics InfluxDB target),
# tunes telegraf.conf's [agent] collection intervals, and installs Fluent Bit.
#
# Usage:
#   curl -sSL https://raw.githubusercontent.com/kaiachain/telegraf_update/main/kaia-cn-v3-telegrafupdate.sh | sudo bash
# =============================================================================

set -euo pipefail

CONF_DIR="/etc/telegraf/telegraf.d"
TELEGRAF_CONF="/etc/telegraf/telegraf.conf"
NODETYPE="cn"
NETWORK="mainnet"
INFLUX_URL="${INFLUX_URL:-http://35.216.80.92:8429}"
INFLUX_DB="${INFLUX_DB:-kaia-network-monitoring}"
DEFAULT_EXE="kcn"
FLUENTBIT_INSTALL_URL="${FLUENTBIT_INSTALL_URL:-https://raw.githubusercontent.com/fluent/fluent-bit/master/install.sh}"

info() { printf '\033[0;32m[INFO]\033[0m  %s\n' "$*"; }
warn() { printf '\033[0;33m[WARN]\033[0m  %s\n' "$*"; }
die()  { printf '\033[0;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

CHANGED=0

# ── The v3 kaia.conf/klaytn.conf content, parameterized by the hostname/exe
# this node already uses. Shared by the real-write path and the preview path
# below so both always render identically. ──────────────────────────────────
render_conf() {
    local hostname="$1" exe="$2"
    cat << EOF
[global_tags]
# Change "cn" to "pn" for PN installation
nodetype = "${NODETYPE}"
network = "${NETWORK}"
[agent]
# The CN/PN name (e.g. \`klaytn-cn\`, \`klaytn-pn-01\`)
hostname = "${hostname}"

[[inputs.procstat]]
  exe = "${exe}"

[inputs.prometheus]
urls = [ "http://localhost:61001/metrics" ]

[[outputs.influxdb]]
  urls = ["${INFLUX_URL}"]
  database = "${INFLUX_DB}"

  namedrop = ["kaia_log"]
  skip_database_creation = true
EOF
}

# ── Find the existing per-node conf under telegraf.d/, if any. ─────────────
find_target_conf() {
    local f
    for f in "${CONF_DIR}/kaia.conf" "${CONF_DIR}/klaytn.conf"; do
        [ -f "$f" ] && { echo "$f"; return; }
    done
}

# ── Migrate kaia.conf/klaytn.conf to the v3 format. Preserves this node's
# existing hostname/exe values; only the surrounding structure and the
# InfluxDB output target change. Skips (not an error) when already migrated,
# or when the existing file doesn't look like the expected v2 shape (so we
# never guess at a hostname that isn't really there). When no conf file
# exists at all, nothing is written — the content that WOULD be created is
# printed so an operator can create it (or re-run after a conf exists). ────
migrate_node_conf() {
    local target
    target="$(find_target_conf)"

    if [ -z "$target" ]; then
        warn "No kaia.conf or klaytn.conf found under ${CONF_DIR}/ — not creating one."
        warn "Preview of what would be written to ${CONF_DIR}/kaia.conf for this host:"
        echo "----------------------------------------"
        render_conf "$(uname -n)" "${DEFAULT_EXE}"
        echo "----------------------------------------"
        return
    fi

    info "Found existing conf: ${target}"

    if grep -qE '^[[:space:]]*network[[:space:]]*=' "$target"; then
        info "${target} already has a network tag — already migrated, skip."
        return
    fi

    local hostname_val exe_val
    hostname_val=$(sed -n 's/^[[:space:]]*hostname[[:space:]]*=[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' "$target" | head -n1)
    exe_val=$(sed -n 's/^[[:space:]]*exe[[:space:]]*=[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' "$target" | head -n1)

    if [ -z "$hostname_val" ]; then
        warn "${target} has no hostname = \"...\" under [agent] — doesn't look like the expected v2 shape, skip (no changes made)."
        return
    fi
    if [ -z "$exe_val" ]; then
        warn "${target} has no exe = \"...\" under [[inputs.procstat]] — defaulting to \"${DEFAULT_EXE}\"."
        exe_val="${DEFAULT_EXE}"
    fi

    local backup
    backup="${target}.bak.$(date +%Y%m%d%H%M%S)"
    cp -p "$target" "$backup"
    # cp (not mv) so $target keeps its original mode/owner/SELinux context.
    render_conf "$hostname_val" "$exe_val" > "${target}.tmp"
    cp "${target}.tmp" "$target"
    rm -f "${target}.tmp"

    info "Migrated ${target} (hostname=${hostname_val}, exe=${exe_val}, backup: ${backup})"
    CHANGED=1
}

# ── Set interval/round_interval/flush_interval under [agent] in
# telegraf.conf, only touching lines that actually differ from the desired
# value (uncommenting if needed). Idempotent: a diff against the patched
# output decides whether anything actually changed. ────────────────────────
patch_agent_intervals() {
    if [ ! -f "$TELEGRAF_CONF" ]; then
        warn "${TELEGRAF_CONF} not found — skip agent interval patch."
        return
    fi

    local tmp
    tmp=$(mktemp)
    awk '
        /^[[:space:]]*\[agent\][[:space:]]*$/ { in_agent=1; print; next }
        in_agent && /^[[:space:]]*\[/ { in_agent=0 }
        in_agent && /^[[:space:]]*#?[[:space:]]*interval[[:space:]]*=/ && $0 !~ /round_interval|flush_interval/ {
            match($0, /^[[:space:]]*/); indent = substr($0, RSTART, RLENGTH)
            print indent "interval = \"10s\""
            next
        }
        in_agent && /^[[:space:]]*#?[[:space:]]*round_interval[[:space:]]*=/ {
            match($0, /^[[:space:]]*/); indent = substr($0, RSTART, RLENGTH)
            print indent "round_interval = true"
            next
        }
        in_agent && /^[[:space:]]*#?[[:space:]]*flush_interval[[:space:]]*=/ {
            match($0, /^[[:space:]]*/); indent = substr($0, RSTART, RLENGTH)
            print indent "flush_interval = \"10s\""
            next
        }
        { print }
    ' "$TELEGRAF_CONF" > "$tmp"

    if diff -q "$TELEGRAF_CONF" "$tmp" > /dev/null 2>&1; then
        info "${TELEGRAF_CONF}: interval/round_interval/flush_interval already correct — skip."
        rm -f "$tmp"
        return
    fi

    local backup
    backup="${TELEGRAF_CONF}.bak.$(date +%Y%m%d%H%M%S)"
    cp -p "$TELEGRAF_CONF" "$backup"
    cp "$tmp" "$TELEGRAF_CONF"
    rm -f "$tmp"
    info "Patched ${TELEGRAF_CONF}: interval=\"10s\", round_interval=true, flush_interval=\"10s\" under [agent] (backup: ${backup})"
    CHANGED=1
}

# ── Install Fluent Bit via its official installer, which auto-detects
# Ubuntu/Debian (apt) vs RHEL/CentOS/Rocky/Alma (yum/dnf) and sets up the
# right repo itself — no distro-specific branching needed here. ────────────
install_fluent_bit() {
    if command -v fluent-bit > /dev/null 2>&1; then
        info "Fluent Bit already installed ($(fluent-bit --version 2>&1 | head -n1)) — skip install."
        return
    fi

    info "Installing Fluent Bit via the official installer (${FLUENTBIT_INSTALL_URL})..."
    if curl -fsSL "$FLUENTBIT_INSTALL_URL" | sh; then
        info "Fluent Bit installed."
    else
        warn "Fluent Bit install script failed — check manually."
        return
    fi

    if command -v systemctl > /dev/null 2>&1; then
        systemctl enable --now fluent-bit \
            && info "fluent-bit service enabled and started" \
            || warn "fluent-bit installed but the service could not be started — check manually."
    fi
}

main() {
    echo "============================================================"
    echo "  Kaia CN Telegraf v3 Update [MAINNET]"
    echo "  Target DB: ${INFLUX_URL}/${INFLUX_DB}"
    echo "============================================================"
    echo

    (( EUID == 0 )) || die "Must be run as root: sudo $0"
    command -v telegraf > /dev/null 2>&1 || die "telegraf not found"

    migrate_node_conf
    patch_agent_intervals
    install_fluent_bit

    if [ "$CHANGED" -eq 1 ]; then
        if systemctl is-active telegraf > /dev/null 2>&1; then
            systemctl reload telegraf \
                && info "telegraf reloaded" \
                || { warn "reload failed, trying restart..."; systemctl restart telegraf && info "telegraf restarted"; }
        else
            warn "telegraf is not running — start it manually: systemctl start telegraf"
        fi
    else
        info "No telegraf config changes made — skip reload."
    fi

    info "Done."
}

main "$@"
