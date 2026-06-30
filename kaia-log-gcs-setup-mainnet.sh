#!/usr/bin/env bash
# =============================================================================
# kaia-log-gcs-setup-mainnet.sh
# Run on a Mainnet CN node — ships kcnd logs to GCS every hour
#
# Flow:
#   kcnd → --log.file (e.g. /var/kcnd/logs/kcnd.out)
#        → [telegraf-log-shipper: inputs.tail → outputs.file → kcnd.log]
#        → [hourly cron /usr/local/bin/kaia-log-gcs-upload]
#        → gs://kaia-node-logs/mainnet/<instance>/kaia_log_YYYYMMDD-HH
#
# The log-shipper config lives at /etc/telegraf/kaia-log-shipper.conf
# (NOT inside telegraf.d/) so the main telegraf service is unaffected.
#
# Prerequisites:
#   - Telegraf installed (binary + telegraf user)
#   - kcnd running
#   - python3 + cryptography library installed
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

# Config lives OUTSIDE telegraf.d/ to avoid being loaded by the main telegraf
SHIPPER_CONF="/etc/telegraf/kaia-log-shipper.conf"
SHIPPER_SERVICE="/etc/systemd/system/telegraf-log-shipper.service"
UPLOAD_SCRIPT="/usr/local/bin/kaia-log-gcs-upload"
CRON_FILE="/etc/cron.d/kaia-log-gcs"

info() { printf '\033[0;32m[INFO]\033[0m  %s\n' "$*"; }
warn() { printf '\033[0;33m[WARN]\033[0m  %s\n' "$*"; }
die()  { printf '\033[0;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

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
    chmod 600 "$CREDS_FILE"
    info "GCS credentials saved: $CREDS_FILE"
}

# ── Parse a value from a TOML section ────────────────────────────────────────
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

# ── Detect Telegraf -config-directory (for instance name detection) ───────────
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

# ── Select conf file for instance name detection ──────────────────────────────
get_target_conf_file() {
    local config_dir="$1"
    for preferred in kaia.conf klaytn.conf; do
        [ -f "$config_dir/$preferred" ] && echo "$config_dir/$preferred" && return
    done
    local first
    first=$(ls "$config_dir"/*.conf 2>/dev/null \
        | grep -v '/telegraf\.conf$' \
        | grep -v '/kaia-log-shipper\.conf$' \
        | head -1 || true)
    [ -n "$first" ] && echo "$first" && return
    echo "$config_dir/kaia.conf"
}

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

# ── Write log-shipper Telegraf config ────────────────────────────────────────
# Placed at /etc/telegraf/kaia-log-shipper.conf (not in telegraf.d/)
# so the main telegraf service does not load it.
write_shipper_config() {
    local log_file="$1" local_log="$2" instance="$3"

    [ -f "$SHIPPER_CONF" ] && warn "Overwriting existing config: $SHIPPER_CONF"

    cat > "$SHIPPER_CONF" << TOML
# Kaia CN log shipper — generated $(date -u '+%Y-%m-%dT%H:%M:%SZ')
# Loaded only by telegraf-log-shipper.service, NOT by the main telegraf.
# inputs.tail reads kcnd.out; outputs.file writes to kcnd.log (same dir).
# Hourly cron (kaia-log-gcs-upload) copytruncates kcnd.log and uploads to GCS.

[agent]
  interval       = "10s"
  flush_interval = "10s"

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

[[outputs.file]]
  files            = ["${local_log}"]
  data_format      = "value"
  value_field_name = "value"
TOML

    info "Log-shipper config written: $SHIPPER_CONF"
}

# ── Create telegraf-log-shipper systemd service ───────────────────────────────
setup_shipper_service() {
    local telegraf_bin
    telegraf_bin=$(command -v telegraf 2>/dev/null || echo "/usr/bin/telegraf")

    cat > "$SHIPPER_SERVICE" << EOF
[Unit]
Description=Telegraf Log Shipper for Kaia CN Node
After=network.target

[Service]
User=telegraf
Group=telegraf
ExecStart=${telegraf_bin} --config ${SHIPPER_CONF}
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

# ── Install hourly GCS upload script ─────────────────────────────────────────
install_upload_script() {
    local local_log="$1" instance="$2"

    cat > "$UPLOAD_SCRIPT" << PYEOF
#!/usr/bin/env python3
"""
Copytruncate kcnd.log (written by telegraf-log-shipper) and upload the
previous hour's content to GCS. Called every hour by cron.
"""
import json, os, time, base64, shutil, datetime, tempfile
import urllib.request, urllib.parse
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding

NETWORK  = "${NETWORK}"
HOSTNAME = "${instance}"
BUCKET   = "${GCS_BUCKET}"
KEY_FILE = "${CREDS_FILE}"
LOG_FILE = "${local_log}"

def get_access_token():
    with open(KEY_FILE) as f:
        k = json.load(f)
    now = int(time.time())
    hdr = base64.urlsafe_b64encode(b'{"alg":"RS256","typ":"JWT"}').rstrip(b'=')
    clm = json.dumps({
        "iss": k["client_email"],
        "scope": "https://www.googleapis.com/auth/devstorage.read_write",
        "aud":   "https://oauth2.googleapis.com/token",
        "iat": now, "exp": now + 3600,
    }).encode()
    pay = base64.urlsafe_b64encode(clm).rstrip(b'=')
    msg = hdr + b"." + pay
    key = serialization.load_pem_private_key(k["private_key"].encode(), password=None)
    sig = base64.urlsafe_b64encode(
        key.sign(msg, padding.PKCS1v15(), hashes.SHA256())
    ).rstrip(b'=')
    jwt_token = (msg + b"." + sig).decode()
    data = urllib.parse.urlencode({
        "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
        "assertion": jwt_token,
    }).encode()
    req = urllib.request.Request("https://oauth2.googleapis.com/token", data=data)
    with urllib.request.urlopen(req) as r:
        return json.loads(r.read())["access_token"]

def upload_file(token, local_path, gcs_object):
    url = (
        "https://storage.googleapis.com/upload/storage/v1/b/"
        + BUCKET + "/o?uploadType=media"
        + "&name=" + urllib.parse.quote(gcs_object, safe="")
    )
    with open(local_path, "rb") as f:
        content = f.read()
    req = urllib.request.Request(url, data=content, method="POST")
    req.add_header("Authorization", "Bearer " + token)
    req.add_header("Content-Type", "text/plain; charset=utf-8")
    with urllib.request.urlopen(req) as r:
        r.read()

def main():
    if not os.path.exists(LOG_FILE) or os.path.getsize(LOG_FILE) == 0:
        print("No log data to upload.")
        return

    prev     = datetime.datetime.utcnow() - datetime.timedelta(hours=1)
    date_str = prev.strftime("%Y%m%d-%H")

    # copytruncate into a temp file so telegraf-log-shipper keeps writing
    tmp_fd, tmp_path = tempfile.mkstemp(suffix=".log", prefix="kaia-log-")
    os.close(tmp_fd)
    try:
        shutil.copy2(LOG_FILE, tmp_path)
        open(LOG_FILE, "w").close()

        gcs_object = NETWORK + "/" + HOSTNAME + "/kaia_log_" + date_str
        token = get_access_token()
        upload_file(token, tmp_path, gcs_object)
        print("Uploaded: gs://" + BUCKET + "/" + gcs_object)
    finally:
        if os.path.exists(tmp_path):
            os.remove(tmp_path)

if __name__ == "__main__":
    main()
PYEOF

    chmod 755 "$UPLOAD_SCRIPT"
    info "Upload script installed: $UPLOAD_SCRIPT"
}

# ── Add hourly cron job ───────────────────────────────────────────────────────
install_cron() {
    local upload_log="$1"
    cat > "$CRON_FILE" << EOF
# Upload previous hour's kcnd log to GCS
0 * * * * root ${UPLOAD_SCRIPT} >> ${upload_log} 2>&1
EOF
    info "Cron job installed: $CRON_FILE"
}

# ── Clean up stale files from previous installations ─────────────────────────
cleanup_old() {
    local old_conf="/etc/telegraf/telegraf.d/kaia-log-shipper.conf"
    if [ -f "$old_conf" ]; then
        info "Removing stale config from telegraf.d/: $old_conf"
        rm -f "$old_conf"
        systemctl reload telegraf 2>/dev/null || true
    fi
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

    local config_dir
    config_dir=$(get_telegraf_config_dir 2>/dev/null || echo "/etc/telegraf/telegraf.d")

    local instance=""
    if [ -d "$config_dir" ]; then
        local conf_file
        conf_file=$(get_target_conf_file "$config_dir")
        if [ -f "$conf_file" ]; then
            instance=$(parse_toml_section "$conf_file" "global_tags" "instance" 2>/dev/null || true)
            [ -z "$instance" ] && instance=$(parse_toml_section "$conf_file" "agent" "hostname" 2>/dev/null || true)
        fi
    fi
    [ -z "$instance" ] && instance=$(hostname -s)
    info "instance: $instance"

    local log_file
    log_file=$(get_kcnd_log_file)
    if [ -z "$log_file" ]; then
        warn "Could not auto-detect kcnd log file path."
        read -rp "  Enter full path to kcnd log file (--log.file): " log_file </dev/tty
    fi
    [ -f "$log_file" ] || warn "Log file does not exist yet: $log_file"
    info "Log file (--log.file): $log_file"

    local log_dir local_log upload_log
    log_dir="$(dirname "$log_file")"
    local_log="${log_dir}/kcnd.log"
    upload_log="${log_dir}/kaia-gcs-upload.log"

    # Grant telegraf write access to the kcnd log directory
    chown root:telegraf "$log_dir"
    chmod g+w "$log_dir"
    info "Granted telegraf write access to: $log_dir"

    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    printf "  %-14s: %s\n" "network"   "$NETWORK"
    printf "  %-14s: %s\n" "instance"  "$instance"
    printf "  %-14s: %s\n" "kcnd log"  "$log_file"
    printf "  %-14s: %s\n" "local log" "$local_log"
    printf "  %-14s: %s\n" "GCS"       "gs://$GCS_BUCKET/$NETWORK/$instance/kaia_log_YYYYMMDD-HH"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo

    cleanup_old
    write_shipper_config "$log_file" "$local_log" "$instance"
    setup_shipper_service
    install_upload_script "$local_log" "$instance"
    install_cron "$upload_log"

    info "Done."
    echo
    echo "  ✓ gs://$GCS_BUCKET/$NETWORK/$instance/kaia_log_YYYYMMDD-HH"
    echo "  Uploads run hourly. Next upload at the top of the next hour."
    echo "  Upload log: $upload_log"
    echo
    echo "  journalctl -u telegraf-log-shipper -f   (to tail log shipper)"
    echo
}

main "$@"
