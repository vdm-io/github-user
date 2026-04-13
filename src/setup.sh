#!/usr/bin/env bash
#
# setup-git.sh — Securely configure Git, GPG signing, and SSH for automated environments.
#
# Usage:
#   ./setup-git.sh \
#     --gpg-key "$GPG_KEY" \
#     --gpg-user "$GPG_USER" \
#     --ssh-key "$SSH_KEY" \
#     --ssh-pub "$SSH_PUB" \
#     --git-user "$GIT_USER" \
#     --git-email "$GIT_EMAIL" \
#     [--git-token "$GIT_TOKEN"] \
#     [--ssh-type ed25519|rsa|ecdsa] \
#     [--ssh-host github.com] \
#     [--force]
#
# Behavior:
# - First run:  configures everything, locks secret files to chmod 400.
# - Same user:  detects matching SSH key, skips setup, verifies health.
# - Diff user:  refuses unless --force is passed, then reconfigures.
#
# Notes:
# - Designed for CI, containers, and other automated environments.
# - Avoids writing the GPG private key to disk (piped directly to gpg).
# - Validates the SSH private/public key pair match.
# - Configures strict SSH host key checking.
#

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

# ──────────────────────────────────────────────
# Globals
# ──────────────────────────────────────────────
readonly SCRIPT_NAME="$(basename "$0")"

GPG_KEY=""
GPG_USER=""
SSH_KEY=""
SSH_PUB=""
SSH_TYPE="ed25519"
SSH_HOST="github.com"
GIT_USER=""
GIT_EMAIL=""
GIT_TOKEN=""
SIGNKEY=""
FORCE=false

TMP_DIR=""
SSH_KEY_FILE=""
SSH_PUB_FILE=""
KNOWN_HOSTS_FILE="${HOME}/.ssh/known_hosts"
SSH_CONFIG_FILE="${HOME}/.ssh/config"
TOKEN_DIR="${HOME}/.github"
TOKEN_FILE="${HOME}/.github/personal.access.token"

# ──────────────────────────────────────────────
# Logging helpers
# ──────────────────────────────────────────────
log_info() {
	printf '[INFO]  %s\n' "$*" >&2
}

log_warn() {
	printf '[WARN]  %s\n' "$*" >&2
}

log_error() {
	printf '[ERROR] %s\n' "$*" >&2
}

fail() {
	log_error "$*"
	exit 1
}

# ──────────────────────────────────────────────
# Cleanup — always remove the temp directory
# ──────────────────────────────────────────────
cleanup() {
	local exit_code=$?

	if [[ -n "${TMP_DIR}" && -d "${TMP_DIR}" ]]; then
		rm -rf "${TMP_DIR}"
	fi

	exit "${exit_code}"
}
trap cleanup EXIT

# ──────────────────────────────────────────────
# Dependency check
# ──────────────────────────────────────────────
require_cmd() {
	command -v "$1" >/dev/null 2>&1 || fail "Required command '$1' not found."
}

require_cmd gpg
require_cmd git
require_cmd ssh
require_cmd ssh-keygen
require_cmd ssh-keyscan
require_cmd awk
require_cmd grep
require_cmd sort
require_cmd mktemp

# ──────────────────────────────────────────────
# Usage
# ──────────────────────────────────────────────
usage() {
	cat >&2 <<EOF
Usage:
  ${SCRIPT_NAME} --gpg-key VALUE --gpg-user VALUE --ssh-key VALUE \\
                 --ssh-pub VALUE --git-user VALUE --git-email VALUE [OPTIONS]

Required:
  --gpg-key VALUE     ASCII-armored GPG private key
  --gpg-user VALUE    GPG user ID (name or email) to locate the signing key
  --ssh-key VALUE     SSH private key content
  --ssh-pub VALUE     SSH public key content
  --git-user VALUE    Git commit author name
  --git-email VALUE   Git commit author email

Optional:
  --git-token VALUE   GitHub personal access token (stored for CLI use)
  --ssh-type VALUE    Key type: ed25519, rsa, ecdsa (default: ed25519)
  --ssh-host VALUE    SSH host to configure (default: github.com)
  --force             Overwrite an existing configuration for a different user
  -h, --help          Show this help
EOF
	exit 1
}

die_missing() {
	fail "\"--$1\" requires a non-empty option argument."
}

# ──────────────────────────────────────────────
# Argument parsing
# ──────────────────────────────────────────────
parse_args() {
	while (($# > 0)); do
		case "${1:-}" in
			--gpg-key)
				[[ -n "${2:-}" ]] || die_missing gpg-key
				GPG_KEY="$2"
				shift 2
				;;
			--gpg-key=?*)
				GPG_KEY="${1#*=}"
				shift
				;;
			--gpg-key=)
				die_missing gpg-key
				;;

			--gpg-user)
				[[ -n "${2:-}" ]] || die_missing gpg-user
				GPG_USER="$2"
				shift 2
				;;
			--gpg-user=?*)
				GPG_USER="${1#*=}"
				shift
				;;
			--gpg-user=)
				die_missing gpg-user
				;;

			--ssh-key)
				[[ -n "${2:-}" ]] || die_missing ssh-key
				SSH_KEY="$2"
				shift 2
				;;
			--ssh-key=?*)
				SSH_KEY="${1#*=}"
				shift
				;;
			--ssh-key=)
				die_missing ssh-key
				;;

			--ssh-pub)
				[[ -n "${2:-}" ]] || die_missing ssh-pub
				SSH_PUB="$2"
				shift 2
				;;
			--ssh-pub=?*)
				SSH_PUB="${1#*=}"
				shift
				;;
			--ssh-pub=)
				die_missing ssh-pub
				;;

			--ssh-type)
				[[ -n "${2:-}" ]] || die_missing ssh-type
				SSH_TYPE="$2"
				shift 2
				;;
			--ssh-type=?*)
				SSH_TYPE="${1#*=}"
				shift
				;;
			--ssh-type=)
				die_missing ssh-type
				;;

			--ssh-host)
				[[ -n "${2:-}" ]] || die_missing ssh-host
				SSH_HOST="$2"
				shift 2
				;;
			--ssh-host=?*)
				SSH_HOST="${1#*=}"
				shift
				;;
			--ssh-host=)
				die_missing ssh-host
				;;

			--git-user)
				[[ -n "${2:-}" ]] || die_missing git-user
				GIT_USER="$2"
				shift 2
				;;
			--git-user=?*)
				GIT_USER="${1#*=}"
				shift
				;;
			--git-user=)
				die_missing git-user
				;;

			--git-email)
				[[ -n "${2:-}" ]] || die_missing git-email
				GIT_EMAIL="$2"
				shift 2
				;;
			--git-email=?*)
				GIT_EMAIL="${1#*=}"
				shift
				;;
			--git-email=)
				die_missing git-email
				;;

			--git-token)
				[[ $# -ge 2 ]] || die_missing git-token
				GIT_TOKEN="$2"
				shift 2
				;;
			--git-token=?*)
				GIT_TOKEN="${1#*=}"
				shift
				;;
			--git-token=)
				GIT_TOKEN=""
				shift
				;;

			--force)
				FORCE=true
				shift
				;;

			-h|--help)
				usage
				;;

			--)
				shift
				break
				;;

			# Backward compatibility: warn on unknown options instead of failing.
			# The original script silently ignored unknown flags via *) break.
			# Wrapper scripts may pass extra options that this script doesn't handle.
			-?*|--?*)
				log_warn "Unknown option ignored: $1"
				shift
				;;

			*)
				break
				;;
		esac
	done
}

# ──────────────────────────────────────────────
# Validation — all checks before any filesystem writes
# ──────────────────────────────────────────────
validate_args() {
	local missing=()

	case "${SSH_TYPE}" in
		ed25519|rsa|ecdsa) ;;
		*) fail "Unsupported --ssh-type '${SSH_TYPE}'. Use: ed25519, rsa, or ecdsa." ;;
	esac

	[[ -n "${GPG_KEY}" ]]   || missing+=("GPG_KEY (--gpg-key)")
	[[ -n "${GPG_USER}" ]]  || missing+=("GPG_USER (--gpg-user)")
	[[ -n "${SSH_KEY}" ]]   || missing+=("SSH_KEY (--ssh-key)")
	[[ -n "${SSH_PUB}" ]]   || missing+=("SSH_PUB (--ssh-pub)")
	[[ -n "${GIT_USER}" ]]  || missing+=("GIT_USER (--git-user)")
	[[ -n "${GIT_EMAIL}" ]] || missing+=("GIT_EMAIL (--git-email)")

	if ((${#missing[@]} > 0)); then
		log_error "Missing required arguments:"
		for item in "${missing[@]}"; do
			log_error "  - ${item}"
		done
		exit 1
	fi
}

# ──────────────────────────────────────────────
# Environment preparation
# ──────────────────────────────────────────────
prepare_environment() {
	TMP_DIR="$(mktemp -d)"
	mkdir -p "${HOME}/.ssh" "${HOME}/.gnupg" "${TOKEN_DIR}"
	chmod 700 "${HOME}/.ssh" "${HOME}/.gnupg" "${TOKEN_DIR}"

	SSH_KEY_FILE="${HOME}/.ssh/id_${SSH_TYPE}"
	SSH_PUB_FILE="${HOME}/.ssh/id_${SSH_TYPE}.pub"
}

# ──────────────────────────────────────────────
# Existing setup detection
#
# Returns:
#   0 — no existing setup found, proceed with fresh install
#   Exits 0 — same user already configured, nothing to do
#   Exits 1 — different user, --force required
# ──────────────────────────────────────────────
check_existing_setup() {
	# No SSH key file means this is a fresh environment — proceed
	if [[ ! -f "${SSH_KEY_FILE}" ]]; then
		return 0
	fi

	log_info "Existing SSH key found at ${SSH_KEY_FILE}."

	# Derive the public key from the existing private key on disk and
	# compare it against the public key we were given as an argument.
	local existing_key_material provided_key_material
	existing_key_material="$(ssh-keygen -y -f "${SSH_KEY_FILE}" 2>/dev/null | awk '{print $1, $2}')" || true
	provided_key_material="$(printf '%s' "${SSH_PUB}" | awk '{print $1, $2}')"

	if [[ "${existing_key_material}" == "${provided_key_material}" ]]; then
		# Same user — already configured. Verify health and exit.
		log_info "Configuration matches the provided credentials. Verifying..."
		resolve_signing_key
		configure_gpg_tty
		run_smoke_tests
		log_info "Already configured. No changes needed."
		exit 0
	fi

	# Different user detected
	if [[ "${FORCE}" == "true" ]]; then
		log_warn "Existing setup is for a different user. Reconfiguring (--force)."
		# Remove the protected files so the fresh install can write them
		rm -f "${SSH_KEY_FILE}" "${SSH_PUB_FILE}" "${TOKEN_FILE}"
		return 0
	fi

	fail "Already configured for a different user. Use --force to reconfigure."
}

# ──────────────────────────────────────────────
# GPG setup
# ──────────────────────────────────────────────
import_gpg_key() {
	log_info "Importing GPG private key..."

	if ! printf '%s\n' "${GPG_KEY}" | gpg --batch --quiet --import 2>/dev/null; then
		# Some GPG versions return non-zero when re-importing a key that
		# is already in the keyring ("not changed"). Verify the key is
		# actually present before treating this as a failure.
		if gpg --batch --list-secret-keys "${GPG_USER}" >/dev/null 2>&1; then
			log_info "GPG key already present in keyring."
		else
			fail "GPG key import failed. Ensure --gpg-key contains a valid ASCII-armored private key."
		fi
	fi
}

resolve_signing_key() {
	log_info "Resolving GPG signing key for '${GPG_USER}'..."

	SIGNKEY="$(
		gpg --batch --with-colons --list-secret-keys "${GPG_USER}" 2>/dev/null \
		| awk -F: '$1 == "sec" { print $5; exit }'
	)"

	[[ -n "${SIGNKEY}" ]] || fail "Could not find a secret GPG signing key matching '${GPG_USER}'."

	log_info "Using GPG signing key: ${SIGNKEY}"
}

# ──────────────────────────────────────────────
# SSH setup
# ──────────────────────────────────────────────
write_ssh_keys() {
	log_info "Writing SSH keypair (${SSH_TYPE})..."

	# At this point the key files must not exist. Either this is a fresh
	# environment, or --force already removed them in check_existing_setup.
	# If they somehow still exist (chmod 400), the write will fail — that
	# is intentional. Protected files should not be silently overwritten.
	printf '%s\n' "${SSH_KEY}" > "${SSH_KEY_FILE}"
	printf '%s\n' "${SSH_PUB}" > "${SSH_PUB_FILE}"

	# Lock the files: read-only for owner, no access for anyone else.
	chmod 400 "${SSH_KEY_FILE}"
	chmod 400 "${SSH_PUB_FILE}"
}

validate_ssh_keypair() {
	log_info "Validating SSH keypair match..."

	# Derive the public key from the private key to verify they belong together.
	local derived_public
	derived_public="$(ssh-keygen -y -f "${SSH_KEY_FILE}" 2>/dev/null)" \
		|| fail "SSH private key is invalid or unreadable."

	# ssh-keygen -y outputs:  "type base64data"          (no comment)
	# Provided pub key has:   "type base64data comment"   (with comment)
	# Compare only the key type and key material (fields 1+2), ignoring the
	# trailing comment so that valid keypairs with comments aren't rejected.
	local derived_fields provided_fields
	derived_fields="$(printf '%s' "${derived_public}" | awk '{print $1, $2}')"
	provided_fields="$(printf '%s' "${SSH_PUB}" | awk '{print $1, $2}')"

	if [[ "${derived_fields}" != "${provided_fields}" ]]; then
		fail "Provided SSH public key does not match the provided private key."
	fi
}

update_known_hosts() {
	log_info "Fetching SSH host keys for ${SSH_HOST}..."

	local scanned_file="${TMP_DIR}/known_hosts.scan"
	touch "${KNOWN_HOSTS_FILE}"

	if ! ssh-keyscan -H -t rsa,ecdsa,ed25519 "${SSH_HOST}" > "${scanned_file}" 2>/dev/null; then
		fail "ssh-keyscan failed for ${SSH_HOST}."
	fi

	[[ -s "${scanned_file}" ]] || fail "No SSH host keys received from ${SSH_HOST}."

	# Merge scanned keys with existing known_hosts, deduplicate, write back.
	cat "${scanned_file}" "${KNOWN_HOSTS_FILE}" | sort -u > "${TMP_DIR}/known_hosts.merged"
	cp "${TMP_DIR}/known_hosts.merged" "${KNOWN_HOSTS_FILE}"
	chmod 644 "${KNOWN_HOSTS_FILE}"
}

replace_managed_ssh_block() {
	log_info "Updating SSH config block for ${SSH_HOST}..."

	local start_marker="# --- BEGIN managed by setup-git.sh (${SSH_HOST}) ---"
	local end_marker="# --- END managed by setup-git.sh (${SSH_HOST}) ---"
	local new_block="${TMP_DIR}/ssh_config.block"
	local existing="${TMP_DIR}/ssh_config.existing"
	local cleaned="${TMP_DIR}/ssh_config.cleaned"

	# Write the managed block to a temp file. No indentation so the markers
	# are matched exactly by the awk cleaner on subsequent runs.
	cat > "${new_block}" <<EOF
${start_marker}
Host ${SSH_HOST}
    HostName ${SSH_HOST}
    User git
    IdentityFile ${SSH_KEY_FILE}
    IdentitiesOnly yes
    StrictHostKeyChecking yes
    UserKnownHostsFile ${KNOWN_HOSTS_FILE}
    LogLevel ERROR
${end_marker}
EOF

	if [[ -f "${SSH_CONFIG_FILE}" ]]; then
		cp "${SSH_CONFIG_FILE}" "${existing}"
		# Remove any previous managed block for this host.
		awk -v start="${start_marker}" -v end="${end_marker}" '
			$0 == start { skip=1; next }
			$0 == end   { skip=0; next }
			!skip       { print }
		' "${existing}" > "${cleaned}"
	else
		: > "${cleaned}"
	fi

	{
		cat "${cleaned}"
		printf '\n'
		cat "${new_block}"
		printf '\n'
	} > "${SSH_CONFIG_FILE}"

	chmod 600 "${SSH_CONFIG_FILE}"
}

# ──────────────────────────────────────────────
# Token storage
# ──────────────────────────────────────────────
store_git_token() {
	# Always create the token file — even when the value is empty — so that
	# downstream scripts checking [ -f ~/.github/personal.access.token ]
	# continue to work. This matches the original script's behavior.
	#
	# The file must not already exist at this point. Either this is a fresh
	# install, or --force removed it in check_existing_setup.
	log_info "Storing Git token..."

	printf '%s\n' "${GIT_TOKEN}" > "${TOKEN_FILE}"
	chmod 400 "${TOKEN_FILE}"

	if [[ -z "${GIT_TOKEN}" ]]; then
		log_warn "Git token is empty. Token file created but contains no token."
	fi
}

# ──────────────────────────────────────────────
# Git configuration
# ──────────────────────────────────────────────
configure_git() {
	log_info "Configuring Git..."

	git config --global user.name "${GIT_USER}"
	git config --global user.email "${GIT_EMAIL}"
	git config --global user.signingkey "${SIGNKEY}"
	git config --global commit.gpgsign true
	git config --global tag.gpgSign true

	# Use bare command name so $PATH resolves it at runtime. Avoids breakage
	# if the gpg binary path changes between container image updates.
	git config --global gpg.program gpg

	git config --global gpg.format openpgp
	git config --global core.sshCommand "ssh -F ${SSH_CONFIG_FILE}"
}

# ──────────────────────────────────────────────
# Runtime environment
# ──────────────────────────────────────────────
configure_gpg_tty() {
	if [[ -t 0 || -t 1 || -t 2 ]]; then
		export GPG_TTY
		GPG_TTY="$(tty)"
	else
		log_warn "No TTY detected. Skipping GPG_TTY export."
	fi
}

# ──────────────────────────────────────────────
# Smoke tests — verify the configuration is usable by git
# ──────────────────────────────────────────────
run_smoke_tests() {
	log_info "Running smoke tests..."

	local failures=0

	# GPG secret key is present
	if gpg --batch --list-secret-keys "${GPG_USER}" >/dev/null 2>&1; then
		log_info "  GPG secret key: OK"
	else
		log_warn "  GPG secret key: FAILED"
		((failures++)) || true
	fi

	# GPG can produce a signature
	if printf 'test' | gpg --batch --armor --local-user "${SIGNKEY}" --sign >/dev/null 2>&1; then
		log_info "  GPG signing:    OK"
	else
		log_warn "  GPG signing:    FAILED (may require pinentry/passphrase access)"
		((failures++)) || true
	fi

	# SSH public key is valid
	if ssh-keygen -l -f "${SSH_PUB_FILE}" >/dev/null 2>&1; then
		log_info "  SSH public key: OK"
	else
		log_warn "  SSH public key: FAILED"
		((failures++)) || true
	fi

	# Git signing key matches what we set
	local configured_key
	configured_key="$(git config --global user.signingkey 2>/dev/null || true)"
	if [[ "${configured_key}" == "${SIGNKEY}" ]]; then
		log_info "  Git signingkey: OK"
	else
		log_warn "  Git signingkey: FAILED (expected '${SIGNKEY}', got '${configured_key}')"
		((failures++)) || true
	fi

	# SSH key file is readable
	if [[ -r "${SSH_KEY_FILE}" ]]; then
		log_info "  SSH key access: OK"
	else
		log_warn "  SSH key access: FAILED (${SSH_KEY_FILE} not readable)"
		((failures++)) || true
	fi

	# known_hosts is populated (entries are hashed so we just check non-empty)
	if [[ -s "${KNOWN_HOSTS_FILE}" ]]; then
		log_info "  Known hosts:    OK"
	else
		log_warn "  Known hosts:    FAILED (empty or missing)"
		((failures++)) || true
	fi

	# Token file exists (even if empty, downstream scripts may check -f)
	if [[ -f "${TOKEN_FILE}" ]]; then
		log_info "  Token file:     OK"
	else
		log_warn "  Token file:     FAILED (not found)"
		((failures++)) || true
	fi

	if ((failures > 0)); then
		log_warn "Smoke tests completed with ${failures} warning(s)."
	else
		log_info "All smoke tests passed."
	fi
}

# ──────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────
main() {
	parse_args "$@"
	validate_args
	prepare_environment
	check_existing_setup
	import_gpg_key
	resolve_signing_key
	write_ssh_keys
	validate_ssh_keypair
	update_known_hosts
	replace_managed_ssh_block
	store_git_token
	configure_git
	configure_gpg_tty
	run_smoke_tests

	log_info "Setup complete."
}

main "$@"
