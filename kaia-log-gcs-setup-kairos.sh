#!/usr/bin/env bash
# =============================================================================
# kaia-log-gcs-setup-kairos.sh
# Run on a Kairos CN node — ships kcnd logs to GCS every hour
#
# Flow:
#   kcnd → --log.file (e.g. /var/kcnd/logs/kcnd.out)
#        → [hourly cron: /usr/local/bin/kaia-log-gcs-upload]
#        → gs://kaia-node-logs/kairos/<hostname>/kaia_log_YYYYMMDD-HH
#
# Prerequisites:
#   - kcnd running
#   - python3 + cryptography library installed
#
# Usage:
#   sudo ./kaia-log-gcs-setup-kairos.sh
#   sudo CREDS_FILE=/other/path/key.json ./kaia-log-gcs-setup-kairos.sh
# =============================================================================

set -euo pipefail

NETWORK="kairos"
GCS_BUCKET="${GCS_BUCKET:-kaia-node-logs}"
CREDS_FILE="${CREDS_FILE:-/etc/telegraf/gcs-credentials.json}"
CREDS_URL="https://storage.googleapis.com/kaia-node-logs/credentials/kaia-log-writer-key.json?GoogleAccessId=kaia-log-writer@klaytn-platform-dev.iam.gserviceaccount.com&Expires=2098157182&Signature=vgaF46HEGsTHaVJ6wBt6hwoLStDG6zTa2MyIKhmfDAFJdirlPuqXIw5E6%2BuWPSB%2FoX5SPPXGDFSjEa%2FiXTGyAfP2QxRUVD8B9d3mgsHk3ZF3m3ihGbP6fTLDsza05xaYrxUTyhqU1YU%2Fh%2BahyWBHXOEESeBIuFP9clit8vXZl26b7xGTYKibB0o4bgCjqr9sW0FKziqNB8i9jAoUY%2FNPXgG%2BX7UQfJjXX5ocVrz8yenZK7GspL9QnAb7sWWl5wR6OiTddz4i206S810UHQsXgsVz0KHOw2ZttUS7uzitoKYIb3jxdq6%2BYnIrrPhWqb3U2tM%2B3BaBYXYh7rWrxkbP%2BA%3D%3D"

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

# ── Install hourly GCS upload script ─────────────────────────────────────────
install_upload_script() {
    local log_file="$1" instance="$2"
    local openssl_bin
    openssl_bin=$(command -v openssl 2>/dev/null || echo /usr/bin/openssl)

    cat > "$UPLOAD_SCRIPT" << PYEOF
#!/usr/bin/env python3
"""
Copytruncate kcnd's --log.file and upload the previous hour's content to GCS.
Called every hour by cron (runs as root).
Uses openssl for RSA signing — no third-party Python libraries required.
"""
import json, os, time, base64, shutil, datetime, tempfile, subprocess
import urllib.request, urllib.parse

NETWORK  = "${NETWORK}"
HOSTNAME = "${instance}"
BUCKET   = "${GCS_BUCKET}"
KEY_FILE = "${CREDS_FILE}"
LOG_FILE = "${log_file}"
OPENSSL  = "${openssl_bin}"

def get_access_token():
    with open(KEY_FILE) as f:
        k = json.load(f)
    now = int(time.time())
    hdr = base64.urlsafe_b64encode(b'{"alg":"RS256","typ":"JWT"}').rstrip(b'=').decode()
    clm = base64.urlsafe_b64encode(json.dumps({
        "iss": k["client_email"],
        "scope": "https://www.googleapis.com/auth/devstorage.read_write",
        "aud":   "https://oauth2.googleapis.com/token",
        "iat": now, "exp": now + 3600,
    }).encode()).rstrip(b'=').decode()
    signing_input = (hdr + "." + clm).encode()

    # Write private key to a temp file and sign with openssl
    tmp = tempfile.NamedTemporaryFile(mode='w', suffix='.pem', delete=False)
    try:
        tmp.write(k["private_key"])
        tmp.flush()
        tmp.close()
        result = subprocess.run(
            [OPENSSL, "dgst", "-sha256", "-sign", tmp.name],
            input=signing_input,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE
        )
        if result.returncode != 0:
            raise RuntimeError("openssl signing failed: " + result.stderr.decode())
        sig = base64.urlsafe_b64encode(result.stdout).rstrip(b'=').decode()
    finally:
        os.unlink(tmp.name)

    jwt_token = hdr + "." + clm + "." + sig
    data = urllib.parse.urlencode({
        "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
        "assertion": jwt_token,
    }).encode()
    req = urllib.request.Request("https://oauth2.googleapis.com/token", data=data)
    with urllib.request.urlopen(req) as r:
        return json.loads(r.read())["access_token"]

def upload_file(token, local_path, gcs_object):
    file_size = os.path.getsize(local_path)

    # Initiate resumable upload session (handles files of any size)
    init_url = (
        "https://storage.googleapis.com/upload/storage/v1/b/"
        + BUCKET + "/o?uploadType=resumable"
        + "&name=" + urllib.parse.quote(gcs_object, safe="")
    )
    init_req = urllib.request.Request(init_url, data=b'', method="POST")
    init_req.add_header("Authorization", "Bearer " + token)
    init_req.add_header("Content-Type", "application/json; charset=UTF-8")
    init_req.add_header("X-Upload-Content-Type", "text/plain; charset=utf-8")
    init_req.add_header("X-Upload-Content-Length", str(file_size))
    try:
        with urllib.request.urlopen(init_req) as r:
            upload_url = r.headers["Location"]
            r.read()
    except urllib.error.HTTPError as e:
        body = e.read().decode(errors="replace")
        raise RuntimeError(f"GCS initiate upload failed HTTP {e.code}: {body}")

    # Upload via curl to stream directly from disk (avoids loading into memory)
    result = subprocess.run(
        ["curl", "-s", "-w", "%{http_code}", "-X", "PUT", upload_url,
         "-H", "Content-Type: text/plain; charset=utf-8",
         "-T", local_path],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE
    )
    http_code = result.stdout[-3:].decode()
    if result.returncode != 0 or not http_code.startswith("2"):
        raise RuntimeError(f"curl upload failed (HTTP {http_code}): {result.stdout[:-3].decode(errors='replace')}")

def main():
    if not os.path.exists(LOG_FILE) or os.path.getsize(LOG_FILE) == 0:
        print("No log data to upload.")
        return

    prev     = datetime.datetime.utcnow() - datetime.timedelta(hours=1)
    date_str = prev.strftime("%Y%m%d-%H")

    tmp_fd, tmp_path = tempfile.mkstemp(suffix=".log", prefix="kaia-log-")
    os.close(tmp_fd)
    try:
        shutil.copy2(LOG_FILE, tmp_path)
        open(LOG_FILE, "w").close()

        gcs_object = NETWORK + "/" + HOSTNAME + "/" + HOSTNAME + "_log_" + date_str
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

# ── Remove any previous Telegraf-based log-shipper setup ─────────────────────
cleanup_old() {
    if systemctl is-active telegraf-log-shipper >/dev/null 2>&1 || \
       systemctl is-enabled telegraf-log-shipper >/dev/null 2>&1; then
        info "Removing telegraf-log-shipper service..."
        systemctl stop telegraf-log-shipper 2>/dev/null || true
        systemctl disable telegraf-log-shipper 2>/dev/null || true
    fi
    rm -f /etc/systemd/system/telegraf-log-shipper.service
    rm -f /etc/telegraf/kaia-log-shipper.conf
    rm -f /etc/telegraf/telegraf.d/kaia-log-shipper.conf
    systemctl daemon-reload
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

    local instance
    instance=$(hostname -s)
    info "instance (hostname): $instance"

    local log_file
    log_file=$(get_kcnd_log_file)
    if [ -z "$log_file" ]; then
        warn "Could not auto-detect kcnd log file path."
        read -rp "  Enter full path to kcnd log file (--log.file): " log_file </dev/tty
    fi
    [ -f "$log_file" ] || warn "Log file does not exist yet: $log_file"
    info "Log file (--log.file): $log_file"

    local upload_log
    upload_log="$(dirname "$log_file")/kaia-gcs-upload.log"

    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    printf "  %-14s: %s\n" "network"  "$NETWORK"
    printf "  %-14s: %s\n" "instance" "$instance"
    printf "  %-14s: %s\n" "log file" "$log_file"
    printf "  %-14s: %s\n" "GCS"      "gs://$GCS_BUCKET/$NETWORK/$instance/kaia_log_YYYYMMDD-HH"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo

    cleanup_old
    install_upload_script "$log_file" "$instance"
    install_cron "$upload_log"

    info "Done."
    echo
    echo "  ✓ gs://$GCS_BUCKET/$NETWORK/$instance/kaia_log_YYYYMMDD-HH"
    echo "  Uploads run hourly. Next upload at the top of the next hour."
    echo "  Upload log: $upload_log"
    echo
}

main "$@"
