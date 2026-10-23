#!/usr/bin/env bash
# Compatible with the Bash 3.2 shipped by macOS.
set -euo pipefail
# Credentials must never be exposed by caller-enabled shell tracing.
set +x

die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
log() { printf '[INFO] %s\n' "$*"; }
usage() {
  cat <<'EOF'
Usage: bash setup-git-ssh.sh --account USER [options]

  --provider github|gitlab  Default: github
  --server-url URL         HTTPS Web URL; default: https://github.com or https://gitlab.com
  --account USER           Required expected account (verified before key creation)
  --token-env NAME         Read token from this environment variable; GitLab default: GITLAB_TOKEN
                          GitHub default: gh auth token --hostname HOST --user USER
  --type ed25519|rsa|ecdsa  Default: ed25519
  --bits N                RSA: 2048/3072/4096 (default 4096); ECDSA: 256/384/521 (default 256)
  --key-path PATH         Default: ~/.ssh/id_TYPE_PROVIDER_INSTANCE_ACCOUNT
  --title TEXT            Key title; default: COMPUTER-ACCOUNT
  --comment TEXT          Key comment; default: ACCOUNT@COMPUTER
  --no-passphrase         Create an unencrypted key; otherwise ssh-keygen prompts
  --configure-ssh         Add a managed Host block to ~/.ssh/config
  --ssh-config-path PATH Override the config file (default: ~/.ssh/config)
  --ssh-alias NAME        Default: PROVIDER-ACCOUNT (custom instances include the instance)
  --ssh-host HOST         Default: Web hostname
  --ssh-port PORT         Default: 22
  --ssh-user USER         Default: git
  --dry-run              Print the plan without network, credentials, or file writes
  -h, --help             Show help

Requires OpenSSH ssh-keygen, curl, and jq. GitHub also requires gh unless --token-env is used.
GitHub Enterprise Server uses /api/v3; GitLab uses /api/v4 (including Web path prefixes).
EOF
}

provider=github server_url= account= token_env= key_type=ed25519 bits= key_path= config_path=
title= comment= configure_ssh=0 ssh_alias= ssh_host= ssh_port=22 ssh_user=git
no_passphrase=0 dry_run=0 work_dir=
cleanup() { if [[ -n "$work_dir" ]]; then rm -rf -- "$work_dir"; fi; }
trap cleanup EXIT
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-passphrase) no_passphrase=1; shift ;;
    --configure-ssh) configure_ssh=1; shift ;;
    --dry-run) dry_run=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --provider|--server-url|--account|--token-env|--type|--bits|--key-path|--title|--comment|--ssh-alias|--ssh-host|--ssh-port|--ssh-user|--ssh-config-path)
      [[ $# -ge 2 && -n "$2" ]] || die "Missing value for $1"
      case "$1" in
        --provider) provider=$2 ;; --server-url) server_url=$2 ;; --account) account=$2 ;;
        --token-env) token_env=$2 ;; --type) key_type=$2 ;; --bits) bits=$2 ;;
        --key-path) key_path=$2 ;; --title) title=$2 ;; --comment) comment=$2 ;;
        --ssh-alias) ssh_alias=$2 ;; --ssh-host) ssh_host=$2 ;; --ssh-port) ssh_port=$2 ;;
        --ssh-user) ssh_user=$2 ;;
        --ssh-config-path) config_path=$2 ;;
      esac
      shift 2 ;;
    *) die "Unknown argument: $1 (use --help)" ;;
  esac
done
[[ "$provider" == github || "$provider" == gitlab ]] || die 'Provider must be github or gitlab.'
[[ "$account" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || die 'A valid --account is required.'
bits_explicit=0
[[ -z "$bits" ]] || bits_explicit=1
case "$key_type" in
  ed25519) [[ -z "$bits" ]] || die 'Ed25519 does not accept --bits.' ;;
  rsa) bits=${bits:-4096}; [[ "$bits" == 2048 || "$bits" == 3072 || "$bits" == 4096 ]] || die 'RSA bits: 2048, 3072, 4096.' ;;
  ecdsa) bits=${bits:-256}; [[ "$bits" == 256 || "$bits" == 384 || "$bits" == 521 ]] || die 'ECDSA bits: 256, 384, 521.' ;;
  *) die 'Type must be ed25519, rsa, or ecdsa.' ;;
esac
server_url=${server_url:-https://$provider.com}
while [[ "$server_url" == */ ]]; do server_url=${server_url%/}; done
# DNS/IPv4 hosts, optional HTTPS port and Web path prefix. Credentials/query/fragment are rejected.
[[ "$server_url" =~ ^https://([a-zA-Z0-9][a-zA-Z0-9.-]*)(:([0-9]+))?(/[a-zA-Z0-9._~/-]*)?$ ]] || die 'Server URL must be HTTPS with a DNS/IPv4 host and optional port/path; no credentials, query, or fragment.'
web_host=${BASH_REMATCH[1]}
web_port=${BASH_REMATCH[3]:-443}
[[ "$web_port" =~ ^[0-9]{1,5}$ ]] && (( 10#$web_port >= 1 && 10#$web_port <= 65535 )) || die 'Invalid HTTPS port.'
authority=${server_url#https://}; authority=${authority%%/*}
instance=${server_url#https://}
instance=$(printf '%s' "$instance" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C sed 's/[^a-z0-9._-]/_/g')
if [[ "$provider" == github && "$server_url" == https://github.com ]]; then
  api_url=https://api.github.com
else
  if [[ "$provider" == github ]]; then api_url=$server_url/api/v3; else api_url=$server_url/api/v4; fi
fi
ssh_host=${ssh_host:-$web_host}
[[ "$ssh_host" =~ ^[a-zA-Z0-9][a-zA-Z0-9.:-]*$ ]] || die 'Invalid SSH hostname.'
[[ "$ssh_user" =~ ^[a-zA-Z0-9_][a-zA-Z0-9._-]*$ ]] || die 'Invalid SSH user.'
[[ "$ssh_port" =~ ^[0-9]{1,5}$ ]] && (( 10#$ssh_port >= 1 && 10#$ssh_port <= 65535 )) || die 'SSH port must be 1..65535.'
ssh_port=$((10#$ssh_port))
if [[ -z "$ssh_alias" ]]; then
  if [[ "$server_url" == https://$provider.com ]]; then ssh_alias=$provider-$account; else ssh_alias=$provider-$instance-$account; fi
fi
[[ "$ssh_alias" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || die 'SSH alias must contain only letters, numbers, dot, underscore, or hyphen.'
key_path=${key_path:-$HOME/.ssh/id_${key_type}_${provider}_${instance}_${account}}
case "$key_path" in '~/'*) key_path=$HOME/${key_path:2} ;; esac
[[ "$key_path" == /* ]] || key_path=$PWD/$key_path
computer=$(hostname -s 2>/dev/null || hostname)
title=${title:-$computer-$account}
comment=${comment:-$account@$computer}
for value in "$key_path" "$title" "$comment"; do
  [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || die 'Paths, titles, and comments must be single-line values.'
done
if [[ -n "$token_env" ]]; then [[ "$token_env" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || die 'Invalid token environment variable name.'; fi
if [[ "$provider" == gitlab && -z "$token_env" ]]; then token_env=GITLAB_TOKEN; fi
config_path=${config_path:-$HOME/.ssh/config}
case "$config_path" in '~/'*) config_path=$HOME/${config_path:2} ;; esac
[[ "$config_path" == /* ]] || config_path=$PWD/$config_path
[[ "$config_path" != *$'\n'* && "$config_path" != *$'\r'* ]] || die 'Config path must be a single-line value.'
# Escape OpenSSH's quoted-path syntax and percent expansion.
identity_path=${key_path//\\/\\\\}; identity_path=${identity_path//\"/\\\"}; identity_path=${identity_path//%/%%}
block=$(printf '# BEGIN setup-git-ssh %s\nHost %s\n    HostName %s\n    Port %s\n    User %s\n    IdentityFile "%s"\n    IdentitiesOnly yes\nHost *\n# END setup-git-ssh %s' "$ssh_alias" "$ssh_alias" "$ssh_host" "$ssh_port" "$ssh_user" "$identity_path" "$ssh_alias")
config_exists=0
scanned_configs=
check_included_configs() {
  local file=$1 depth=$2 directives kind value pattern included
  (( depth <= 32 )) || die 'Too many nested SSH Include directives.'
  case "$scanned_configs" in *"|$file|"*) return 0 ;; esac
  scanned_configs=$scanned_configs"|$file|"
  directives=$(awk '
    {
      line=$0; sub(/\r$/, "", line); sub(/^[ \t]+/, "", line);
      if(!match(line,/^[^ \t=#]+/)) next;
      kind=tolower(substr(line,1,RLENGTH)); line=substr(line,RLENGTH+1);
      if(kind!="host" && kind!="include") next;
      sub(/^[ \t=]+/, "", line);
      while(length(line) && line !~ /^#/) {
        if(line ~ /^"/) { line=substr(line,2); if(!match(line,/"/)) exit 1; value=substr(line,1,RSTART-1); line=substr(line,RSTART+1) }
        else { match(line,/^[^ \t]+/); value=substr(line,1,RLENGTH); line=substr(line,RLENGTH+1) }
        print kind "\t" value; sub(/^[ \t]+/, "", line);
      }
    }' "$file") || die "Cannot parse SSH config: $file"
  while IFS=$'\t' read -r kind value; do
    if [[ "$kind" == host && "$depth" != 0 ]]; then
      [[ "$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')" != "$(printf '%s' "$ssh_alias" | tr '[:upper:]' '[:lower:]')" ]] || die "SSH alias '$ssh_alias' already exists in included file: $file"
    elif [[ "$kind" == include ]]; then
      [[ "$value" != *'$'* && "$value" != *%* ]] || die 'Include paths using environment/token expansion require manual SSH config editing.'
      case "$value" in
        '~/'*) pattern=$HOME/${value:2} ;;
        /*) pattern=$value ;;
        '~'*) die 'Include paths for other home directories require manual SSH config editing.' ;;
        *) pattern=$HOME/.ssh/$value ;;
      esac
      while IFS= read -r included; do
        [[ -f "$included" ]] || continue
        check_included_configs "$included" "$((depth + 1))"
      done < <(compgen -G "$pattern" || true)
    fi
  done <<< "$directives"
}
check_config() {
  [[ "$configure_ssh" == 1 ]] || return 0
  [[ ! -L "$config_path" ]] || die "Refusing to edit symlink: $config_path"
  [[ ! -e "$config_path" || -f "$config_path" ]] || die 'SSH config must be a regular file.'
  [[ -f "$config_path" ]] || return 0
  scanned_configs=
  check_included_configs "$config_path" 0
  local state
  # Only this tool's exact block is reusable. Detect explicit aliases even in multi-name Host lines.
  state=$(awk -v alias="$ssh_alias" -v expected="$block" '
    BEGIN { inside=0; count=0; collision=0; found="" }
    { sub(/\r$/, "", $0) }
    $0 == "# BEGIN setup-git-ssh " alias { if (inside) collision=1; inside=1; count++; next }
    $0 == "# END setup-git-ssh " alias { if (!inside) collision=1; inside=0; next }
    inside { found=found $0 "\n"; next }
    { line=$0; sub(/\r$/, "", line); sub(/#.*/, "", line); gsub(/=/, " ", line); n=split(line, words, /[ \t]+/);
      first=1; while(first<=n && words[first]=="") first++;
      if(tolower(words[first])=="host") for(i=first+1;i<=n;i++) { gsub(/^"|"$/, "", words[i]); if(tolower(words[i])==tolower(alias)) collision=1; }
    }
    END {
      sub(/^[^\n]*\n/, "", expected); sub(/\n#[^\n]*$/, "", expected);
      sub(/\n$/, "", found);
      if(inside || count>1 || collision || (count==1 && found!=expected)) print "conflict";
      else if(count==1) print "exists"; else print "new";
    }' "$config_path")
  [[ "$state" != conflict ]] || die "SSH alias '$ssh_alias' already exists or its managed block differs; choose --ssh-alias or edit $config_path manually."
  [[ "$state" != exists ]] || config_exists=1
}
check_config
[[ ! -L "$key_path" && ! -L "$key_path.pub" ]] || die 'Key paths must not be symlinks.'
[[ ! -e "$key_path" || -f "$key_path" ]] || die 'Private key path must be a regular file.'
[[ ! -e "$key_path.pub" || -f "$key_path.pub" ]] || die 'Public key path must be a regular file.'
[[ -f "$key_path" || ! -e "$key_path.pub" ]] || die 'Public key exists without the private key; select another --key-path.'
log "Provider: $provider; server: $server_url; expected account: $account"
log "Key: $key_path; algorithm: $key_type${bits:+ ($bits bits)}"
if [[ "$dry_run" == 1 ]]; then
  if [[ -f "$key_path" ]]; then log 'Would validate and reuse the existing private key.'; else log 'Would generate a new key.'; fi
  log "Would verify identity, list keys, and upload if absent using $api_url."
  if [[ "$configure_ssh" == 1 ]]; then printf '%s\n' "$block"; fi
  exit 0
fi
for dependency in ssh-keygen curl jq; do command -v "$dependency" >/dev/null 2>&1 || die "Missing dependency: $dependency. Install it and rerun."; done
if [[ -n "$token_env" ]]; then
  token=${!token_env:-}
  [[ -n "$token" ]] || die "Environment variable $token_env is empty."
else
  command -v gh >/dev/null 2>&1 || die 'Install GitHub CLI (gh), or use --token-env NAME.'
  token=$(gh auth token --hostname "$authority" --user "$account" 2>/dev/null) || die "No usable gh credential for $account on $authority. Run: gh auth login --hostname $authority"
fi
[[ -n "$token" && "$token" != *[[:space:]\"\\]* ]] || die 'Token is empty or contains unsupported whitespace/quote/backslash characters.'
umask 077
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/setup-git-ssh.XXXXXXXX")
api() {
  local method=$1 endpoint=$2 payload=${3:-} status
  local args=(--disable --silent --show-error --proto '=https' --connect-timeout 15 --max-time 60 --max-redirs 0
    --config - --request "$method" --output "$work_dir/response.json" --write-out '%{http_code}'
    --header 'Accept: application/json' "$api_url$endpoint")
  if [[ "$method" == POST ]]; then args+=(--header 'Content-Type: application/json' --data-binary "$payload"); fi
  # Token is sent through stdin, never a process argument or a temporary file. Redirects are not followed.
  if ! status=$(printf 'header = "Authorization: Bearer %s"\n' "$token" | curl "${args[@]}"); then die 'API connection failed. Check URL, connectivity, and trusted TLS certificates.'; fi
  case "$status" in
    200|201) ;;
    401) die 'API authentication failed (401). Check the selected account and token.' ;;
    403) die 'API access denied (403). GitHub needs read:public_key/write:public_key; GitLab PAT needs api. Check instance policies too.' ;;
    *) die "API $method $endpoint failed (HTTP $status). Check permissions, key policy, expiry, or whether this key belongs to another account. Local keys are retained." ;;
  esac
  jq -e . "$work_dir/response.json" >/dev/null || die 'API returned invalid JSON.'
}
api GET /user
if [[ "$provider" == github ]]; then actual=$(jq -er '.login | select(type == "string")' "$work_dir/response.json"); else actual=$(jq -er '.username | select(type == "string")' "$work_dir/response.json"); fi
[[ "$(printf '%s' "$actual" | tr '[:upper:]' '[:lower:]')" == "$(printf '%s' "$account" | tr '[:upper:]' '[:lower:]')" ]] || die "Credential belongs to '$actual', expected '$account'. No key was created or uploaded."
log "Verified account: $actual"
page=1
: > "$work_dir/keys.jsonl"
while :; do
  api GET "/user/keys?per_page=100&page=$page"
  jq -e 'type == "array" and all(.[]; (.key | type) == "string")' "$work_dir/response.json" >/dev/null || die 'Unexpected public-key list response.'
  jq -c '.[]' "$work_dir/response.json" >> "$work_dir/keys.jsonl"
  count=$(jq 'length' "$work_dir/response.json")
  [[ "$count" == 100 ]] || break
  page=$((page + 1))
done
if [[ ! -f "$key_path" ]]; then
  parent=${key_path%/*}
  mkdir -p -- "$parent"
  # Generate beside the final path so a hard link publishes it atomically without overwriting a race winner.
  stage=$(mktemp -d "$parent/.setup-git-ssh.XXXXXXXX")
  args=(-q -t "$key_type" -f "$stage/key" -C "$comment")
  [[ -z "$bits" ]] || args+=(-b "$bits")
  [[ "$no_passphrase" == 0 ]] || args+=(-N '')
  if ! ssh-keygen "${args[@]}"; then rm -rf -- "$stage"; die 'Key generation failed.'; fi
  chmod 600 "$stage/key"
  if ! ln "$stage/key" "$key_path"; then rm -rf -- "$stage"; die 'Private key path appeared during generation; rerun to validate it.'; fi
  if ! ln "$stage/key.pub" "$key_path.pub"; then rm -rf -- "$stage"; die 'Public key path appeared during generation; private key was retained.'; fi
  rm -rf -- "$stage"
fi
chmod 600 "$key_path"
# Derive from the private key even when .pub exists, preventing mismatched public-key uploads.
derived=$(ssh-keygen -y -f "$key_path") || die 'Cannot read private key (check its format and passphrase).'
normalized=$(printf '%s\n' "$derived" | awk '{print $1 " " $2}')
case "$key_type:$normalized" in
  ed25519:ssh-ed25519\ *|rsa:ssh-rsa\ *|ecdsa:ecdsa-sha2-nistp*\ *) ;;
  *) die "Existing private key is not $key_type; select another --key-path or --type." ;;
esac
printf '%s\n' "$normalized" > "$work_dir/public.pub"
fingerprint=$(ssh-keygen -lf "$work_dir/public.pub" -E sha256) || die 'Invalid derived public key.'
actual_bits=${fingerprint%% *}
if [[ "$bits_explicit" == 1 && "$actual_bits" != "$bits" ]]; then die "Existing private key has $actual_bits bits, requested $bits."; fi
if [[ -f "$key_path.pub" ]]; then
  existing=$(awk 'NF {print $1 " " $2; count++} END {if(count!=1) exit 1}' "$key_path.pub") || die 'Public key file must contain exactly one key.'
  [[ "$existing" == "$normalized" ]] || die 'Public key does not match the private key; no key was uploaded.'
else
  # noclobber prevents replacing a file created concurrently.
  (set -o noclobber; printf '%s %s\n' "$normalized" "$comment" > "$key_path.pub") || die 'Public key path appeared; rerun to validate it.'
fi
chmod 644 "$key_path.pub"
matches=$(jq -s --arg key "$normalized" '[.[] | select((.key | split(" ") | map(select(length > 0)) | .[0:2] | join(" ")) == $key)] | length' "$work_dir/keys.jsonl")
if [[ "$matches" != 0 ]]; then
  if [[ "$provider" == gitlab ]]; then
    jq -es --arg key "$normalized" '
      def usable_expiry:
        if . == null or . == "" then true else
          (if test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$") then . + "T00:00:00Z"
           else sub("\\.[0-9]+Z$"; "Z") | sub("\\+00:00$"; "Z") end | fromdateiso8601) > now
        end;
      any(.[]; ((.key | split(" ") | map(select(length > 0)) | .[0:2] | join(" ")) == $key)
        and (.usage_type != "signing") and (.expires_at | usable_expiry))' "$work_dir/keys.jsonl" >/dev/null || die 'Matching GitLab key is signing-only or expired; update it manually.'
  fi
  log 'Public key already registered; upload skipped.'
else
  payload=$(jq -n --arg title "$title" --arg key "$(cat "$key_path.pub")" '{title:$title,key:$key}')
  if [[ "$provider" == gitlab ]]; then payload=$(printf '%s' "$payload" | jq '. + {usage_type:"auth"}'); fi
  api POST /user/keys "$payload"
  log 'Public key added successfully.'
fi
if [[ "$configure_ssh" == 1 ]]; then
  config_exists=0
  check_config
  if [[ "$config_exists" == 0 ]]; then
    mkdir -p -- "${config_path%/*}"
    config_stage=$(mktemp "$config_path.tmp.XXXXXXXX")
    # Place specific settings before existing Host * defaults (OpenSSH uses the first scalar value).
    printf '%s\n\n' "$block" > "$config_stage"
    if [[ -f "$config_path" ]]; then
      cat "$config_path" >> "$config_stage"
      mv -f -- "$config_stage" "$config_path"
    else
      if ! ln "$config_stage" "$config_path"; then rm -f -- "$config_stage"; die 'SSH config appeared concurrently; rerun.'; fi
      rm -f -- "$config_stage"
    fi
    chmod 600 "$config_path"
    log "SSH alias configured: $ssh_alias"
  else log "SSH alias already configured: $ssh_alias"; fi
fi
unset token
log "Fingerprint: $fingerprint"
if [[ "$configure_ssh" == 1 ]]; then
  printf 'Test: ssh -T %q\n' "$ssh_alias"
  printf 'Clone: git clone %q\n' "$ssh_alias:OWNER/REPO.git"
else
  printf 'Test: ssh -T -o IdentitiesOnly=yes -i %q -p %q %q\n' "$key_path" "$ssh_port" "$ssh_user@$ssh_host"
fi
