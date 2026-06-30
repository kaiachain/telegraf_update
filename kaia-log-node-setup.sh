#!/usr/bin/env bash
# =============================================================================
# kaia-log-node-setup.sh
# Run once on node.kaia.io (as root or with sudo).
# - Creates kairos_logs / mainnet_logs InfluxDB databases
# - Sets 7-day retention (uploads happen hourly, 7d is safety buffer)
# - Installs kaia-log-influx-to-gcs.py as hourly cron
# =============================================================================

set -euo pipefail

INFLUX_HOST="${INFLUX_HOST:-localhost}"
INFLUX_PORT="${INFLUX_PORT:-45560}"
INFLUX_URL="http://${INFLUX_HOST}:${INFLUX_PORT}"
RETENTION="${RETENTION:-7d}"
UPLOAD_SCRIPT="/usr/local/bin/kaia-log-influx-to-gcs"
CRON_FILE="/etc/cron.d/kaia-log-influx-to-gcs"
UPLOAD_LOG="/var/log/kaia-log-influx-to-gcs.log"

info() { printf '\033[0;32m[INFO]\033[0m  %s\n' "$*"; }
die()  { printf '\033[0;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

command -v influx  >/dev/null 2>&1 || die "influx CLI not found"
command -v python3 >/dev/null 2>&1 || die "python3 not found"
command -v gcloud  >/dev/null 2>&1 || die "gcloud not found"

echo "============================================================"
echo "  Kaia CN Log -> GCS  [node.kaia.io setup]"
echo "  InfluxDB : ${INFLUX_URL}"
echo "  Retention: ${RETENTION}"
echo "============================================================"
echo

# ── Create InfluxDB databases ─────────────────────────────────────────────────
for db in kairos_logs mainnet_logs; do
    info "Creating database: ${db}"
    influx -host "$INFLUX_HOST" -port "$INFLUX_PORT" \
        -execute "CREATE DATABASE ${db}"
    influx -host "$INFLUX_HOST" -port "$INFLUX_PORT" \
        -execute "ALTER RETENTION POLICY autogen ON ${db} DURATION ${RETENTION} REPLICATION 1 DEFAULT"
    info "Retention set: ${db} -> ${RETENTION}"
done

# ── Install upload script ─────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cp "${SCRIPT_DIR}/kaia-log-influx-to-gcs.py" "$UPLOAD_SCRIPT"
chmod 755 "$UPLOAD_SCRIPT"
info "Upload script installed: ${UPLOAD_SCRIPT}"

# ── Install cron (runs at :05 each hour) ─────────────────────────────────────
cat > "$CRON_FILE" << EOF
# Upload previous hour's CN logs from InfluxDB to GCS
5 * * * * root ${UPLOAD_SCRIPT} >> ${UPLOAD_LOG} 2>&1
EOF
info "Cron installed: ${CRON_FILE} (runs at :05 each hour)"

echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Done. Next steps:"
echo ""
echo "  1. On each Kairos CN node:"
echo "     - Copy kaia-log-telegraf-kairos.conf to /etc/telegraf/telegraf.d/"
echo "     - Add  namedrop = [\"kcnd_log\"]  to existing [[outputs.influxdb]]"
echo "     - sudo systemctl reload telegraf"
echo ""
echo "  2. On each Mainnet CN node:"
echo "     - Copy kaia-log-telegraf-mainnet.conf to /etc/telegraf/telegraf.d/"
echo "     - Add  namedrop = [\"kcnd_log\"]  to existing [[outputs.influxdb]]"
echo "     - sudo systemctl reload telegraf"
echo ""
echo "  3. Test upload manually:"
echo "     sudo ${UPLOAD_SCRIPT}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo
