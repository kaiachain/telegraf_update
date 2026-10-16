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
INFLUX_URL="${INFLUX_URL:-http://metrics.node.kaia.io:45560}"
INFLUX_DB="${INFLUX_DB:-kaia-network-monitoring}"
DEFAULT_EXE="kcn"
FLUENTBIT_INSTALL_URL="${FLUENTBIT_INSTALL_URL:-https://raw.githubusercontent.com/fluent/fluent-bit/master/install.sh}"
FLUENTBIT_BIN="/opt/fluent-bit/bin/fluent-bit"
FLUENTBIT_CONF_DIR="/etc/fluent-bit"
LOG_CONF="${FLUENTBIT_CONF_DIR}/kaia-logs.conf"
PREFLIGHT_SCRIPT="/usr/local/bin/kaia-log-shipper-preflight.sh"
LOG_SHIPPER_UNIT="/etc/systemd/system/kaia-log-shipper.service"
# vlogs-external LoadBalancer (kaia-grafana namespace, kaia-cluster-prod) —
# same VictoriaLogs ingest endpoint the kairos fleet's kaia-log-shipper units
# already point at. Port 45560 is shared with the metrics endpoint above by
# deliberate choice (both external Services' own upstream components still
# listen internally on their old default ports, 8429/9428 — only the
# external-facing port was unified), not a coincidence to preserve.
LOG_INGEST_HOST="${LOG_INGEST_HOST:-logs.node.kaia.io}"
LOG_INGEST_PORT="${LOG_INGEST_PORT:-45560}"

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
# right repo itself — no distro-specific branching needed here. This only
# installs the binary/package; it deliberately does NOT enable the package's
# own `fluent-bit.service` (that unit runs the stock demo
# /etc/fluent-bit/fluent-bit.conf, not this node's actual log shipping). The
# real unit is `kaia-log-shipper.service`, set up by install_log_shipper
# below. ─────────────────────────────────────────────────────────────────────
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
        systemctl disable --now fluent-bit > /dev/null 2>&1 || true
    fi
}

# ── Find this node's kcnd log file, the same 3-tier detection the older
# kaia-log-telegraf-setup-mainnet.sh used: live process cmdline first, then
# the daemon's own conf, then common log paths. Sets LOG_FILE directly (not
# via echo/$(...), which would run this in a subshell and drop it). ────────
LOG_FILE=""
detect_kaia_log_file() {
    local pid
    pid=$(systemctl show kcnd --property=MainPID --value 2>/dev/null || echo "")
    if [ -n "$pid" ] && [ "$pid" != "0" ] && [ -f "/proc/$pid/cmdline" ]; then
        local lf
        lf=$(tr '\0' '\n' < "/proc/$pid/cmdline" \
            | awk '/^--log\.file$/{getline; print; exit}' || true)
        if [ -n "$lf" ] && [[ "$lf" != --* ]]; then
            LOG_FILE="$lf"; return
        fi
    fi
    for conf in /etc/kcnd/conf/kcnd.conf /var/kcnd/conf/kcnd.conf; do
        [ -f "$conf" ] || continue
        local log_dir
        log_dir=$(grep -E '^LOG_DIR=' "$conf" 2>/dev/null | cut -d= -f2 | tr -d '" ' || true)
        if [ -n "$log_dir" ]; then
            LOG_FILE="${log_dir%/}/kcnd.out"; return
        fi
    done
    for path in /var/kcnd/logs/kcnd.out /home/kcnd/logs/kcnd.out /opt/kcnd/logs/kcnd.out; do
        if [ -f "$path" ]; then
            LOG_FILE="$path"; return
        fi
    done
}

# ── This node's `instance` tag value — must match what telegraf already
# tags this host as (the `hostname` under [agent] in kaia.conf/klaytn.conf),
# or the node ends up split across two identities in the metric and log
# dashboards. Falls back to `uname -n` only when no conf exists yet. ────────
get_node_instance() {
    local target hostname_val
    target="$(find_target_conf)"
    if [ -n "$target" ]; then
        hostname_val=$(sed -n 's/^[[:space:]]*hostname[[:space:]]*=[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' "$target" | head -n1)
    fi
    echo "${hostname_val:-$(uname -n)}"
}

# ── The kaia-logs.conf content, parameterized the same way render_conf is —
# one render function shared by nothing else here since there's no preview
# path (log shipping needs a real log file to point at, unlike the metrics
# conf which can always be previewed). ──────────────────────────────────────
render_log_conf() {
    local log_file="$1" instance="$2"
    cat << EOF
# kaia-logs.conf — managed by kaia-cn-v3-telegrafupdate.sh. Manual edits are
# overwritten the next time this script runs.
#
# Ships this node's kcnd log to VictoriaLogs via Fluent Bit rather than
# telegraf: telegraf's own InfluxDB output would exit entirely if a second,
# log-shipping output (e.g. Elasticsearch) failed its connection handshake,
# which would silently stop this node's METRICS too. A separate process
# can't do that — whatever happens to log shipping, telegraf and the chain
# process are untouched.

[SERVICE]
    Flush                     5
    Log_Level                 info
    # Node-side spill buffer. Only holds data while the upstream is
    # unreachable, and empties itself once delivery resumes. A queue, not a
    # log store.
    storage.path              /var/lib/fluent-bit/chunks
    # Write chunks through to disk rather than relying on the page cache —
    # the setting that makes a hard kill survivable.
    storage.sync              normal
    storage.checksum          on
    storage.max_chunks_up     128

[INPUT]
    Name                      tail
    Path                      ${log_file}
    # Read position, so an agent restart neither re-ships nor skips. Must
    # live on persistent storage, not /tmp.
    DB                        /var/lib/fluent-bit/tail.db
    DB.sync                   normal
    storage.type              filesystem
    # Start at the end of the file on first install — shipping the node's
    # entire existing log history on day one would be hours of backlog for
    # no benefit.
    Read_from_Head            false
    # A Kaia log line is ~211 bytes; anything past 32k is not a log line.
    Skip_Long_Lines           on
    Buffer_Chunk_Size         32k
    Buffer_Max_Size           64k
    Tag                       kaia

[FILTER]
    Name                      record_modifier
    Match                     kaia
    # These three become the VictoriaLogs stream, which is what the store
    # partitions and compresses by. Identity only — nothing with open
    # cardinality, and deliberately not the file path (which drifts across
    # the fleet) so each node is its own stream regardless of path shape.
    Record                    instance ${instance}
    Record                    nodetype ${NODETYPE}
    Record                    network  ${NETWORK}

[OUTPUT]
    Name                      http
    Match                     kaia
    host                      ${LOG_INGEST_HOST}
    port                      ${LOG_INGEST_PORT}
    # No TLS — a deliberate carry-over, same as the metrics path beside it
    # (metrics.node.kaia.io:45560): plain HTTP reachable only from an IP
    # allowlist. Node logs are block numbers/hashes/peer counts, not
    # secrets, but raising this whole ingest surface to TLS is tracked as a
    # separate, not-yet-done item.
    uri                       /insert/jsonline?_msg_field=log&_time_field=date&_stream_fields=instance,nodetype,network
    format                    json_lines
    json_date_format          iso8601
    json_date_key             date
    compress                  gzip
    # Retry forever — the filesystem buffer above holds the backlog, and
    # giving up would turn a cluster restart into permanent loss.
    Retry_Limit               false
    # Cap what this node may hold in the local spill buffer.
    storage.total_limit_size  1G
EOF
}

render_preflight_script() {
    cat << 'EOF'
#!/bin/sh
# Startup guard for the Kaia node log shipper. Run by ExecStartPre; a
# non-zero exit stops the unit before Fluent Bit starts.
#
# It exists because every way this config can be wrong is SILENT: a wrong
# Path makes tail simply wait forever for a file that never appears, and the
# unit sits there Running and healthy, shipping nothing.
#
# Usage: kaia-log-shipper-preflight.sh /etc/fluent-bit/kaia-logs.conf
set -eu

CONF="${1:-/etc/fluent-bit/kaia-logs.conf}"

if [ ! -r "$CONF" ]; then
  echo "preflight: config not readable: $CONF" >&2
  exit 1
fi

# The file we intend to tail is there and readable AS THIS UNIT'S USER.
# Reading it as root would pass here and fail at runtime.
LOGPATH=$(sed -n 's/^[[:space:]]*Path[[:space:]]\{1,\}//p' "$CONF" | head -1)
if [ -z "$LOGPATH" ]; then
  echo "preflight: no Path found in $CONF" >&2
  exit 1
fi
if [ ! -r "$LOGPATH" ]; then
  echo "preflight: log file is not readable by $(id -un): $LOGPATH" >&2
  echo "preflight: add this user to the group that owns it, or fix the path" >&2
  exit 1
fi

# The buffer directory must be writable, or Fluent Bit silently degrades to
# memory-only buffering — the property that made us choose it in the first
# place.
BUFDIR=$(sed -n 's/^[[:space:]]*storage.path[[:space:]]\{1,\}//p' "$CONF" | head -1)
if [ -n "$BUFDIR" ]; then
  mkdir -p "$BUFDIR" 2>/dev/null || true
  if [ ! -w "$BUFDIR" ]; then
    echo "preflight: buffer dir is not writable by $(id -un): $BUFDIR" >&2
    exit 1
  fi
fi

echo "preflight: ok — tailing $LOGPATH, buffering in ${BUFDIR:-<none>}"
EOF
}

render_log_shipper_unit() {
    cat << EOF
# /etc/systemd/system/kaia-log-shipper.service
# Managed by kaia-cn-v3-telegrafupdate.sh. Installed alongside the node's
# existing telegraf unit; it replaces nothing and depends on nothing.
# Removing log shipping is \`systemctl disable --now kaia-log-shipper\` — the
# node's metrics path is not involved either way.

[Unit]
Description=Kaia node log shipper (Fluent Bit -> VictoriaLogs)
Documentation=https://docs.victoriametrics.com/victorialogs/data-ingestion/fluentbit/
After=network-online.target
Wants=network-online.target
# A node that stopped shipping because systemd rate-limited it would look
# identical to a node that is simply quiet. This belongs in [Unit], not
# [Service] — systemd moved it in 229 and the old placement is silently
# ignored on current releases.
StartLimitIntervalSec=0

[Service]
Type=simple

ExecStartPre=${PREFLIGHT_SCRIPT} ${LOG_CONF}
# Fluent Bit's own parser, so a malformed config fails here rather than in a
# restart loop.
ExecStartPre=${FLUENTBIT_BIN} --dry-run -c ${LOG_CONF}

ExecStart=${FLUENTBIT_BIN} -c ${LOG_CONF}

KillSignal=SIGTERM
TimeoutStopSec=60

Restart=always
RestartSec=10

# Unprivileged. It reads one log file and writes one buffer directory.
User=fluent-bit
Group=fluent-bit
StateDirectory=fluent-bit
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
# ProtectSystem=strict makes /var read-only; this is the one exception, for
# the chunk buffer and the tail offset DB.
ReadWritePaths=/var/lib/fluent-bit
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true

# Bounded, so a runaway shipper cannot compete with the chain process.
MemoryMax=256M
CPUQuota=50%

[Install]
WantedBy=multi-user.target
EOF
}

# ── Set up the real log-shipping unit: a dedicated unprivileged user, the
# per-node kaia-logs.conf (Path/instance/nodetype/network all filled in —
# no CHANGE_ME placeholders, unlike the older manual-install docs this
# replaces), the startup preflight guard, and the kaia-log-shipper systemd
# unit. Skips entirely (not just a partial no-op) when the unit is already
# active, so a good existing install is never touched. ──────────────────────
install_log_shipper() {
    if [ ! -x "$FLUENTBIT_BIN" ]; then
        warn "${FLUENTBIT_BIN} not found — Fluent Bit install must have failed, skip log shipper setup."
        return
    fi

    if systemctl is-active kaia-log-shipper > /dev/null 2>&1; then
        info "kaia-log-shipper already active — skip log shipper setup."
        return
    fi

    detect_kaia_log_file
    if [ -z "$LOG_FILE" ]; then
        warn "Could not auto-detect kcnd's --log.file path — skip log shipper setup (metrics are unaffected)."
        return
    fi
    if [ ! -f "$LOG_FILE" ]; then
        warn "Detected log file does not exist yet: ${LOG_FILE} — skip log shipper setup for now."
        return
    fi

    local instance
    instance="$(get_node_instance)"

    if ! getent group fluent-bit > /dev/null 2>&1; then
        groupadd -r fluent-bit
    fi
    if ! getent passwd fluent-bit > /dev/null 2>&1; then
        useradd -r -g fluent-bit -d /home/fluent-bit -s /sbin/nologin -c "Fluent Bit" fluent-bit
    fi

    render_log_conf "$LOG_FILE" "$instance" > "$LOG_CONF"
    chmod 644 "$LOG_CONF"

    render_preflight_script > "$PREFLIGHT_SCRIPT"
    chmod 755 "$PREFLIGHT_SCRIPT"

    render_log_shipper_unit > "$LOG_SHIPPER_UNIT"
    chmod 644 "$LOG_SHIPPER_UNIT"

    info "Log shipper configured (log_file=${LOG_FILE}, instance=${instance}, destination=${LOG_INGEST_HOST}:${LOG_INGEST_PORT})"

    systemctl daemon-reload
    if systemctl enable --now kaia-log-shipper; then
        info "kaia-log-shipper enabled and started"
    else
        warn "kaia-log-shipper failed to start — check: systemctl status kaia-log-shipper"
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
    install_log_shipper

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
