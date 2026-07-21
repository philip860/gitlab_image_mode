#!/usr/bin/env bash
###############################################################################
# Configure an Image Mode GitLab EC2 instance during its first boot.
#
# GitLab must already be installed in the bootc image.
#
# Configuration may be supplied through:
#
#   /etc/gitlab-firstboot.env
#
# Required:
#
#   GITLAB_EXTERNAL_URL=https://gitlab.example.com
#
# Optional:
#
#   GITLAB_REGISTRY_EXTERNAL_URL=https://registry.example.com
#   GITLAB_TIMEZONE=America/New_York
#   GITLAB_EMAIL_FROM=gitlab@example.com
#   GITLAB_EMAIL_DISPLAY_NAME=GitLab
#   GITLAB_BACKUP_BUCKET=example-gitlab-backups
#   GITLAB_BACKUP_REGION=us-east-2
#   GITLAB_ENABLE_LETSENCRYPT=false
#   GITLAB_DATA_MOUNT=/var/opt/gitlab
#   GITLAB_LOG_MOUNT=/var/log/gitlab
#
# The script:
#
#   - Reads EC2 identity through IMDSv2
#   - Sets a stable hostname when cloud-init has not already done so
#   - Validates persistent storage
#   - Writes a managed GitLab configuration block
#   - Runs gitlab-ctl reconfigure
#   - Starts and validates GitLab
#   - Creates a completion marker
###############################################################################

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

readonly PROGRAM_NAME="$(basename "$0")"
readonly ENV_FILE="/etc/gitlab-firstboot.env"
readonly GITLAB_CONFIG="/etc/gitlab/gitlab.rb"
readonly STATE_DIRECTORY="/var/lib/gitlab-firstboot"
readonly COMPLETE_MARKER="${STATE_DIRECTORY}/complete"
readonly LOCK_FILE="/run/gitlab-firstboot.lock"
readonly LOG_FILE="/var/log/gitlab-firstboot.log"

readonly MANAGED_BLOCK_BEGIN="# BEGIN IMAGE MODE GITLAB FIRSTBOOT"
readonly MANAGED_BLOCK_END="# END IMAGE MODE GITLAB FIRSTBOOT"

###############################################################################
# Logging and error handling
###############################################################################

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
chmod 0600 "$LOG_FILE"

exec > >(tee -a "$LOG_FILE") 2>&1

log() {
    printf '%s [%s] %s\n' \
        "$(date --iso-8601=seconds)" \
        "$PROGRAM_NAME" \
        "$*"
}

fatal() {
    log "ERROR: $*"
    exit 1
}

on_error() {
    local exit_code=$?
    local line_number=${1:-unknown}

    log "ERROR: First-boot configuration failed at line ${line_number}, rc=${exit_code}."

    if command -v gitlab-ctl >/dev/null 2>&1; then
        log "GitLab service status at failure:"
        gitlab-ctl status || true
    fi

    exit "$exit_code"
}

trap 'on_error "$LINENO"' ERR

###############################################################################
# Prevent concurrent or repeated execution
###############################################################################

exec 9>"$LOCK_FILE"

if ! flock -n 9; then
    fatal "Another ${PROGRAM_NAME} process is already running."
fi

mkdir -p "$STATE_DIRECTORY"
chmod 0700 "$STATE_DIRECTORY"

if [[ -f "$COMPLETE_MARKER" ]]; then
    log "First-boot configuration is already complete."
    exit 0
fi

###############################################################################
# Load deployment-specific configuration
###############################################################################

if [[ -f "$ENV_FILE" ]]; then
    log "Loading configuration from ${ENV_FILE}."

    # shellcheck disable=SC1090
    source "$ENV_FILE"
else
    fatal "Required configuration file ${ENV_FILE} was not found."
fi

: "${GITLAB_EXTERNAL_URL:?GITLAB_EXTERNAL_URL must be defined in ${ENV_FILE}}"

GITLAB_REGISTRY_EXTERNAL_URL="${GITLAB_REGISTRY_EXTERNAL_URL:-}"
GITLAB_TIMEZONE="${GITLAB_TIMEZONE:-America/New_York}"
GITLAB_EMAIL_FROM="${GITLAB_EMAIL_FROM:-gitlab@$(hostname -f 2>/dev/null || hostname)}"
GITLAB_EMAIL_DISPLAY_NAME="${GITLAB_EMAIL_DISPLAY_NAME:-GitLab}"
GITLAB_BACKUP_BUCKET="${GITLAB_BACKUP_BUCKET:-}"
GITLAB_BACKUP_REGION="${GITLAB_BACKUP_REGION:-us-east-2}"
GITLAB_ENABLE_LETSENCRYPT="${GITLAB_ENABLE_LETSENCRYPT:-false}"
GITLAB_DATA_MOUNT="${GITLAB_DATA_MOUNT:-/var/opt/gitlab}"
GITLAB_LOG_MOUNT="${GITLAB_LOG_MOUNT:-/var/log/gitlab}"

case "$GITLAB_EXTERNAL_URL" in
    http://*|https://*)
        ;;
    *)
        fatal "GITLAB_EXTERNAL_URL must begin with http:// or https://."
        ;;
esac

if [[ -n "$GITLAB_REGISTRY_EXTERNAL_URL" ]]; then
    case "$GITLAB_REGISTRY_EXTERNAL_URL" in
        http://*|https://*)
            ;;
        *)
            fatal \
                "GITLAB_REGISTRY_EXTERNAL_URL must begin with http:// or https://."
            ;;
    esac
fi

case "${GITLAB_ENABLE_LETSENCRYPT,,}" in
    true|false)
        ;;
    *)
        fatal "GITLAB_ENABLE_LETSENCRYPT must be true or false."
        ;;
esac

###############################################################################
# Validate the immutable image contents
###############################################################################

required_commands=(
    awk
    curl
    flock
    hostnamectl
    sed
    systemctl
    gitlab-ctl
)

for required_command in "${required_commands[@]}"; do
    command -v "$required_command" >/dev/null 2>&1 ||
        fatal "Required command is missing from the image: ${required_command}"
done

[[ -f "$GITLAB_CONFIG" ]] ||
    fatal "GitLab configuration file does not exist: ${GITLAB_CONFIG}"

systemctl list-unit-files sshd.service >/dev/null 2>&1 ||
    fatal "sshd.service is not installed in the image."

###############################################################################
# Retrieve EC2 metadata using IMDSv2
###############################################################################

IMDS_BASE_URL="http://169.254.169.254/latest"
IMDS_TOKEN=""

get_imds_token() {
    curl \
        --silent \
        --show-error \
        --fail \
        --connect-timeout 2 \
        --max-time 5 \
        --request PUT \
        --header "X-aws-ec2-metadata-token-ttl-seconds: 300" \
        "${IMDS_BASE_URL}/api/token"
}

get_imds_value() {
    local path=$1

    curl \
        --silent \
        --show-error \
        --fail \
        --connect-timeout 2 \
        --max-time 5 \
        --header "X-aws-ec2-metadata-token: ${IMDS_TOKEN}" \
        "${IMDS_BASE_URL}/meta-data/${path}"
}

if IMDS_TOKEN="$(get_imds_token 2>/dev/null)"; then
    INSTANCE_ID="$(get_imds_value instance-id 2>/dev/null || true)"
    LOCAL_IPV4="$(get_imds_value local-ipv4 2>/dev/null || true)"
    LOCAL_HOSTNAME="$(get_imds_value local-hostname 2>/dev/null || true)"
    AVAILABILITY_ZONE="$(
        get_imds_value placement/availability-zone 2>/dev/null || true
    )"
    AWS_REGION="${AVAILABILITY_ZONE::-1}"

    log "EC2 instance ID: ${INSTANCE_ID:-unknown}"
    log "EC2 private IPv4: ${LOCAL_IPV4:-unknown}"
    log "EC2 availability zone: ${AVAILABILITY_ZONE:-unknown}"
else
    log "WARNING: EC2 IMDSv2 was unavailable; continuing without metadata."
    INSTANCE_ID=""
    LOCAL_IPV4=""
    LOCAL_HOSTNAME=""
    AVAILABILITY_ZONE=""
    AWS_REGION="${GITLAB_BACKUP_REGION}"
fi

###############################################################################
# Configure hostname
###############################################################################

#
# Prefer a hostname explicitly configured by Satellite/cloud-init. Only use
# the EC2 private hostname when the current hostname is generic.
#
current_hostname="$(hostname)"

case "$current_hostname" in
    localhost|localhost.localdomain|rhel|rhel.localdomain)
        if [[ -n "$LOCAL_HOSTNAME" ]]; then
            log "Setting hostname to ${LOCAL_HOSTNAME}."
            hostnamectl set-hostname "$LOCAL_HOSTNAME"
        else
            log "WARNING: No replacement hostname was available."
        fi
        ;;
    *)
        log "Preserving configured hostname ${current_hostname}."
        ;;
esac

###############################################################################
# Validate storage
###############################################################################

validate_directory() {
    local directory=$1

    mkdir -p "$directory"

    if [[ ! -w "$directory" ]]; then
        fatal "Required directory is not writable: ${directory}"
    fi
}

validate_directory "$GITLAB_DATA_MOUNT"
validate_directory "$GITLAB_LOG_MOUNT"

#
# When separate EBS volumes are required, fail rather than silently placing
# GitLab data on the root filesystem.
#
if [[ "${GITLAB_REQUIRE_DATA_MOUNT:-false}" == "true" ]]; then
    mountpoint -q "$GITLAB_DATA_MOUNT" ||
        fatal "${GITLAB_DATA_MOUNT} is not mounted on persistent storage."
fi

if [[ "${GITLAB_REQUIRE_LOG_MOUNT:-false}" == "true" ]]; then
    mountpoint -q "$GITLAB_LOG_MOUNT" ||
        fatal "${GITLAB_LOG_MOUNT} is not mounted on persistent storage."
fi

###############################################################################
# Generate GitLab configuration
###############################################################################

ruby_escape() {
    printf '%s' "$1" | sed \
        -e 's/\\/\\\\/g' \
        -e "s/'/\\\\'/g"
}

escaped_external_url="$(ruby_escape "$GITLAB_EXTERNAL_URL")"
escaped_timezone="$(ruby_escape "$GITLAB_TIMEZONE")"
escaped_email_from="$(ruby_escape "$GITLAB_EMAIL_FROM")"
escaped_email_display_name="$(ruby_escape "$GITLAB_EMAIL_DISPLAY_NAME")"
escaped_backup_bucket="$(ruby_escape "$GITLAB_BACKUP_BUCKET")"
escaped_backup_region="$(ruby_escape "$GITLAB_BACKUP_REGION")"
escaped_registry_url="$(ruby_escape "$GITLAB_REGISTRY_EXTERNAL_URL")"

temporary_config="$(mktemp)"
temporary_block="$(mktemp)"

cleanup() {
    rm -f "$temporary_config" "$temporary_block"
}

trap cleanup EXIT

#
# Remove a block created by an earlier incomplete execution.
#
awk \
    -v begin="$MANAGED_BLOCK_BEGIN" \
    -v end="$MANAGED_BLOCK_END" '
        $0 == begin {
            managed = 1
            next
        }

        $0 == end {
            managed = 0
            next
        }

        !managed {
            print
        }
    ' "$GITLAB_CONFIG" > "$temporary_config"

cat > "$temporary_block" <<EOF
${MANAGED_BLOCK_BEGIN}

external_url '${escaped_external_url}'

gitlab_rails['time_zone'] = '${escaped_timezone}'
gitlab_rails['gitlab_email_from'] = '${escaped_email_from}'
gitlab_rails['gitlab_email_display_name'] = '${escaped_email_display_name}'

letsencrypt['enable'] = ${GITLAB_ENABLE_LETSENCRYPT,,}

# Trust the AWS private network and local reverse proxy headers as appropriate.
nginx['listen_port'] = 443
nginx['listen_https'] = true

# Preserve application data outside the immutable /usr filesystem.
git_data_dirs({
  'default' => {
    'path' => '${GITLAB_DATA_MOUNT}/git-data'
  }
})

# EC2 identity captured during first boot:
# Instance ID: ${INSTANCE_ID:-unknown}
# Region: ${AWS_REGION:-unknown}

EOF

if [[ -n "$GITLAB_REGISTRY_EXTERNAL_URL" ]]; then
    cat >> "$temporary_block" <<EOF
registry_external_url '${escaped_registry_url}'
gitlab_rails['registry_enabled'] = true

EOF
fi

if [[ -n "$GITLAB_BACKUP_BUCKET" ]]; then
    cat >> "$temporary_block" <<EOF
gitlab_rails['backup_upload_connection'] = {
  'provider' => 'AWS',
  'region' => '${escaped_backup_region}',
  'use_iam_profile' => true
}

gitlab_rails['backup_upload_remote_directory'] = '${escaped_backup_bucket}'

EOF
fi

cat >> "$temporary_block" <<EOF
${MANAGED_BLOCK_END}
EOF

{
    cat "$temporary_config"
    printf '\n'
    cat "$temporary_block"
    printf '\n'
} > "${GITLAB_CONFIG}.new"

chown root:root "${GITLAB_CONFIG}.new"
chmod 0600 "${GITLAB_CONFIG}.new"
mv -f "${GITLAB_CONFIG}.new" "$GITLAB_CONFIG"

log "Updated ${GITLAB_CONFIG}."

###############################################################################
# Enable required services
###############################################################################

systemctl enable sshd.service
systemctl start sshd.service

#
# cloud-init itself normally starts this script. Do not restart cloud-init here.
#
if systemctl list-unit-files gitlab-runsvdir.service >/dev/null 2>&1; then
    systemctl enable gitlab-runsvdir.service
fi

###############################################################################
# Apply GitLab configuration
###############################################################################

log "Running gitlab-ctl reconfigure."
gitlab-ctl reconfigure

log "Starting GitLab services."
gitlab-ctl start

###############################################################################
# Validate GitLab
###############################################################################

log "Waiting for GitLab services to become healthy."

health_check_attempts=60
health_check_delay=10

for ((attempt = 1; attempt <= health_check_attempts; attempt++)); do
    if gitlab-ctl status >/dev/null 2>&1; then
        if curl \
            --silent \
            --show-error \
            --fail \
            --insecure \
            --connect-timeout 5 \
            --max-time 15 \
            "${GITLAB_EXTERNAL_URL%/}/-/health" >/dev/null; then

            log "GitLab health endpoint is responding."
            break
        fi
    fi

    if (( attempt == health_check_attempts )); then
        log "GitLab service status:"
        gitlab-ctl status || true
        fatal "GitLab did not become healthy."
    fi

    log \
        "GitLab is not ready; attempt ${attempt}/${health_check_attempts}."
    sleep "$health_check_delay"
done

###############################################################################
# Mark completion
###############################################################################

cat > "$COMPLETE_MARKER" <<EOF
completed_at=$(date --iso-8601=seconds)
instance_id=${INSTANCE_ID}
availability_zone=${AVAILABILITY_ZONE}
region=${AWS_REGION}
external_url=${GITLAB_EXTERNAL_URL}
EOF

chmod 0600 "$COMPLETE_MARKER"

log "GitLab first-boot configuration completed successfully."
