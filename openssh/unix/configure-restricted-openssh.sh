#!/usr/bin/env bash
# Configure the target machine, not the SSH client. Compatible with Bash 3.2+.
set -eo pipefail

BEGIN_MARKER='# BEGIN shell-scripts restricted-openssh'
END_MARKER='# END shell-scripts restricted-openssh'

log() { printf '[INFO] %s\n' "$*"; }
die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage (run on the target machine):
  sudo bash configure-restricted-openssh.sh --user demo \
    --local-address 192.0.2.10 --remote-address 192.0.2.1 \
    --public-key-file /path/to/client.pub [--dry-run]

Supports macOS (built-in Remote Login) and Ubuntu/Debian with systemd.
  --user USER             Existing non-root login account (required).
  --local-address IP      Allowed destination IP; repeat for multiple addresses.
  --remote-address CIDR   Allowed client IP or network; repeat as needed.
  --public-key-file FILE  One OpenSSH public key, without authorized_keys options.
  --dry-run              Validate inputs and print the plan without writes/sudo.
  -h, --help             Show help.

The allowlist applies to ALL SSH logins via sshd Match/DenyUsers rules.
Only the chosen user may log in, from the supplied sources/destinations.
This does not change the firewall, SSH port, or password authentication policy.
EOF
}

# Return the address without its CIDR mask. Reject hostnames, wildcards, scope
# IDs, ambiguous IPv4 notation, and non-canonical network host bits.
validate_address() {
    local input=$1 allow_cidr=$2 address prefix octet value bits shift_count
    local left right expanded group index compressed=0
    local -a parts groups left_groups right_groups
    address=${input%%/*}
    prefix=''
    if [[ "$input" == */* ]]; then
        [[ "$allow_cidr" == 1 && "$input" != */*/* ]] || return 1
        prefix=${input#*/}
        [[ "$prefix" =~ ^(0|[1-9][0-9]*)$ && ${#prefix} -le 3 ]] || return 1
    fi
    if [[ "$address" == *:* ]]; then
        [[ "$address" =~ ^[0-9a-fA-F:]+$ && "$address" != *:::* ]] || return 1
        [[ -z "$prefix" || "$prefix" -le 128 ]] || return 1
        if [[ "$address" == *::* ]]; then
            compressed=1
            left=${address%%::*}; right=${address#*::}
            [[ "$right" != *::* ]] || return 1
        else
            left=$address; right=''
        fi
        left_groups=(); right_groups=()
        if [[ -n "$left" ]]; then
            [[ "$left" != :* && "$left" != *: ]] || return 1
            IFS=: read -r -a left_groups <<< "$left"
        fi
        if [[ -n "$right" ]]; then
            [[ "$right" != :* && "$right" != *: ]] || return 1
            IFS=: read -r -a right_groups <<< "$right"
        fi
        index=$((${#left_groups[@]} + ${#right_groups[@]}))
        if [[ "$compressed" == 1 ]]; then [[ "$index" -lt 8 ]] || return 1
        else [[ "$index" == 8 ]] || return 1; fi
        groups=("${left_groups[@]}")
        if [[ "$compressed" == 1 ]]; then
            while [[ "${#groups[@]}" -lt "$((8 - ${#right_groups[@]}))" ]]; do groups+=(0); done
        fi
        groups+=("${right_groups[@]}")
        bits=${prefix:-128}
        for group in "${groups[@]}"; do
            [[ ${#group} -ge 1 && ${#group} -le 4 ]] || return 1
            value=$((16#$group))
            if [[ "$bits" -ge 16 ]]; then bits=$((bits - 16))
            else
                shift_count=$((16 - bits))
                [[ $((value % (1 << shift_count))) == 0 ]] || return 1
                bits=0
            fi
        done
    else
        [[ "$address" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
        [[ -z "$prefix" || "$prefix" -le 32 ]] || return 1
        IFS=. read -r -a parts <<< "$address"
        bits=${prefix:-32}
        for octet in "${parts[@]}"; do
            [[ "$octet" =~ ^(0|[1-9][0-9]*)$ && ${#octet} -le 3 && "$octet" -le 255 ]] || return 1
            value=$((10#$octet))
            if [[ "$bits" -ge 8 ]]; then bits=$((bits - 8))
            else
                shift_count=$((8 - bits))
                [[ $((value % (1 << shift_count))) == 0 ]] || return 1
                bits=0
            fi
        done
    fi
    printf '%s\n' "$address"
}

strip_managed_block() {
    awk -v begin="$BEGIN_MARKER" -v end="$END_MARKER" '
        $0 == begin { if (inside || seen++) exit 2; inside=1; next }
        $0 == end { if (!inside) exit 2; inside=0; next }
        !inside { print }
        END { if (inside) exit 2 }
    ' "$1"
}

# A pre-existing DenyUsers in a Match block can take precedence over our rules.
# Inspect all Includes, including conditional ones. Unsupported Include syntax
# fails closed rather than silently leaving a path around the allowlist.
check_config_tree() {
    local file=$1 depth=${2:-0} line keyword token include_file
    local -a words matches
    [[ "$depth" -lt 16 ]] || die 'Recursive or excessively deep sshd Include chain.'
    [[ -r "$file" ]] || die "Cannot read SSH config: $file"
    while IFS= read -r line || [[ -n "$line" ]]; do
        line=${line%%#*}
        line=${line/=/ }
        words=()
        read -r -a words <<< "$line"
        [[ ${#words[@]} -gt 0 ]] || continue
        [[ "${words[0]}" =~ ^[a-zA-Z][a-zA-Z0-9]*$ ]] || die "Unsupported SSH directive syntax: $file"
        keyword=$(printf '%s' "${words[0]}" | tr '[:upper:]' '[:lower:]')
        [[ "$keyword" != denyusers ]] || die "Existing DenyUsers requires manual reconciliation: $file"
        [[ "$keyword" == include ]] || continue
        [[ ${#words[@]} -gt 1 ]] || die "Empty Include: $file"
        for token in "${words[@]:1}"; do
            if [[ "$token" == \"* || "$token" == *\" ]]; then
                [[ "$token" == \"*\" && ${#token} -gt 2 ]] || die 'Include paths with spaces require manual reconciliation.'
                token=${token#\"}; token=${token%\"}
            fi
            [[ "$token" != *[!a-zA-Z0-9_./\*\?\[\]-]* && -n "$token" && "$token" != *..* ]] || die "Unsupported Include path: $token"
            [[ "$token" == /* ]] || token="/etc/ssh/$token"
            matches=()
            while IFS= read -r include_file; do matches+=("$include_file"); done < <(compgen -G "$token" || true)
            for include_file in "${matches[@]}"; do check_config_tree "$include_file" "$((depth + 1))"; done
        done
    done < "$file"
}

render_rules() {
    local address patterns='*'
    printf '%s\nMatch all\n' "$BEGIN_MARKER"
    printf 'Match User *,!%s\n    DenyUsers *\n' "$login_user"
    for address in "${remote_addresses[@]}"; do patterns="$patterns,!$address"; done
    printf 'Match Address %s\n    DenyUsers *\n' "$patterns"
    patterns='*'
    for address in "${local_addresses[@]}"; do patterns="$patterns,!$address"; done
    printf 'Match LocalAddress %s\n    DenyUsers *\n' "$patterns"
    printf 'Match all\n%s\n' "$END_MARKER"
}

detect_platform() {
    platform=$(uname -s)
    case "$platform" in
        Darwin) ;;
        Linux)
            [[ -r /etc/os-release ]] || die 'Missing /etc/os-release.'
            # This is the trusted, root-owned OS identity file.
            . /etc/os-release
            case "${ID:-}" in ubuntu|debian) ;; *) die 'Only Ubuntu/Debian Linux is supported.' ;; esac
            command -v systemctl >/dev/null && [[ -d /run/systemd/system ]] || die 'Linux requires systemd (not a plain container/WSL without systemd).'
            ;;
        *) die 'Run this script on macOS or Ubuntu/Debian, not on the client PC.' ;;
    esac
}

resolve_user() {
    local record
    user_id=$(id -u "$login_user") || die "No such user: $login_user"
    [[ "$user_id" != 0 ]] || die 'Choose a non-root account.'
    group_id=$(id -g "$login_user")
    if [[ "$platform" == Darwin ]]; then
        user_home=$(dscl . -read "/Users/$login_user" NFSHomeDirectory | sed 's/^NFSHomeDirectory: //')
    else
        record=$(getent passwd "$login_user") || die 'Cannot resolve target account.'
        IFS=: read -r _ _ _ _ _ user_home _ <<< "$record"
    fi
    [[ "$user_home" == /* && "$user_home" != / && -d "$user_home" ]] || die 'Target home directory must already exist.'
    ssh_dir="$user_home/.ssh"; authorized_keys="$ssh_dir/authorized_keys"
    [[ ! -L "$ssh_dir" && ! -L "$authorized_keys" ]] || die 'Refusing symlinked .ssh/authorized_keys paths.'
    [[ ! -e "$ssh_dir" || -d "$ssh_dir" ]] || die '.ssh is not a directory.'
    [[ ! -e "$authorized_keys" || -f "$authorized_keys" ]] || die 'authorized_keys is not a regular file.'
}

ensure_server() {
    if [[ "$platform" == Linux && ! -x /usr/sbin/sshd ]]; then
        # Debian package scripts can start sshd during installation. Suppress
        # service actions until the restricted config has passed validation.
        [[ ! -e /usr/sbin/policy-rc.d && ! -L /usr/sbin/policy-rc.d ]] || die 'Install openssh-server using your existing policy-rc.d, then rerun.'
        (set -C; printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d)
        policy_created=1
        chmod 755 /usr/sbin/policy-rc.d
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-server
        rm -f /usr/sbin/policy-rc.d
        policy_created=0
    fi
    assert_server_files
    if [[ "$platform" == Linux ]]; then
        mkdir -p /run/sshd
    fi
    # Remote Login's launch wrapper may not have run on a new Mac yet. Both
    # platforms need host keys before the raw sshd -t/-T configuration checks.
    ssh-keygen -A
}

assert_server_files() {
    [[ -x /usr/sbin/sshd && -f "$sshd_config" && ! -L "$sshd_config" ]] || die 'Expected regular /etc/ssh/sshd_config and /usr/sbin/sshd.'
}

# Never open, chmod, chown, or restore a user-controlled home path as root.
# Dropping privileges protects even when a path is replaced after a symlink
# check (including during rollback). No user input is interpolated into code.
run_as_target_user() {
    if [[ "$EUID" == "$user_id" ]]; then
        "$@"
    elif [[ "$platform" == Darwin ]]; then
        /usr/bin/sudo -H -u "#$user_id" -g "#$group_id" -- "$@"
    else
        /usr/sbin/runuser -u "$login_user" -- "$@"
    fi
}

user_key_task() {
    local task=$1 code
    shift
    code=$(cat <<'USER_KEY_SCRIPT'
set -eo pipefail
umask 077
task=$1; platform=$2; home=$3; shift 3
fail() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
mode() {
    if [[ "$platform" == Darwin ]]; then stat -f '%Lp' "$1"
    else stat -c '%a' "$1"; fi
}
cd -- "$home"
[[ ! -L .ssh ]] || fail 'Refusing a symlinked .ssh directory.'
if [[ -e .ssh ]]; then
    [[ -d .ssh && -O .ssh ]] || fail '.ssh must be a directory owned by the target user.'
    dir_existed=1; dir_mode=$(mode .ssh)
else dir_existed=0; dir_mode=0; fi

if [[ "$task" == snapshot && "$dir_existed" == 0 ]]; then
    printf '0 0 0 0\n'
    exit
fi
if [[ "$task" == restore && "$dir_existed" == 0 && "$1" == 0 ]]; then exit; fi
if [[ "$dir_existed" == 0 ]]; then mkdir -m 700 .ssh; fi
# Pin the working directory before operating on relative file names. All of
# these operations run as the account that already controls this directory.
cd -- .ssh
[[ -O . ]] || fail '.ssh must be owned by the target user.'
[[ ! -L authorized_keys ]] || fail 'Refusing a symlinked authorized_keys file.'
if [[ -e authorized_keys ]]; then
    [[ -f authorized_keys && -O authorized_keys ]] || fail 'authorized_keys must be a regular file owned by the target user.'
    keys_existed=1; keys_mode=$(mode authorized_keys)
else keys_existed=0; keys_mode=0; fi

stage=''
trap 'if [[ -n "$stage" ]]; then rm -f -- "$stage"; fi' EXIT
case "$task" in
    snapshot)
        printf '%s %s %s %s\n' "$dir_existed" "$dir_mode" "$keys_existed" "$keys_mode"
        if [[ "$keys_existed" == 1 ]]; then cat -- authorized_keys; fi
        ;;
    install)
        key_type=$1; key_data=$2; public_key=$3
        chmod 700 .
        stage=$(mktemp .authorized_keys.XXXXXXXX)
        if [[ "$keys_existed" == 1 ]]; then cat -- authorized_keys > "$stage"; fi
        if ! awk -v type="$key_type" -v data="$key_data" '$1 == type && $2 == data { found=1 } END { exit !found }' "$stage"; then
            printf '\n%s\n' "$public_key" >> "$stage"
        fi
        chmod 600 "$stage"
        mv -f -- "$stage" authorized_keys
        stage=''
        ;;
    restore)
        old_dir_existed=$1; old_dir_mode=$2; old_keys_existed=$3; old_keys_mode=$4
        if [[ "$old_keys_existed" == 1 ]]; then
            stage=$(mktemp .authorized_keys.XXXXXXXX)
            cat > "$stage"
            chmod "$old_keys_mode" "$stage"
            mv -f -- "$stage" authorized_keys
            stage=''
        else rm -f -- authorized_keys; fi
        if [[ "$old_dir_existed" == 1 ]]; then chmod "$old_dir_mode" .
        else cd ..; rmdir .ssh; fi
        ;;
    *) fail 'Unknown user-key operation.' ;;
esac
USER_KEY_SCRIPT
)
    run_as_target_user /bin/bash -c "$code" -- "$task" "$platform" "$user_home" "$@"
}

verify_effective_config() {
    local config=${1:-$sshd_config} remote local_ip output key_paths value
    for remote in "${remote_addresses[@]}"; do
        remote=${remote%%/*}
        for local_ip in "${local_addresses[@]}"; do
            output=$(/usr/sbin/sshd -T -f "$config" -C "user=$login_user,host=client.example.com,addr=$remote,laddr=$local_ip,lport=22")
            value=$(printf '%s\n' "$output" | awk '$1 == "pubkeyauthentication" { print $2 }')
            [[ "$value" == yes ]] || die 'Existing SSH policy disables public-key authentication.'
            key_paths=$(printf '%s\n' "$output" | awk '$1 == "authorizedkeysfile" { $1=""; print }')
            case " $key_paths " in
                *' .ssh/authorized_keys '*|*' %h/.ssh/authorized_keys '*|*" $authorized_keys "*) ;;
                *) die 'Existing AuthorizedKeysFile does not use the target ~/.ssh/authorized_keys.' ;;
            esac
            # A supplied destination must not be blocked by our own rules.
            if printf '%s\n' "$output" | awk '$1 == "denyusers" { for (i=2; i<=NF; i++) if ($i == "*") found=1 } END { exit !found }'; then
                die 'Effective sshd policy denies one of the supplied address combinations.'
            fi
        done
    done
}

activate_server() {
    if [[ "$platform" == Darwin ]]; then
        if ! /bin/launchctl print system/com.openssh.sshd >/dev/null 2>&1; then
            /usr/sbin/systemsetup -setremotelogin on
        fi
        /bin/launchctl print system/com.openssh.sshd >/dev/null || die 'Remote Login did not start. Enable it in System Settings > General > Sharing, then rerun.'
    else
        # Ubuntu may use socket activation: keep its sockets and port settings.
        systemctl enable ssh.service
        systemctl restart ssh.service
        systemctl is-active --quiet ssh.service
    fi
}

cleanup() {
    local status=$?
    trap - EXIT
    if [[ "$policy_created" == 1 ]]; then rm -f /usr/sbin/policy-rc.d; fi
    if [[ "$status" != 0 && "$files_changed" == 1 ]]; then
        printf '[WARN] Restoring SSH config and authorized_keys from this run.\n' >&2
        cp -p "$work_dir/config.before" "$sshd_config"
        user_key_task restore "$ssh_dir_existed" "$ssh_dir_mode" "$keys_existed" "$keys_mode" < "$work_dir/keys.before" || printf '[WARN] Could not restore user SSH files; inspect them as the target user.\n' >&2
        if [[ "$activation_started" == 1 && "$platform" == Linux ]]; then
            if [[ "$service_was_active" == 1 ]]; then
                systemctl restart ssh.service || printf '[WARN] Could not restart the restored SSH config; use the local console.\n' >&2
            else systemctl stop ssh.service || true; fi
            if [[ "$service_was_enabled" != enabled ]]; then systemctl disable ssh.service || true; fi
        elif [[ "$activation_started" == 1 && "$platform" == Darwin && "$service_was_active" == 0 ]]; then
            /usr/sbin/systemsetup -f -setremotelogin off || true
        fi
    fi
    if [[ -n "$work_dir" ]]; then rm -f "$work_dir/config.before" "$work_dir/config.base" "$work_dir/config.next" "$work_dir/key.snapshot" "$work_dir/keys.before"; rmdir "$work_dir"; fi
    if [[ -n "$staged_config" ]]; then rm -f "$staged_config"; fi
    if [[ "$lock_created" == 1 ]]; then rmdir /etc/ssh/.restricted-openssh.lock; fi
    exit "$status"
}

apply_configuration() {
    work_dir=$(mktemp -d /tmp/restricted-openssh.XXXXXXXX)
    cp -p "$sshd_config" "$work_dir/config.before"
    strip_managed_block "$sshd_config" > "$work_dir/config.base" || die 'Malformed managed block in sshd_config.'
    check_config_tree "$work_dir/config.base"
    { cat "$work_dir/config.base"; render_rules; } > "$work_dir/config.next"
    validate_sshd_config "$work_dir/config.next"
    verify_effective_config "$work_dir/config.next"
    user_key_task snapshot > "$work_dir/key.snapshot"
    read -r ssh_dir_existed ssh_dir_mode keys_existed keys_mode < "$work_dir/key.snapshot"
    [[ "$ssh_dir_existed" =~ ^[01]$ && "$keys_existed" =~ ^[01]$ && "$ssh_dir_mode" =~ ^[0-7]{1,4}$ && "$keys_mode" =~ ^[0-7]{1,4}$ ]] || die 'Invalid user-key snapshot metadata.'
    tail -n +2 "$work_dir/key.snapshot" > "$work_dir/keys.before"
    staged_config=$(mktemp "${sshd_config%/*}/.restricted-openssh.XXXXXXXX")
    cp -p "$sshd_config" "$staged_config"
    cat "$work_dir/config.next" > "$staged_config"
    files_changed=1
    mv -f "$staged_config" "$sshd_config"
    staged_config=''
    user_key_task install "$key_type" "$key_data" "$public_key"
    activation_started=1
    activate_server
    files_changed=0
}

validate_sshd_config() { /usr/sbin/sshd -t -f "${1:-$sshd_config}"; }

main() {
    local arg address key_comment
    if [[ "$EUID" == 0 ]]; then PATH=/usr/sbin:/usr/bin:/sbin:/bin; export PATH; fi
    login_user=''; public_key_file=''; dry_run=0
    local_addresses=(); remote_addresses=()
    while [[ $# -gt 0 ]]; do
        arg=$1; shift
        case "$arg" in
            -h|--help) usage; return ;;
            --dry-run) dry_run=1 ;;
            --user|--local-address|--remote-address|--public-key-file)
                [[ $# -gt 0 && -n "$1" && "$1" != --* ]] || die "Missing value for $arg"
                case "$arg" in
                    --user) login_user=$1 ;;
                    --local-address) local_addresses+=("$1") ;;
                    --remote-address) remote_addresses+=("$1") ;;
                    --public-key-file) public_key_file=$1 ;;
                esac
                shift ;;
            *) die "Unknown argument: $arg" ;;
        esac
    done
    [[ "$login_user" =~ ^[a-zA-Z_][a-zA-Z0-9_-]*\$?$ && "$login_user" != root ]] || die '--user must name an existing non-root account.'
    [[ ${#local_addresses[@]} -gt 0 && ${#remote_addresses[@]} -gt 0 && -r "$public_key_file" ]] || die 'Supply --local-address, --remote-address, and a readable --public-key-file.'
    for address in "${local_addresses[@]}"; do validate_address "$address" 0 >/dev/null || die "Invalid destination IP: $address"; done
    for address in "${remote_addresses[@]}"; do validate_address "$address" 1 >/dev/null || die "Invalid client IP/CIDR (use a network address for CIDR): $address"; done
    # Only a single plain public key is accepted; no options or extra key lines.
    public_key=$(awk 'NF { sub(/\r$/, ""); if (++n > 1) exit 2; key=$0 } END { if (n == 1) print key; else exit 2 }' "$public_key_file") || die 'Expected exactly one public key.'
    IFS=' ' read -r key_type key_data key_comment <<< "$public_key"
    case "$key_type" in ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com) ;; *) die 'Unsupported public key type or authorized_keys options.' ;; esac
    [[ "$key_data" =~ ^[A-Za-z0-9+/]+={0,3}$ ]] || die 'Malformed public key.'
    command -v ssh-keygen >/dev/null || die 'Install the OpenSSH client (ssh-keygen) first.'
    ssh-keygen -lf "$public_key_file" >/dev/null || die 'ssh-keygen rejected the public key.'
    detect_platform
    if [[ "$dry_run" == 1 ]]; then
        log "Platform: $platform; target account: $login_user"
        log 'Would ensure OpenSSH/Remote Login, install the public key, validate config, and activate SSH.'
        log 'Would append/replace these sshd rules (no firewall changes):'
        render_rules
        log 'Existing accounts, key paths, Include files, and conflicts are checked during apply.'
        return
    fi
    [[ "$EUID" == 0 ]] || die 'Run with sudo on the target machine, or use --dry-run.'
    umask 077
    # Root operations must not resolve administrative commands from user PATH.
    PATH=/usr/sbin:/usr/bin:/sbin:/bin; export PATH
    sshd_config=/etc/ssh/sshd_config
    resolve_user
    if [[ "$platform" == Linux ]]; then
        [[ -x /usr/sbin/runuser ]] || die 'Install util-linux (runuser) before applying configuration.'
    fi
    mkdir -p /etc/ssh
    mkdir /etc/ssh/.restricted-openssh.lock || die 'Another run holds /etc/ssh/.restricted-openssh.lock; resolve it before retrying.'
    lock_created=1
    ensure_server
    service_was_active=0
    if [[ "$platform" == Linux ]]; then
        systemctl is-active --quiet ssh.service && service_was_active=1
        service_was_enabled=$(systemctl is-enabled ssh.service 2>/dev/null || true)
        [[ "$service_was_enabled" != masked && "$service_was_enabled" != masked-runtime ]] || die 'SSH service is masked; resolve the service policy first.'
    else
        /bin/launchctl print system/com.openssh.sshd >/dev/null 2>&1 && service_was_active=1
    fi
    apply_configuration
    log "SSH configured for $login_user. Existing keys were preserved; the allowlist was replaced."
    log 'Only the selected user and supplied source/destination addresses may authenticate.'
    log 'Keep the local console available until a real client login succeeds; firewalls and router rules still apply.'
    if [[ "$platform" == Darwin ]]; then
        log 'If Remote Login uses Only these users, include the selected account in System Settings > General > Sharing.'
    fi
}

# Guard permits offline tests to source and exercise the policy builder.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    work_dir=''; staged_config=''; files_changed=0; keys_existed=0; ssh_dir_existed=0
    activation_started=0; policy_created=0; lock_created=0
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    main "$@"
fi
