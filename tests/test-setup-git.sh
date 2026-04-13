#!/usr/bin/env bash
#
# test-setup-git.sh — Test harness for setup-git.sh
#
# Generates real GPG and SSH keys, runs the setup script, and verifies that
# git operations (init, commit, sign, tag) actually work afterward.
#
# The test suite mocks ssh-keyscan so it can run in offline / sandboxed
# environments (CI containers, air-gapped machines, etc.).
#
# Usage:
#   ./test-setup-git.sh [path/to/setup-git.sh]
#
# Exit codes:
#   0  All tests passed
#   1  One or more tests failed
#

set -Euo pipefail
IFS=$'\n\t'

# ──────────────────────────────────────────────
# Configuration
# ──────────────────────────────────────────────
SETUP_SCRIPT="${1:-./setup-git.sh}"
TEST_USER="Test Robot"
TEST_EMAIL="robot@test.local"
TEST_TOKEN="ghp_fake_token_for_testing_1234567890ab"

# Second user for force/rejection tests
TEST_USER_B="Other Robot"
TEST_EMAIL_B="other@test.local"

# Counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Scratch space — completely isolated from the real HOME
TEST_ROOT=""
REAL_HOME="${HOME}"

# ──────────────────────────────────────────────
# Logging / assertions
# ──────────────────────────────────────────────
_red()   { printf '\033[1;31m%s\033[0m' "$*"; }
_green() { printf '\033[1;32m%s\033[0m' "$*"; }
_bold()  { printf '\033[1m%s\033[0m' "$*"; }

log_section() {
	printf '\n%s\n' "── $(_bold "$*") ──"
}

pass() {
	((TESTS_RUN++))  || true
	((TESTS_PASSED++)) || true
	printf '  %s %s\n' "$(_green "PASS")" "$*"
}

fail_test() {
	((TESTS_RUN++))  || true
	((TESTS_FAILED++)) || true
	printf '  %s %s\n' "$(_red "FAIL")" "$*"
}

assert_eq() {
	local description="$1" expected="$2" actual="$3"
	if [[ "${expected}" == "${actual}" ]]; then
		pass "${description}"
	else
		fail_test "${description}"
		printf '         expected: %s\n' "${expected}"
		printf '         actual:   %s\n' "${actual}"
	fi
}

assert_ne() {
	local description="$1" not_expected="$2" actual="$3"
	if [[ "${not_expected}" != "${actual}" ]]; then
		pass "${description}"
	else
		fail_test "${description} (should NOT be '${not_expected}')"
	fi
}

assert_file_exists() {
	local description="$1" filepath="$2"
	if [[ -f "${filepath}" ]]; then
		pass "${description}"
	else
		fail_test "${description} (file not found: ${filepath})"
	fi
}

assert_file_not_exists() {
	local description="$1" filepath="$2"
	if [[ ! -f "${filepath}" ]]; then
		pass "${description}"
	else
		fail_test "${description} (file should not exist: ${filepath})"
	fi
}

assert_file_contains() {
	local description="$1" filepath="$2" pattern="$3"
	if grep -qF -- "${pattern}" "${filepath}" 2>/dev/null; then
		pass "${description}"
	else
		fail_test "${description} (pattern '${pattern}' not found in ${filepath})"
	fi
}

assert_perm() {
	local description="$1" filepath="$2" expected_perm="$3"
	local actual_perm
	actual_perm="$(stat -c '%a' "${filepath}" 2>/dev/null || echo "MISSING")"
	if [[ "${actual_perm}" == "${expected_perm}" ]]; then
		pass "${description}"
	else
		fail_test "${description} (expected ${expected_perm}, got ${actual_perm})"
	fi
}

assert_dir_perm() {
	assert_perm "$@"
}

assert_exit_code() {
	local description="$1" expected_code="$2"
	shift 2
	local actual_code=0
	"$@" >/dev/null 2>&1 || actual_code=$?
	if [[ "${actual_code}" == "${expected_code}" ]]; then
		pass "${description}"
	else
		fail_test "${description} (expected exit ${expected_code}, got ${actual_code})"
	fi
}

assert_exit_nonzero() {
	local description="$1"
	shift
	local actual_code=0
	"$@" >/dev/null 2>&1 || actual_code=$?
	if [[ "${actual_code}" -ne 0 ]]; then
		pass "${description}"
	else
		fail_test "${description} (expected non-zero exit, got 0)"
	fi
}

assert_output_contains() {
	local description="$1" pattern="$2"
	shift 2
	local output
	output="$("$@" 2>&1)" || true
	if printf '%s' "${output}" | grep -qF -- "${pattern}"; then
		pass "${description}"
	else
		fail_test "${description} (pattern '${pattern}' not in output)"
		printf '         output: %.200s\n' "${output}"
	fi
}

# ──────────────────────────────────────────────
# Mock ssh-keyscan
#
# ssh-keyscan requires network access to the target host, which is
# unavailable in sandboxed CI or test environments. This mock produces
# valid-looking known_hosts output for any host requested.
# ──────────────────────────────────────────────
create_mock_ssh_keyscan() {
	local mock_bin_dir="${TEST_ROOT}/mock_bin"
	mkdir -p "${mock_bin_dir}"

	cat > "${mock_bin_dir}/ssh-keyscan" <<'MOCK_EOF'
#!/usr/bin/env bash
# Mock ssh-keyscan — produces valid-format known_hosts entries.
host=""
hash_flag=""
while (($# > 0)); do
    case "$1" in
        -H) hash_flag=1; shift ;;
        -t) shift 2 ;;
        -p) shift 2 ;;
        -*) shift ;;
        *)  host="$1"; shift ;;
    esac
done
[[ -n "${host}" ]] || exit 1
if [[ -n "${hash_flag}" ]]; then
    local_hash="|1|AAAAAAAAAAAAAAAAAAAAAAAAAAAA|BBBBBBBBBBBBBBBBBBBBBBBBBBBB"
    printf '%s ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMockHostKeyEd25519ForTestingPurposesOnly00000000000\n' "${local_hash}"
    printf '%s ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQDMockRSAHostKeyForTestingPurposesOnlyxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx==\n' "${local_hash}"
    printf '%s ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBMockECDSAHostKeyForTestingPurposesOnlyxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx==\n' "${local_hash}"
else
    printf '%s ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMockHostKeyEd25519ForTestingPurposesOnly00000000000\n' "${host}"
    printf '%s ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQDMockRSAHostKeyForTestingPurposesOnlyxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx==\n' "${host}"
    printf '%s ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBMockECDSAHostKeyForTestingPurposesOnlyxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx==\n' "${host}"
fi
exit 0
MOCK_EOF

	chmod +x "${mock_bin_dir}/ssh-keyscan"
	export PATH="${mock_bin_dir}:${PATH}"
}

# ──────────────────────────────────────────────
# Test environment setup / teardown
# ──────────────────────────────────────────────
create_test_environment() {
	TEST_ROOT="$(mktemp -d)"
	export HOME="${TEST_ROOT}/fakehome"
	export GNUPGHOME="${HOME}/.gnupg"
	mkdir -p "${HOME}"

	create_mock_ssh_keyscan
}

destroy_test_environment() {
	export HOME="${REAL_HOME}"
	if [[ -n "${TEST_ROOT}" && -d "${TEST_ROOT}" ]]; then
		rm -rf "${TEST_ROOT}"
	fi
}

# Reset HOME to a clean state for tests that need a fresh start
reset_home() {
	rm -rf "${HOME}"
	mkdir -p "${HOME}"
	mkdir -p "${GNUPGHOME}"
	chmod 700 "${GNUPGHOME}"
}

# ──────────────────────────────────────────────
# Key generation helpers
# ──────────────────────────────────────────────
generate_gpg_key() {
	local user_name="$1" user_email="$2"

	gpg --batch --quiet --gen-key <<EOF
%no-protection
Key-Type: eddsa
Key-Curve: ed25519
Subkey-Type: eddsa
Subkey-Curve: ed25519
Name-Real: ${user_name}
Name-Email: ${user_email}
Expire-Date: 0
%commit
EOF
}

export_gpg_private_key() {
	local user_email="$1"
	gpg --batch --armor --export-secret-keys "${user_email}" 2>/dev/null
}

generate_ssh_keypair() {
	local key_file="$1" key_type="${2:-ed25519}" comment="${3:-test@test}"
	ssh-keygen -t "${key_type}" -f "${key_file}" -N "" -C "${comment}" -q
}

# Run setup-git.sh with standard test arguments for user A
run_setup() {
	local gpg_key="$1" ssh_priv="$2" ssh_pub="$3"
	shift 3
	bash "${SETUP_SCRIPT}" \
		--gpg-key "${gpg_key}" \
		--gpg-user "${TEST_EMAIL}" \
		--ssh-key "${ssh_priv}" \
		--ssh-pub "${ssh_pub}" \
		--git-user "${TEST_USER}" \
		--git-email "${TEST_EMAIL}" \
		--git-token "${TEST_TOKEN}" \
		"$@"
}

# Generate all test keys and wipe GPG so setup-git.sh imports fresh.
# Sets: GPG_KEY_EXPORT, SSH_PRIV, SSH_PUB
prepare_keys() {
	local key_type="${1:-ed25519}" key_dir="${2:-${TEST_ROOT}/keys_default}"
	local user_name="${3:-${TEST_USER}}" user_email="${4:-${TEST_EMAIL}}"

	mkdir -p "${key_dir}"
	generate_gpg_key "${user_name}" "${user_email}"
	GPG_KEY_EXPORT="$(export_gpg_private_key "${user_email}")"

	generate_ssh_keypair "${key_dir}/id_${key_type}" "${key_type}" "${user_email}"
	SSH_PRIV="$(cat "${key_dir}/id_${key_type}")"
	SSH_PUB="$(cat "${key_dir}/id_${key_type}.pub")"

	# Wipe GPG so setup-git.sh does a clean import
	rm -rf "${GNUPGHOME}"
	mkdir -p "${GNUPGHOME}"
	chmod 700 "${GNUPGHOME}"
}

# ──────────────────────────────────────────────
# TEST SUITES
# ──────────────────────────────────────────────

test_prerequisites() {
	log_section "Prerequisites"

	if [[ -f "${SETUP_SCRIPT}" && -r "${SETUP_SCRIPT}" ]]; then
		pass "Setup script exists and is readable"
	else
		fail_test "Setup script not found: ${SETUP_SCRIPT}"
		printf '\n%s\n' "$(_red "Cannot continue without the setup script.")"
		exit 1
	fi

	for cmd in gpg git ssh-keygen awk grep sort mktemp stat; do
		if command -v "${cmd}" >/dev/null 2>&1; then
			pass "Command available: ${cmd}"
		else
			fail_test "Command missing: ${cmd}"
		fi
	done

	local keyscan_path
	keyscan_path="$(command -v ssh-keyscan 2>/dev/null || echo "")"
	if [[ "${keyscan_path}" == *"mock_bin"* ]]; then
		pass "Mock ssh-keyscan active (offline testing)"
	elif [[ -n "${keyscan_path}" ]]; then
		pass "Real ssh-keyscan available"
	else
		fail_test "ssh-keyscan not available"
	fi
}

test_argument_validation() {
	log_section "Argument validation"

	reset_home
	prepare_keys "ed25519" "${TEST_ROOT}/keys_argtest"

	# Missing all required args
	assert_exit_nonzero \
		"Fails with no arguments" \
		bash "${SETUP_SCRIPT}"

	# Missing individual required args
	assert_exit_nonzero \
		"Fails when --gpg-key is missing" \
		bash "${SETUP_SCRIPT}" \
		--gpg-user "${TEST_EMAIL}" \
		--ssh-key "${SSH_PRIV}" --ssh-pub "${SSH_PUB}" \
		--git-user "${TEST_USER}" --git-email "${TEST_EMAIL}"

	assert_exit_nonzero \
		"Fails when --git-email is missing" \
		bash "${SETUP_SCRIPT}" \
		--gpg-key "${GPG_KEY_EXPORT}" --gpg-user "${TEST_EMAIL}" \
		--ssh-key "${SSH_PRIV}" --ssh-pub "${SSH_PUB}" \
		--git-user "${TEST_USER}"

	assert_exit_nonzero \
		"Fails when --ssh-key is missing" \
		bash "${SETUP_SCRIPT}" \
		--gpg-key "${GPG_KEY_EXPORT}" --gpg-user "${TEST_EMAIL}" \
		--ssh-pub "${SSH_PUB}" \
		--git-user "${TEST_USER}" --git-email "${TEST_EMAIL}"

	# Empty value forms
	assert_exit_nonzero \
		"Fails on --gpg-key= (empty)" \
		bash "${SETUP_SCRIPT}" --gpg-key=

	assert_exit_nonzero \
		"Fails on --ssh-key= (empty)" \
		bash "${SETUP_SCRIPT}" --ssh-key=

	# Invalid SSH type
	assert_exit_nonzero \
		"Fails on invalid --ssh-type" \
		bash "${SETUP_SCRIPT}" \
		--gpg-key "${GPG_KEY_EXPORT}" --gpg-user "${TEST_EMAIL}" \
		--ssh-key "${SSH_PRIV}" --ssh-pub "${SSH_PUB}" \
		--git-user "${TEST_USER}" --git-email "${TEST_EMAIL}" \
		--ssh-type dsa

	# Unknown options should warn but NOT fail
	assert_output_contains \
		"Unknown option produces warning (not failure)" \
		"Unknown option ignored" \
		run_setup "${GPG_KEY_EXPORT}" "${SSH_PRIV}" "${SSH_PUB}" \
		--some-future-flag value
}

test_full_setup() {
	log_section "Full setup (end-to-end)"

	reset_home
	prepare_keys "ed25519" "${TEST_ROOT}/keys_full"

	# Run the setup script
	run_setup "${GPG_KEY_EXPORT}" "${SSH_PRIV}" "${SSH_PUB}" 2>/dev/null
	local setup_exit=$?
	assert_eq "Setup exits 0" "0" "${setup_exit}"

	# --- File existence ---
	assert_file_exists "SSH private key created" "${HOME}/.ssh/id_ed25519"
	assert_file_exists "SSH public key created"  "${HOME}/.ssh/id_ed25519.pub"
	assert_file_exists "SSH config created"       "${HOME}/.ssh/config"
	assert_file_exists "SSH known_hosts created"  "${HOME}/.ssh/known_hosts"
	assert_file_exists "Token file created"       "${HOME}/.github/personal.access.token"

	# --- Permissions ---
	assert_dir_perm "~/.ssh is 700"     "${HOME}/.ssh"    "700"
	assert_dir_perm "~/.github is 700"  "${HOME}/.github" "700"
	assert_perm "SSH private key is 400" "${HOME}/.ssh/id_ed25519"     "400"
	assert_perm "SSH public key is 400"  "${HOME}/.ssh/id_ed25519.pub" "400"
	assert_perm "SSH config is 600"      "${HOME}/.ssh/config"         "600"
	assert_perm "Token file is 400"      "${HOME}/.github/personal.access.token" "400"

	# --- SSH config content ---
	assert_file_contains "SSH config has managed block" \
		"${HOME}/.ssh/config" "managed by setup-git.sh"
	assert_file_contains "SSH config has IdentityFile" \
		"${HOME}/.ssh/config" "IdentityFile"
	assert_file_contains "SSH config has IdentitiesOnly" \
		"${HOME}/.ssh/config" "IdentitiesOnly yes"
	assert_file_contains "SSH config has StrictHostKeyChecking" \
		"${HOME}/.ssh/config" "StrictHostKeyChecking yes"
	assert_file_contains "SSH config has UserKnownHostsFile" \
		"${HOME}/.ssh/config" "UserKnownHostsFile"
	assert_file_contains "SSH config has LogLevel ERROR" \
		"${HOME}/.ssh/config" "LogLevel ERROR"

	# known_hosts should have content
	if [[ -s "${HOME}/.ssh/known_hosts" ]]; then
		pass "known_hosts is non-empty"
	else
		fail_test "known_hosts is empty"
	fi

	# Token file content
	local stored_token
	stored_token="$(cat "${HOME}/.github/personal.access.token")"
	assert_eq "Token file contains correct token" "${TEST_TOKEN}" "${stored_token}"

	# --- Git config ---
	assert_eq "git user.name" \
		"${TEST_USER}" "$(git config --global user.name)"
	assert_eq "git user.email" \
		"${TEST_EMAIL}" "$(git config --global user.email)"
	assert_eq "git commit.gpgsign" \
		"true" "$(git config --global commit.gpgsign)"
	assert_eq "git tag.gpgSign" \
		"true" "$(git config --global tag.gpgSign)"
	assert_eq "git gpg.program" \
		"gpg" "$(git config --global gpg.program)"
	assert_eq "git gpg.format" \
		"openpgp" "$(git config --global gpg.format)"

	local signing_key
	signing_key="$(git config --global user.signingkey)"
	assert_ne "git user.signingkey is non-empty" "" "${signing_key}"

	local ssh_cmd
	ssh_cmd="$(git config --global core.sshCommand 2>/dev/null || true)"
	if [[ "${ssh_cmd}" == *".ssh/config"* ]]; then
		pass "core.sshCommand references SSH config"
	else
		fail_test "core.sshCommand should reference .ssh/config (got: ${ssh_cmd})"
	fi
}

test_ssh_keypair_validation() {
	log_section "SSH keypair validation"

	reset_home

	local key_dir="${TEST_ROOT}/keys_mismatch"
	mkdir -p "${key_dir}"
	generate_ssh_keypair "${key_dir}/key_a" "ed25519" "a@test"
	generate_ssh_keypair "${key_dir}/key_b" "ed25519" "b@test"

	local priv_a pub_b
	priv_a="$(cat "${key_dir}/key_a")"
	pub_b="$(cat "${key_dir}/key_b.pub")"

	prepare_keys "ed25519" "${TEST_ROOT}/keys_mismatch_gpg"

	assert_exit_nonzero \
		"Rejects mismatched SSH keypair" \
		run_setup "${GPG_KEY_EXPORT}" "${priv_a}" "${pub_b}"

	# --- Test with comment in public key ---
	reset_home
	prepare_keys "ed25519" "${TEST_ROOT}/keys_comment"

	if printf '%s' "${SSH_PUB}" | awk '{print $3}' | grep -q .; then
		pass "Test public key has trailing comment"
	else
		fail_test "Test public key missing comment — test is not meaningful"
	fi

	assert_exit_code \
		"Accepts matching keypair WITH comment in public key" 0 \
		run_setup "${GPG_KEY_EXPORT}" "${SSH_PRIV}" "${SSH_PUB}"
}

test_idempotency_skip() {
	log_section "Idempotency (same user skips)"

	reset_home
	prepare_keys "ed25519" "${TEST_ROOT}/keys_idemp"

	# First run — full setup
	run_setup "${GPG_KEY_EXPORT}" "${SSH_PRIV}" "${SSH_PUB}" 2>/dev/null

	# Record file modification times after first run
	local ssh_key_mtime token_mtime config_mtime
	ssh_key_mtime="$(stat -c '%Y' "${HOME}/.ssh/id_ed25519")"
	token_mtime="$(stat -c '%Y' "${HOME}/.github/personal.access.token")"
	config_mtime="$(stat -c '%Y' "${HOME}/.ssh/config")"

	# Small delay to ensure mtimes would differ if files were rewritten
	sleep 1

	# Second run — same user, should skip
	local output
	output="$(run_setup "${GPG_KEY_EXPORT}" "${SSH_PRIV}" "${SSH_PUB}" 2>&1)"
	local rerun_exit=$?
	assert_eq "Re-run exits 0" "0" "${rerun_exit}"

	# Should say "Already configured"
	if printf '%s' "${output}" | grep -qF "Already configured"; then
		pass "Re-run reports 'Already configured'"
	else
		fail_test "Re-run should report 'Already configured'"
		printf '         output: %.300s\n' "${output}"
	fi

	# Files must NOT have been modified (chmod 400 files untouched)
	local ssh_key_mtime_2 token_mtime_2 config_mtime_2
	ssh_key_mtime_2="$(stat -c '%Y' "${HOME}/.ssh/id_ed25519")"
	token_mtime_2="$(stat -c '%Y' "${HOME}/.github/personal.access.token")"
	config_mtime_2="$(stat -c '%Y' "${HOME}/.ssh/config")"

	assert_eq "SSH key not modified on re-run" "${ssh_key_mtime}" "${ssh_key_mtime_2}"
	assert_eq "Token file not modified on re-run" "${token_mtime}" "${token_mtime_2}"
	assert_eq "SSH config not modified on re-run" "${config_mtime}" "${config_mtime_2}"

	# Third run for good measure
	assert_exit_code "Third run also exits 0" 0 \
		run_setup "${GPG_KEY_EXPORT}" "${SSH_PRIV}" "${SSH_PUB}"
}

test_force_different_user() {
	log_section "Force reconfigure (different user)"

	reset_home
	prepare_keys "ed25519" "${TEST_ROOT}/keys_force_a" "${TEST_USER}" "${TEST_EMAIL}"

	local gpg_a="${GPG_KEY_EXPORT}" ssh_priv_a="${SSH_PRIV}" ssh_pub_a="${SSH_PUB}"

	# First run — setup as user A
	run_setup "${gpg_a}" "${ssh_priv_a}" "${ssh_pub_a}" 2>/dev/null

	# Generate different SSH keys for user B
	local key_dir_b="${TEST_ROOT}/keys_force_b"
	mkdir -p "${key_dir_b}"
	generate_ssh_keypair "${key_dir_b}/id_ed25519" "ed25519" "${TEST_EMAIL_B}"
	local ssh_priv_b ssh_pub_b
	ssh_priv_b="$(cat "${key_dir_b}/id_ed25519")"
	ssh_pub_b="$(cat "${key_dir_b}/id_ed25519.pub")"

	# Generate GPG key for user B
	generate_gpg_key "${TEST_USER_B}" "${TEST_EMAIL_B}"
	local gpg_b
	gpg_b="$(export_gpg_private_key "${TEST_EMAIL_B}")"

	# Run as user B WITHOUT --force — must fail
	assert_exit_nonzero \
		"Rejects different user without --force" \
		bash "${SETUP_SCRIPT}" \
		--gpg-key "${gpg_b}" --gpg-user "${TEST_EMAIL_B}" \
		--ssh-key "${ssh_priv_b}" --ssh-pub "${ssh_pub_b}" \
		--git-user "${TEST_USER_B}" --git-email "${TEST_EMAIL_B}" \
		--git-token "${TEST_TOKEN}"

	assert_output_contains \
		"Rejection message mentions --force" \
		"--force" \
		bash "${SETUP_SCRIPT}" \
		--gpg-key "${gpg_b}" --gpg-user "${TEST_EMAIL_B}" \
		--ssh-key "${ssh_priv_b}" --ssh-pub "${ssh_pub_b}" \
		--git-user "${TEST_USER_B}" --git-email "${TEST_EMAIL_B}" \
		--git-token "${TEST_TOKEN}"

	# Run as user B WITH --force — must succeed
	local force_exit=0
	bash "${SETUP_SCRIPT}" \
		--gpg-key "${gpg_b}" --gpg-user "${TEST_EMAIL_B}" \
		--ssh-key "${ssh_priv_b}" --ssh-pub "${ssh_pub_b}" \
		--git-user "${TEST_USER_B}" --git-email "${TEST_EMAIL_B}" \
		--git-token "${TEST_TOKEN}" \
		--force 2>/dev/null || force_exit=$?
	assert_eq "Force reconfigure exits 0" "0" "${force_exit}"

	# Verify git is now configured for user B
	assert_eq "git user.name is user B" \
		"${TEST_USER_B}" "$(git config --global user.name)"
	assert_eq "git user.email is user B" \
		"${TEST_EMAIL_B}" "$(git config --global user.email)"

	# Verify SSH key is now user B's key
	local installed_pub
	installed_pub="$(ssh-keygen -y -f "${HOME}/.ssh/id_ed25519" 2>/dev/null | awk '{print $1, $2}')"
	local expected_pub
	expected_pub="$(printf '%s' "${ssh_pub_b}" | awk '{print $1, $2}')"
	assert_eq "SSH key is now user B's key" "${expected_pub}" "${installed_pub}"
}

test_git_commit_signing() {
	log_section "Git commit signing (integration)"

	reset_home
	prepare_keys "ed25519" "${TEST_ROOT}/keys_sign"

	run_setup "${GPG_KEY_EXPORT}" "${SSH_PRIV}" "${SSH_PUB}" 2>/dev/null

	local test_repo="${TEST_ROOT}/test_repo"
	mkdir -p "${test_repo}"
	cd "${test_repo}"

	git init -q
	printf 'hello\n' > README.md
	git add README.md

	local commit_exit=0
	git commit -q -m "test: signed commit" 2>/dev/null || commit_exit=$?
	assert_eq "Signed git commit succeeds" "0" "${commit_exit}"

	local log_output
	log_output="$(git log --show-signature -1 2>&1 || true)"
	if printf '%s' "${log_output}" | grep -qi "gpg\|signature\|good sig"; then
		pass "Commit has a GPG signature"
	else
		local raw_commit
		raw_commit="$(git cat-file -p HEAD 2>/dev/null || true)"
		if printf '%s' "${raw_commit}" | grep -q "gpgsig"; then
			pass "Commit has a GPG signature (verified via raw object)"
		else
			fail_test "Commit does not appear to be signed"
		fi
	fi

	assert_eq "Commit author name" \
		"${TEST_USER}" "$(git log --format='%an' -1)"
	assert_eq "Commit author email" \
		"${TEST_EMAIL}" "$(git log --format='%ae' -1)"

	local tag_exit=0
	git tag -s -m "test tag" v0.0.1 2>/dev/null || tag_exit=$?
	assert_eq "Signed git tag succeeds" "0" "${tag_exit}"

	if git tag -v v0.0.1 2>&1 | grep -qi "gpg\|signature\|good sig"; then
		pass "Tag v0.0.1 has a GPG signature"
	else
		local raw_tag
		raw_tag="$(git cat-file -p v0.0.1 2>/dev/null || true)"
		if printf '%s' "${raw_tag}" | grep -q "BEGIN PGP SIGNATURE"; then
			pass "Tag v0.0.1 has a GPG signature (verified via raw object)"
		else
			fail_test "Tag v0.0.1 does not appear to be signed"
		fi
	fi

	printf 'world\n' >> README.md
	git add README.md
	local commit2_exit=0
	git commit -q -m "test: second signed commit" 2>/dev/null || commit2_exit=$?
	assert_eq "Second signed commit succeeds" "0" "${commit2_exit}"

	cd /
}

test_ssh_type_override() {
	log_section "SSH type override (--ssh-type rsa)"

	reset_home
	prepare_keys "rsa" "${TEST_ROOT}/keys_rsa"

	run_setup "${GPG_KEY_EXPORT}" "${SSH_PRIV}" "${SSH_PUB}" --ssh-type rsa 2>/dev/null
	local setup_exit=$?
	assert_eq "Setup with --ssh-type rsa exits 0" "0" "${setup_exit}"

	assert_file_exists "RSA private key at correct path" "${HOME}/.ssh/id_rsa"
	assert_file_exists "RSA public key at correct path"  "${HOME}/.ssh/id_rsa.pub"
	assert_file_not_exists "No ed25519 key created" "${HOME}/.ssh/id_ed25519"

	assert_file_contains "SSH config references RSA key" \
		"${HOME}/.ssh/config" "id_rsa"
}

test_empty_token() {
	log_section "Empty/missing token handling"

	reset_home
	prepare_keys "ed25519" "${TEST_ROOT}/keys_notoken"

	bash "${SETUP_SCRIPT}" \
		--gpg-key "${GPG_KEY_EXPORT}" \
		--gpg-user "${TEST_EMAIL}" \
		--ssh-key "${SSH_PRIV}" \
		--ssh-pub "${SSH_PUB}" \
		--git-user "${TEST_USER}" \
		--git-email "${TEST_EMAIL}" \
		2>/dev/null

	assert_file_exists "Token file exists even without --git-token" \
		"${HOME}/.github/personal.access.token"
}

test_no_temp_key_files() {
	log_section "Security: no temporary key files on disk"

	reset_home
	prepare_keys "ed25519" "${TEST_ROOT}/keys_notmp"

	run_setup "${GPG_KEY_EXPORT}" "${SSH_PRIV}" "${SSH_PUB}" 2>/dev/null

	assert_file_not_exists "No robot.asc in pwd" "${PWD}/robot.asc"
	assert_file_not_exists "No robot.asc in HOME" "${HOME}/robot.asc"

	local leftover
	leftover="$(find /tmp -maxdepth 1 -name 'tmp.*' -user "$(whoami)" \
		-newer "${HOME}/.ssh/id_ed25519" -type d 2>/dev/null | wc -l)"
	if [[ "${leftover}" -eq 0 ]]; then
		pass "No leftover temp directories"
	else
		fail_test "Found ${leftover} possible leftover temp directory(ies)"
	fi
}

test_protected_files() {
	log_section "Security: chmod 400 files are protected"

	reset_home
	prepare_keys "ed25519" "${TEST_ROOT}/keys_prot"

	run_setup "${GPG_KEY_EXPORT}" "${SSH_PRIV}" "${SSH_PUB}" 2>/dev/null

	# Verify all sensitive files are locked
	assert_perm "SSH private key is 400" "${HOME}/.ssh/id_ed25519" "400"
	assert_perm "SSH public key is 400"  "${HOME}/.ssh/id_ed25519.pub" "400"
	assert_perm "Token file is 400"      "${HOME}/.github/personal.access.token" "400"
}

test_equals_sign_syntax() {
	log_section "Argument parsing: --key=value syntax"

	reset_home
	prepare_keys "ed25519" "${TEST_ROOT}/keys_equals"

	local setup_exit=0
	bash "${SETUP_SCRIPT}" \
		--gpg-key="${GPG_KEY_EXPORT}" \
		--gpg-user="${TEST_EMAIL}" \
		--ssh-key="${SSH_PRIV}" \
		--ssh-pub="${SSH_PUB}" \
		--git-user="${TEST_USER}" \
		--git-email="${TEST_EMAIL}" \
		--git-token="${TEST_TOKEN}" \
		2>/dev/null || setup_exit=$?

	assert_eq "Setup with --key=value syntax exits 0" "0" "${setup_exit}"
	assert_eq "git user.name via --key=value" \
		"${TEST_USER}" "$(git config --global user.name 2>/dev/null || true)"
}

test_custom_ssh_host() {
	log_section "Custom SSH host (--ssh-host)"

	reset_home
	prepare_keys "ed25519" "${TEST_ROOT}/keys_host"

	run_setup "${GPG_KEY_EXPORT}" "${SSH_PRIV}" "${SSH_PUB}" \
		--ssh-host "git.example.com" 2>/dev/null
	local setup_exit=$?
	assert_eq "Setup with custom --ssh-host exits 0" "0" "${setup_exit}"

	assert_file_contains "SSH config has custom host" \
		"${HOME}/.ssh/config" "git.example.com"
	assert_file_contains "SSH config block tagged with host" \
		"${HOME}/.ssh/config" "managed by setup-git.sh (git.example.com)"
}

test_help_flag() {
	log_section "Help flag"

	assert_exit_nonzero \
		"--help exits non-zero (usage)" \
		bash "${SETUP_SCRIPT}" --help

	assert_output_contains \
		"--help shows usage text" \
		"Usage:" \
		bash "${SETUP_SCRIPT}" --help

	assert_output_contains \
		"--help documents --force" \
		"--force" \
		bash "${SETUP_SCRIPT}" --help

	assert_exit_nonzero \
		"-h exits non-zero (usage)" \
		bash "${SETUP_SCRIPT}" -h
}

# ──────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────
main() {
	printf '%s\n' "$(_bold "setup-git.sh — Test Suite")"
	printf 'Script under test: %s\n' "${SETUP_SCRIPT}"
	printf 'Date:              %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')"

	SETUP_SCRIPT="$(cd "$(dirname "${SETUP_SCRIPT}")" && pwd)/$(basename "${SETUP_SCRIPT}")"

	create_test_environment
	trap destroy_test_environment EXIT

	test_prerequisites
	test_argument_validation
	test_full_setup
	test_ssh_keypair_validation
	test_idempotency_skip
	test_force_different_user
	test_git_commit_signing
	test_ssh_type_override
	test_empty_token
	test_no_temp_key_files
	test_protected_files
	test_equals_sign_syntax
	test_custom_ssh_host
	test_help_flag

	# Summary
	printf '\n%s\n' "════════════════════════════════════════"
	printf 'Tests run:    %d\n' "${TESTS_RUN}"
	printf 'Passed:       %s\n' "$(_green "${TESTS_PASSED}")"
	if ((TESTS_FAILED > 0)); then
		printf 'Failed:       %s\n' "$(_red "${TESTS_FAILED}")"
		printf '\n%s\n' "$(_red "SOME TESTS FAILED")"
		exit 1
	else
		printf 'Failed:       0\n'
		printf '\n%s\n' "$(_green "ALL TESTS PASSED")"
		exit 0
	fi
}

main "$@"
