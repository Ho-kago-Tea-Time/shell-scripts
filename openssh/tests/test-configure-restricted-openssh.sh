#!/usr/bin/env bash
# Offline tests. Optional real sshd -T/-t coverage when sshd is installed.
set -eo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
script=${1:-$repo/openssh/unix/configure-restricted-openssh.sh}
root=$(mktemp -d "${TMPDIR:-/tmp}/restricted-openssh-tests.XXXXXXXX")
cleanup_tests() {
    # Remove only the files created by this test under its private temp directory.
    find "$root" -type l -delete
    find "$root" -type f -delete
    find "$root" -depth -type d -empty -delete
}
trap cleanup_tests EXIT
# shellcheck source=../unix/configure-restricted-openssh.sh
source "$script"
passed=0
ok() { passed=$((passed + 1)); printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
expect_failure() { if ("$@") > "$root/error" 2>&1; then fail "Expected failure: $*"; fi; }
expect_error() {
    local expected=$1
    shift
    expect_failure "$@"
    grep -Fq -- "$expected" "$root/error" || fail "Missing diagnostic: $expected"
}

for value in 192.0.2.1 0.0.0.0 255.255.255.255 2001:db8::10 ::1 :: 2001:db8:0:0:0:0:0:1; do
    validate_address "$value" 0 >/dev/null || fail "Valid address: $value"
done
for value in 192.0.2.0/24 0.0.0.0/0 192.0.2.1/32 2001:db8::/32 ::/0 2001:db8::10/128; do
    validate_address "$value" 1 >/dev/null || fail "Valid CIDR: $value"
done
for value in '192.0.2.1/24' '192.0.2.1/33' '192.0.2.1/01' '192.00.2.1' '256.0.0.1' 'example.com' '*' '192.0.2.1,!*' '2001:db8::1/64' '::/129' '2001::db8::1' '1:2:3:4:5:6:7:8::' ':::' 'fe80::1%en0' $'192.0.2.1\nMatch all'; do
    expect_failure validate_address "$value" 1
done
expect_failure validate_address 192.0.2.0/24 0
ok 'IPv4/IPv6, canonical CIDRs, and policy injection rejection'

printf 'Port 22\n# preserve this comment\n' > "$root/config"
login_user=demo
local_addresses=(192.0.2.10 2001:db8::10)
remote_addresses=(192.0.2.1 198.51.100.0/24 2001:db8:1::/64)
render_rules >> "$root/config"
strip_managed_block "$root/config" > "$root/base"
check_config_tree "$root/base"
{ cat "$root/base"; render_rules; } > "$root/config2"
strip_managed_block "$root/config2" > "$root/base2"
# Removing/replacing the block may leave one separator newline; policy stays unique.
[[ $(grep -c '^# BEGIN shell-scripts restricted-openssh$' "$root/config2") == 1 ]] || fail 'Duplicate policy'
grep -q '^# preserve this comment$' "$root/base2" || fail 'Lost existing comment'
printf '%s\n' "$BEGIN_MARKER" >> "$root/config2"
expect_failure strip_managed_block "$root/config2"
printf '%s\n' "$END_MARKER" > "$root/orphan"
expect_failure strip_managed_block "$root/orphan"
ok 'Managed block replacement preserves existing config and rejects malformed blocks'

mkdir "$root/includes"
printf 'Match User other\n    DenyUsers=demo\n' > "$root/includes/nested.conf"
printf 'Include "%s/*.conf"\n' "$root/includes" > "$root/include-root"
expect_failure check_config_tree "$root/include-root"
printf 'PubkeyAuthentication yes\n' > "$root/includes/nested.conf"
check_config_tree "$root/include-root"
printf 'Include %s\n' "$root/include-root" > "$root/includes/nested.conf"
expect_failure check_config_tree "$root/include-root"
printf 'Include "unsupported path/*.conf"\n' > "$root/include-root"
expect_failure check_config_tree "$root/include-root"
ok 'Conditional Includes cannot hide DenyUsers; cycles and unsupported paths fail closed'

ssh-keygen -q -t ed25519 -N '' -C demo@example.com -f "$root/key"
public_key=$(cat "$root/key.pub")
read -r key_type key_data _ <<< "$public_key"

cat > "$root/preview.sh" <<'PREVIEW'
source "$1"
detect_platform() { platform=Darwin; }
resolve_user() { die 'Dry run tried resolving/modifying the target account.'; }
ensure_server() { die 'Dry run tried installing a server.'; }
apply_configuration() { die 'Dry run tried writing configuration.'; }
shift
main "$@"
PREVIEW
bash "$root/preview.sh" "$script" --user demo --local-address 192.0.2.10 --remote-address 192.0.2.1 --public-key-file "$root/key.pub" --dry-run > "$root/preview.out"
grep -q 'Platform: Darwin' "$root/preview.out" || fail 'macOS preview'
expect_error "A private key was supplied: $root/key" bash "$root/preview.sh" "$script" --user demo --local-address 192.0.2.10 --remote-address 192.0.2.1 --public-key-file "$root/key" --dry-run
if grep -Fq -- '-----BEGIN OPENSSH PRIVATE KEY-----' "$root/error"; then fail 'Diagnostic exposed private key contents'; fi
cat "$root/key.pub" "$root/key.pub" > "$root/multiple.pub"
expect_error "Public key file contains multiple non-empty lines: $root/multiple.pub" bash "$root/preview.sh" "$script" --user demo --local-address 192.0.2.10 --remote-address 192.0.2.1 --public-key-file "$root/multiple.pub" --dry-run
printf ' \r\n\t\r\n' > "$root/empty.pub"
expect_error "Public key file is empty or contains only whitespace: $root/empty.pub" bash "$root/preview.sh" "$script" --user demo --local-address 192.0.2.10 --remote-address 192.0.2.1 --public-key-file "$root/empty.pub" --dry-run
printf 'restrict %s\n' "$public_key" > "$root/options.pub"
expect_error "Public key file contains authorized_keys options: $root/options.pub" bash "$root/preview.sh" "$script" --user demo --local-address 192.0.2.10 --remote-address 192.0.2.1 --public-key-file "$root/options.pub" --dry-run
printf '\r\n%s\r\n\r\n' "$public_key" > "$root/crlf.pub"
bash "$root/preview.sh" "$script" --user demo --local-address 192.0.2.10 --remote-address 192.0.2.1 --public-key-file "$root/crlf.pub" --dry-run > "$root/preview.out"
ok 'macOS dry run avoids system changes; private keys and multiple key lines are rejected'

expect_error 'Missing required --user.' main --dry-run
expect_error '--user cannot be root.' main --user root --dry-run
expect_error 'Invalid --user format: 123demo' main --user 123demo --dry-run
ok 'Missing, root, and malformed login accounts have distinct diagnostics'

acquire_lock "$root/config.lock"
expect_error "SSH configuration lock path already exists: $root/config.lock" acquire_lock "$root/config.lock"
expect_error "Cannot create SSH configuration lock: $root/missing-parent/config.lock" acquire_lock "$root/missing-parent/config.lock"
ok 'Lock creation errors do not falsely imply another running instance'

(
    # Stub only the policy query, so the actual checks and connection context run.
    /usr/sbin/sshd() { printf '%s\n' "$mock_policy"; }
    login_user=demo
    local_addresses=(192.0.2.10)
    remote_addresses=(192.0.2.1)
    authorized_keys=/home/demo/.ssh/authorized_keys
    mock_policy=$'pubkeyauthentication no\nauthorizedkeysfile .ssh/authorized_keys'
    expect_error 'PubkeyAuthentication=no' verify_effective_config "$root/config"
    grep -Fq 'user=demo, source=192.0.2.1, destination=192.0.2.10' "$root/error" || fail 'Policy error lost connection context'
    mock_policy=$'pubkeyauthentication yes\nauthorizedkeysfile /custom/keys'
    expect_error 'actual: /custom/keys; expected:' verify_effective_config "$root/config"
    mock_policy=$'pubkeyauthentication yes\nauthorizedkeysfile .ssh/authorized_keys\ndenyusers *'
    expect_error 'SSH policy denies the supplied connection (user=demo, source=192.0.2.1, destination=192.0.2.10' verify_effective_config "$root/config"
)
ok 'Policy conflict diagnostics identify the connection and effective settings'

(
    /usr/sbin/sshd() { printf '%s\n' "$mock_policy"; }
    login_user=demo
    local_addresses=(192.0.2.10)
    remote_addresses=(192.0.2.1)
    # Preserve value case: macOS home paths and account names can contain it.
    authorized_keys=/Users/Demo/.ssh/authorized_keys
    for spelling in canonical mixed; do
        case "$spelling" in
            canonical) pubkey_option=PubkeyAuthentication; keys_option=AuthorizedKeysFile; deny_option=DenyUsers ;;
            mixed) pubkey_option=PuBkEyAuThEnTiCaTiOn; keys_option=AuThOrIzEdKeYsFiLe; deny_option=DeNyUsErS ;;
        esac
        mock_policy=$(printf '%s yes\n%s %s\n' "$pubkey_option" "$keys_option" "$authorized_keys")
        verify_effective_config "$root/config"
        mock_policy=$(printf '%s no\n%s %s\n' "$pubkey_option" "$keys_option" "$authorized_keys")
        expect_error 'PubkeyAuthentication=no' verify_effective_config "$root/config"
        mock_policy=$(printf '%s yes\n%s /Users/Other/.ssh/authorized_keys\n' "$pubkey_option" "$keys_option")
        expect_error 'incompatible AuthorizedKeysFile' verify_effective_config "$root/config"
        mock_policy=$(printf '%s yes\n%s %s\n%s *\n' "$pubkey_option" "$keys_option" "$authorized_keys" "$deny_option")
        expect_error 'SSH policy denies the supplied connection' verify_effective_config "$root/config"
    done
    mock_policy='AuthorizedKeysFile .ssh/authorized_keys'
    expect_error 'PubkeyAuthentication=<missing>' verify_effective_config "$root/config"
) || fail 'Mixed-case sshd policy checks failed'
ok 'Mixed-case sshd fields preserve key paths and enforce authentication/deny policies'

# A fresh Mac must generate host keys before raw sshd validation, even though
# the system Remote Login launch wrapper has never generated them yet.
(
    platform=Darwin
    assert_server_files() { :; }
    ssh-keygen() {
        [[ "$*" == -A ]] || fail 'Wrong host-key command'
        printf 'generated\n' > "$root/host-keys-ready"
    }
    ensure_server
    [[ -f "$root/host-keys-ready" ]] || fail 'macOS skipped host-key generation'
)
ok 'macOS prepares missing host keys before configuration checks'

# Exercise the actual file transaction with service/sshd commands replaced.
# All writes are confined to the private fixture; no sudo or service changes.
fixture=$root/transaction
mkdir -p "$fixture/home/.ssh"
printf 'Port 22\n' > "$fixture/sshd_config"
printf '# old key and comment\n' > "$fixture/home/.ssh/authorized_keys"
test_user=$(id -un)
if [[ "$EUID" == 0 && -n "${SUDO_USER:-}" && "$SUDO_USER" != root ]]; then test_user=$SUDO_USER; fi
test_uid=$(id -u "$test_user"); test_gid=$(id -g "$test_user")
export KEY_TEST_USER=$test_user
if [[ "$EUID" == 0 ]]; then
    # Allow only traversal into the private test root; the target user's home
    # fixture is the only subtree handed to that user. No system paths change.
    chmod 711 "$root" "$fixture"
    chown -R "$test_uid:$test_gid" "$fixture/home"
fi
cat > "$root/run-fixture.sh" <<'FIXTURE'
#!/usr/bin/env bash
source "$1"
fixture=$2
public_key=$(cat "$3")
read -r key_type key_data _ <<< "$public_key"
login_user=$KEY_TEST_USER
local_addresses=(192.0.2.10 2001:db8::10)
remote_addresses=(192.0.2.1 198.51.100.0/24 2001:db8:1::/64)
    work_dir=''; staged_config=''; files_changed=0; keys_existed=0; ssh_dir_existed=0
    activation_started=0; policy_created=0; lock_created=0
    case "$(uname -s)" in Darwin) platform=Darwin ;; *) platform=Linux ;; esac
    # Mark the mocked service as already active so macOS rollback never calls
    # the real systemsetup utility. Linux systemctl is stubbed below as well.
    service_was_active=1; service_was_enabled=disabled
    sshd_config=$fixture/sshd_config
    user_home=$fixture/home
    ssh_dir=$fixture/home/.ssh; authorized_keys=$ssh_dir/authorized_keys
    user_id=$(id -u "$login_user"); group_id=$(id -g "$login_user")
    [[ "$(run_as_target_user id -u)" == "$user_id" ]] || die 'User-key commands retained the wrong uid.'
    validate_sshd_config() { [[ "${MOCK_INVALID_CONFIG:-0}" != 1 ]]; }
    verify_effective_config() { :; }
    systemctl() { [[ "$1" != "${MOCK_SERVICE_STEP:-}" ]]; }
    eval "$(declare -f activate_server | sed '1s/activate_server/original_activate_server/')"
    activate_server() {
        if [[ "${MOCK_ROLLBACK_LINK:-0}" == 1 ]]; then
            rm -f "$authorized_keys"
            ln -s "$fixture/outside" "$authorized_keys"
            return 1
        fi
        if [[ -n "${MOCK_SERVICE_STEP:-}" ]]; then
            platform=Linux
            original_activate_server
            return
        fi
        [[ "${MOCK_SERVICE_FAILURE:-0}" != 1 ]]
    }
    # Deterministically replace a path after snapshot/preflight, immediately
    # before the install operation. The original root path writes followed it.
    # Wrap the privilege boundary instead of re-evaluating user_key_task's
    # heredoc: Bash 3.2's declare -f cannot round-trip that function reliably.
    eval "$(declare -f run_as_target_user | sed '1s/run_as_target_user/original_run_as_target_user/')"
    run_as_target_user() {
        if [[ "${5:-}" == install && "${MOCK_INSTALL_LINK:-0}" == 1 ]]; then
            rm -f "$authorized_keys"
            ln -s "$fixture/outside" "$authorized_keys"
        elif [[ "${5:-}" == install && "${MOCK_DIRECTORY_LINK:-0}" == 1 ]]; then
            mv "$ssh_dir" "$fixture/saved-ssh"
            ln -s "$fixture/outside-dir" "$ssh_dir"
        fi
        original_run_as_target_user "$@"
    }
    trap cleanup EXIT
    apply_configuration
FIXTURE
apply_fixture() { bash "$root/run-fixture.sh" "$script" "$fixture" "$root/key.pub"; }
apply_fixture
first_config=$(cat "$fixture/sshd_config")
apply_fixture
[[ "$first_config" == "$(cat "$fixture/sshd_config")" ]] || fail 'Rerun changed the config'
[[ $(grep -c "$key_data" "$fixture/home/.ssh/authorized_keys") == 1 ]] || fail 'Duplicate key'
grep -q '^# old key and comment$' "$fixture/home/.ssh/authorized_keys" || fail 'Lost existing keys'
[[ $(grep -c '^# BEGIN shell-scripts restricted-openssh$' "$fixture/sshd_config") == 1 ]] || fail 'Duplicate managed block'
ok 'Repeated configuration preserves authorized_keys and avoids duplicate keys/rules'

printf '# before failure\n' > "$fixture/home/.ssh/authorized_keys"
chmod 640 "$fixture/home/.ssh/authorized_keys"
chmod 750 "$fixture/home/.ssh"
cp "$fixture/sshd_config" "$root/config.expected"
cp "$fixture/home/.ssh/authorized_keys" "$root/keys.expected"
export MOCK_INVALID_CONFIG=1
expect_failure apply_fixture
cmp "$root/config.expected" "$fixture/sshd_config" || fail 'Invalid config rollback'
cmp "$root/keys.expected" "$fixture/home/.ssh/authorized_keys" || fail 'Key rollback'
unset MOCK_INVALID_CONFIG
export MOCK_SERVICE_FAILURE=1
expect_failure apply_fixture
cmp "$root/config.expected" "$fixture/sshd_config" || fail 'Service failure config rollback'
cmp "$root/keys.expected" "$fixture/home/.ssh/authorized_keys" || fail 'Service failure key rollback'
if [[ "$(uname -s)" == Linux ]]; then
    [[ "$(stat -c '%a' "$fixture/home/.ssh")" == 750 ]] || fail 'Directory mode rollback'
    [[ "$(stat -c '%a' "$fixture/home/.ssh/authorized_keys")" == 640 ]] || fail 'Key file mode rollback'
fi
unset MOCK_SERVICE_FAILURE
ok 'Validation and service activation failures restore the exact prior files'

for step in enable restart is-active; do
    export MOCK_SERVICE_STEP=$step
    expect_error 'SSH service activation failed:' apply_fixture
    grep -Fq 'sudo journalctl -u ssh.service' "$root/error" || fail 'Missing service troubleshooting command'
    if [[ "$step" == is-active ]]; then
        grep -Fq 'ssh.service is not active after restart' "$root/error" || fail 'Missing inactive service cause'
    else
        grep -Fq "systemctl $step ssh.service failed" "$root/error" || fail 'Missing failed service operation'
    fi
    cmp "$root/config.expected" "$fixture/sshd_config" || fail 'Service diagnostic changed config rollback'
    cmp "$root/keys.expected" "$fixture/home/.ssh/authorized_keys" || fail 'Service diagnostic changed key rollback'
    unset MOCK_SERVICE_STEP
done
ok 'Each service activation failure reports its cause and still restores prior files'

printf 'sensitive sentinel\n' > "$fixture/outside"
chmod 640 "$fixture/outside"
mkdir "$fixture/outside-dir"
cp "$fixture/outside" "$fixture/outside-dir/authorized_keys"
cp "$fixture/outside" "$root/outside.expected"
ln -s "$fixture/outside" "$root/probe-link"
if [[ -L "$root/probe-link" ]]; then
if [[ "$(uname -s)" == Linux ]]; then sentinel_mode=$(stat -c '%u:%g:%a' "$fixture/outside"); fi
for scenario in MOCK_INSTALL_LINK MOCK_DIRECTORY_LINK MOCK_ROLLBACK_LINK; do
    export "$scenario=1"
    expect_failure apply_fixture
    unset "$scenario"
    cmp "$root/config.expected" "$fixture/sshd_config" || fail 'Symlink attack config rollback'
    cmp "$root/outside.expected" "$fixture/outside" || fail 'Symlink attack changed external file'
    cmp "$root/outside.expected" "$fixture/outside-dir/authorized_keys" || fail 'Directory symlink changed external file'
    if [[ "$(uname -s)" == Linux ]]; then
        [[ "$(stat -c '%u:%g:%a' "$fixture/outside")" == "$sentinel_mode" ]] || fail 'Symlink attack changed external ownership/mode'
    fi
    if [[ -L "$fixture/home/.ssh" ]]; then
        rm "$fixture/home/.ssh"
        mv "$fixture/saved-ssh" "$fixture/home/.ssh"
    fi
    if [[ -L "$fixture/home/.ssh/authorized_keys" ]]; then rm "$fixture/home/.ssh/authorized_keys"; fi
    cp "$root/keys.expected" "$fixture/home/.ssh/authorized_keys"
    if [[ "$EUID" == 0 ]]; then chown "$test_uid:$test_gid" "$fixture/home/.ssh/authorized_keys"; fi
done
ok 'File/directory replacement during install and rollback cannot modify external targets'
else
    printf 'SKIP: symlink replacement tests (requires native Unix symlinks)\n'
fi

if [[ -x /usr/sbin/sshd ]]; then
    printf 'HostKey %s\nUsePAM no\nAuthorizedKeysFile .ssh/authorized_keys\n' "$root/key" > "$root/real-config"
    render_rules >> "$root/real-config"
    /usr/sbin/sshd -t -f "$root/real-config"
    check_policy() {
        local user=$1 source_ip=$2 target_ip=$3 expect_denied=$4 result
        result=$(/usr/sbin/sshd -T -f "$root/real-config" -C "user=$user,host=client.example.com,addr=$source_ip,laddr=$target_ip,lport=22")
        if printf '%s\n' "$result" | awk 'tolower($1) == "denyusers" { for (i=2; i<=NF; i++) if ($i == "*") found=1 } END { exit !found }'; then
            [[ "$expect_denied" == 1 ]] || fail 'Allowed connection was denied'
        else [[ "$expect_denied" == 0 ]] || fail 'Disallowed connection was accepted'; fi
    }
    check_policy demo 192.0.2.1 192.0.2.10 0
    check_policy demo 198.51.100.99 192.0.2.10 0
    check_policy demo 2001:db8:1::20 2001:db8::10 0
    check_policy other 192.0.2.1 192.0.2.10 1
    check_policy root 192.0.2.1 192.0.2.10 1
    check_policy demo 203.0.113.1 192.0.2.10 1
    check_policy demo 192.0.2.1 192.0.2.11 1
    check_policy demo 2001:db8:2::20 2001:db8::10 1
    check_policy demo 2001:db8:1::20 2001:db8::11 1
    sshd_config=$root/real-config
    authorized_keys=/path/to/home/.ssh/authorized_keys
    verify_effective_config
    ok 'Real sshd validates IPv4/IPv6 user, source, destination, CIDR, and effective key policy'
else
    printf 'SKIP: real sshd checks (requires OpenSSH Server on macOS/Linux)\n'
fi
printf '%s test groups passed.\n' "$passed"
