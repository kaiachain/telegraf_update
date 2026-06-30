#!/usr/bin/env bash
# =============================================================================
# gcs-setup.sh
# Run once as a GCP admin — creates service account, IAM binding, and key file
#
# Prerequisites: gcloud CLI authenticated, Owner/Editor role on the target project
#
# Usage:
#   ./gcs-setup.sh
#   PROJECT=my-project BUCKET=my-bucket ./gcs-setup.sh
# =============================================================================

set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────────────
PROJECT="${PROJECT:-klaytn-platform-dev}"
BUCKET="${BUCKET:-kaia-node-logs}"
SA_NAME="${SA_NAME:-kaia-log-writer}"
KEY_FILE="${KEY_FILE:-kaia-log-writer-key.json}"

SA_EMAIL="${SA_NAME}@${PROJECT}.iam.gserviceaccount.com"

# ── Helpers ──────────────────────────────────────────────────────────────────
info()  { printf '\033[0;32m[INFO]\033[0m  %s\n' "$*"; }
warn()  { printf '\033[0;33m[WARN]\033[0m  %s\n' "$*"; }
error() { printf '\033[0;31m[ERROR]\033[0m %s\n' "$*" >&2; }
die()   { error "$*"; exit 1; }
confirm() { local a; read -rp "$1 [y/N]: " a; [[ "$a" =~ ^[Yy]$ ]]; }

# ── Pre-flight checks ────────────────────────────────────────────────────────
command -v gcloud >/dev/null 2>&1 || die "gcloud CLI not found. Install the Google Cloud SDK."

echo "============================================================"
echo "  Kaia Node Log -> GCS Service Account Setup"
echo "  Project : $PROJECT"
echo "  Bucket  : gs://$BUCKET"
echo "============================================================"
echo

# Verify current gcloud auth
CURRENT_ACCOUNT=$(gcloud config get-value account 2>/dev/null)
info "Current gcloud account: ${CURRENT_ACCOUNT:-none}"
[ -n "$CURRENT_ACCOUNT" ] || die "Not authenticated. Run 'gcloud auth login' first."

# Set active project
gcloud config set project "$PROJECT" 2>/dev/null
info "Project set: $PROJECT"

# ── 1. Verify bucket exists ──────────────────────────────────────────────────
info "Checking bucket: gs://$BUCKET"
gcloud storage buckets describe "gs://$BUCKET" --project="$PROJECT" >/dev/null 2>&1 \
    || die "Bucket gs://$BUCKET not found. Check the bucket name."
info "Bucket verified."

# Check Uniform Bucket-Level Access (required for IAM Conditions)
UBA_STATUS=$(gcloud storage buckets describe "gs://$BUCKET" \
    --format="value(iamConfiguration.uniformBucketLevelAccess.enabled)" 2>/dev/null || echo "")

if [ "${UBA_STATUS}" != "True" ]; then
    warn "Uniform Bucket-Level Access is disabled."
    warn "UBA is required to restrict writes to a specific prefix via IAM Conditions."
    if confirm "Enable Uniform Bucket-Level Access? (existing ACLs will be removed)"; then
        gcloud storage buckets update "gs://$BUCKET" --uniform-bucket-level-access
        info "Uniform Bucket-Level Access enabled."
    else
        warn "Proceeding without UBA. objectCreator will be granted on the entire bucket."
        SKIP_CONDITION=true
    fi
fi
SKIP_CONDITION="${SKIP_CONDITION:-false}"

# ── 2. Create service account (idempotent) ───────────────────────────────────
info "Checking service account: $SA_EMAIL"
if gcloud iam service-accounts describe "$SA_EMAIL" --project="$PROJECT" >/dev/null 2>&1; then
    info "Service account already exists."
else
    gcloud iam service-accounts create "$SA_NAME" \
        --project="$PROJECT" \
        --display-name="Kaia Node Log Writer" \
        --description="Write-only to ${BUCKET}/ for external kaia nodes"
    info "Service account created."
fi

# ── 3. IAM binding: objectCreator + prefix condition ────────────────────────
info "Applying IAM binding..."

if [ "$SKIP_CONDITION" = "true" ]; then
    # No UBA: grant without condition (lower security, but still a service account)
    gcloud storage buckets add-iam-policy-binding "gs://$BUCKET" \
        --member="serviceAccount:${SA_EMAIL}" \
        --role="roles/storage.objectCreator"
    warn "storage.objectCreator granted without prefix condition (entire bucket writable)."
else
    # Prefix-scoped binding — write access limited to kaia-node-logs/ only
    CONDITION_EXPR="resource.name.startsWith('projects/_/buckets/${BUCKET}/objects/')"
    gcloud storage buckets add-iam-policy-binding "gs://$BUCKET" \
        --member="serviceAccount:${SA_EMAIL}" \
        --role="roles/storage.objectCreator" \
        --condition="expression=${CONDITION_EXPR},title=kaia-log-bucket-write,description=Write access to ${BUCKET}"
    info "IAM binding applied (write access to bucket: ${BUCKET})."
fi

# ── 4. Create service account JSON key ──────────────────────────────────────
if [ -f "$KEY_FILE" ]; then
    warn "Key file $KEY_FILE already exists."
    if confirm "Issue a new key? (overwrites existing file)"; then
        gcloud iam service-accounts keys create "$KEY_FILE" \
            --iam-account="$SA_EMAIL" \
            --project="$PROJECT"
        info "New key created: $KEY_FILE"
    else
        info "Keeping existing key file."
    fi
else
    gcloud iam service-accounts keys create "$KEY_FILE" \
        --iam-account="$SA_EMAIL" \
        --project="$PROJECT"
    info "Key created: $KEY_FILE"
fi

# Restrict key file permissions
chmod 600 "$KEY_FILE"

# ── Done ─────────────────────────────────────────────────────────────────────
echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✓ GCS setup complete"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo
echo "  Service account : $SA_EMAIL"
echo "  Key file        : $(pwd)/$KEY_FILE"
echo "  Writable bucket : gs://$BUCKET/"
echo
echo "  ─── Next steps ──────────────────────────────────────────"
echo
echo "  Copy the key file to each external server:"
echo
echo "    scp $KEY_FILE <server>:/tmp/gcs-credentials.json"
echo "    ssh <server> 'sudo mv /tmp/gcs-credentials.json /etc/telegraf/gcs-credentials.json'"
echo "    ssh <server> 'sudo chown telegraf:telegraf /etc/telegraf/gcs-credentials.json'"
echo "    ssh <server> 'sudo chmod 600 /etc/telegraf/gcs-credentials.json'"
echo
echo "  Then run on each server:"
echo
echo "    sudo ./kaia-log-gcs-setup-kairos.sh   # for Kairos CN nodes"
echo "    sudo ./kaia-log-gcs-setup-mainnet.sh  # for Mainnet CN nodes"
echo
echo "  ⚠  Keep $KEY_FILE secure."
echo "     This key grants write access to gs://$BUCKET/"
echo
