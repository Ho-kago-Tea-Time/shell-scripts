#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
script=$repo/git/unix/setup-git-ssh.sh
mkdir -p "$repo/.tools"
root=$(mktemp -d "$repo/.tools/git-ssh-bash-tests.XXXXXXXX")
cleanup() {
  case "$root" in "$repo"/.tools/git-ssh-bash-tests.*) rm -rf -- "$root" ;; *) printf 'Unsafe cleanup path\n' >&2; return 1 ;; esac
}
trap cleanup EXIT
mkdir -p "$root/bin"
cp "$repo/git/tests/fixtures/curl" "$repo/git/tests/fixtures/gh" "$root/bin/"
chmod +x "$root/bin/curl" "$root/bin/gh"
export PATH="$root/bin:$PATH" GIT_SSH_TEST_TOKEN=test-secret
export MOCK_API_URL=https://api.github.com MOCK_GH_HOST=github.com
export MOCK_ACCOUNT=demo MOCK_FAIL_LIST=0 MOCK_FAIL_UPLOAD=0 MOCK_PAGINATE=0
passed=0
fail() { printf 'FAIL: %s\n' "$*" >&2; cat "$root/output" >&2; exit 1; }
ok() { passed=$((passed + 1)); printf 'PASS: %s\n' "$*"; }
new_case() {
  state=$root/$1
  mkdir -p "$state"
  export MOCK_STATE=$state MOCK_ACCOUNT=demo MOCK_FAIL_LIST=0 MOCK_FAIL_UPLOAD=0 MOCK_PAGINATE=0
  export MOCK_API_URL=https://api.github.com MOCK_GH_HOST=github.com
  key=$state/key config=$state/config
}
run() {
  bash "$script" --account demo --key-path "$key" --ssh-config-path "$config" "$@" > "$root/output" 2>&1
}
expect_error() {
  if run "$@"; then fail 'Expected failure'; fi
  if grep -q test-secret "$root/output"; then fail 'Token leaked'; fi
}

new_case dry
run --dry-run --configure-ssh || fail 'Dry run'
[[ ! -e "$key" && ! -e "$config" && ! -e "$state/requests" && ! -e "$state/gh-requests" ]] || fail 'Dry run had side effects'
ok 'Offline dry run does not read credentials or write files'

new_case github
run --no-passphrase --configure-ssh || fail 'GitHub creation'
[[ -f "$key" && -f "$key.pub" ]] || fail 'Keys missing'
grep -q 'auth token --hostname github.com --user demo' "$state/gh-requests" || fail 'Wrong gh identity'
ssh-keygen -y -f "$key" > "$state/derived"
[[ "$(awk '{print $1 " " $2}' "$key.pub")" == "$(awk '{print $1 " " $2}' "$state/derived")" ]] || fail 'Key pair mismatch'
before=$(cat "$key")
run --no-passphrase --configure-ssh || fail 'GitHub reuse'
[[ "$(grep -c '^POST ' "$state/requests")" == 1 && "$(grep -c '^Host github-demo$' "$config")" == 1 ]] || fail 'Rerun duplicated upload or config'
[[ "$(cat "$key")" == "$before" ]] || fail 'Private key changed'
ok 'GitHub gh account selection, real key generation, and idempotent rerun'

new_case enterprise
export MOCK_API_URL=https://github.example.com/api/v3 MOCK_GH_HOST=github.example.com
run --server-url https://github.example.com --no-passphrase || fail 'GHES API mapping'
ok 'GitHub Enterprise Server API and gh hostname'

new_case gitlab
export MOCK_API_URL=https://git.example.com:8443/team/api/v4
run --provider gitlab --server-url https://git.example.com:8443/team --token-env GIT_SSH_TEST_TOKEN --no-passphrase --configure-ssh --ssh-port 2222 --ssh-host ssh.example.com --ssh-user vcs || fail 'Self-managed GitLab'
jq -e '.usage_type == "auth" and (.key | startswith("ssh-ed25519 "))' "$state/upload.json" >/dev/null || fail 'GitLab upload payload'
grep -q 'Port 2222' "$config" && grep -q 'HostName ssh.example.com' "$config" && grep -q 'User vcs' "$config" || fail 'SSH overrides'
export MOCK_PAGINATE=1
run --provider gitlab --server-url https://git.example.com:8443/team --token-env GIT_SSH_TEST_TOKEN --no-passphrase --configure-ssh --ssh-port 2222 --ssh-host ssh.example.com --ssh-user vcs || fail 'GitLab pagination'
grep -q 'page=2' "$state/requests" || fail 'Second page missing'
[[ "$(grep -c '^POST ' "$state/requests")" == 1 ]] || fail 'Duplicate key on second page was uploaded'
ok 'Self-managed GitLab path/port, auth-only payload, SSH overrides, and pagination'

new_case gitlab-official
export MOCK_API_URL=https://gitlab.com/api/v4 GITLAB_TOKEN=test-secret
run --provider gitlab --no-passphrase || fail 'GitLab official default token'
ok 'GitLab.com and default GITLAB_TOKEN'

new_case identity
export MOCK_ACCOUNT=someone-else
expect_error --no-passphrase
[[ ! -e "$key" && ! -e "$state/upload.json" ]] || fail 'Wrong-account request wrote keys'
ok 'Wrong-account credential fails before key creation'

new_case permission
export MOCK_FAIL_LIST=1
expect_error --no-passphrase
[[ ! -e "$key" ]] || fail 'Permission failure created keys'
ok 'List permission failure precedes key creation'

new_case conflict
printf 'Host other github-demo\n    User git\n' > "$config"
expect_error --no-passphrase --configure-ssh
[[ ! -e "$key" && ! -e "$state/requests" ]] || fail 'Config conflict was detected too late'
ok 'Multi-name Host conflict fails before credentials and writes'

new_case include-conflict
printf 'Host github-demo\n    User git\n' > "$state/included file"
printf 'Include "%s"\n' "$state/included file" > "$config"
expect_error --no-passphrase --configure-ssh
[[ ! -e "$state/requests" ]] || fail 'Included alias conflict detected too late'
ok 'Quoted Include path is checked for alias conflicts'

new_case wildcard-default
printf 'ServerAliveInterval 37\nHost *\n    User fallback\n' > "$config"
run --no-passphrase --configure-ssh || fail 'Wildcard defaults'
[[ "$(head -n 1 "$config")" == '# BEGIN setup-git-ssh github-demo' ]] || fail 'Specific Host must precede wildcard defaults'
grep -q 'User fallback' "$config" || fail 'Original config was lost'
if command -v ssh >/dev/null 2>&1; then
  ssh -G -F "$config" github-demo > "$state/effective-alias" 2>/dev/null
  ssh -G -F "$config" unrelated.example.com > "$state/effective-other" 2>/dev/null
  grep -q '^user git$' "$state/effective-alias" || fail 'Managed User lost precedence'
  grep -q '^serveraliveinterval 37$' "$state/effective-other" || fail 'Original global settings lost their scope'
fi
ok 'Specific Host is prepended while retaining wildcard defaults'

new_case mismatched-public
ssh-keygen -q -t ed25519 -N '' -f "$key"
ssh-keygen -q -t ed25519 -N '' -f "$state/other"
cp "$state/other.pub" "$key.pub"
expect_error --no-passphrase
[[ ! -e "$state/upload.json" ]] || fail 'Mismatched public key was uploaded'
ok 'Public/private mismatch is rejected'

new_case missing-public
ssh-keygen -q -t ed25519 -N '' -f "$key"
rm "$key.pub"
run --no-passphrase || fail 'Public key recovery'
[[ -f "$key.pub" ]] || fail 'Public key not recovered'
ok 'Missing public key is derived from existing private key'

new_case rsa
run --type rsa --bits 2048 --no-passphrase || fail 'RSA creation'
expect_error --type rsa --bits 4096 --no-passphrase
expect_error --type ed25519 --no-passphrase
ok 'RSA generation and existing algorithm/bit-count validation'

new_case ecdsa
run --type ecdsa --bits 384 --no-passphrase || fail 'ECDSA creation'
ok 'ECDSA P-384 generation'

new_case upload-failure
export MOCK_FAIL_UPLOAD=1
expect_error --no-passphrase --configure-ssh
[[ -f "$key" && -f "$key.pub" && ! -e "$config" ]] || fail 'Failed upload did not retain only the keys'
export MOCK_FAIL_UPLOAD=0
run --no-passphrase --configure-ssh || fail 'Retry after upload failure'
ok 'Upload failure retains key pair and permits retry'

new_case validation
expect_error --type ed25519 --bits 256
expect_error --type rsa --bits 1024
expect_error --server-url http://git.example.com
expect_error --server-url https://user:password@git.example.com
expect_error --server-url https://git.example.com:99999
expect_error --ssh-port 0
[[ ! -e "$state/requests" ]] || fail 'Invalid inputs contacted the API'
ok 'Invalid algorithms, URLs, and ports fail offline'

new_case signed-only
export MOCK_API_URL=https://gitlab.com/api/v4 GITLAB_TOKEN=test-secret
ssh-keygen -q -t ed25519 -N '' -f "$key"
jq -n --arg key "$(cat "$key.pub")" '[{key:$key,usage_type:"signing"}]' > "$state/keys.json"
expect_error --provider gitlab --no-passphrase
[[ ! -e "$state/upload.json" ]] || fail 'Signing-only key caused upload'
ok 'GitLab signing-only duplicate is not treated as usable authentication'

new_case expired
export MOCK_API_URL=https://gitlab.com/api/v4 GITLAB_TOKEN=test-secret
ssh-keygen -q -t ed25519 -N '' -f "$key"
jq -n --arg key "$(cat "$key.pub")" '[{key:$key,usage_type:"auth",expires_at:"2000-01-01T00:00:00.000Z"}]' > "$state/keys.json"
expect_error --provider gitlab --no-passphrase
[[ ! -e "$state/upload.json" ]] || fail 'Expired key caused upload'
ok 'Expired GitLab duplicate is rejected'

if grep -q test-secret "$root/output"; then fail 'Token leaked'; fi
printf '\n%d offline Bash scenarios passed.\n' "$passed"
