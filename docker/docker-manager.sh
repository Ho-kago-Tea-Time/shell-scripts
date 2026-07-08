#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="${0##*/}"

ACTION=""
INSTALL_COMPOSE=1
ENABLE_SERVICE=1
VERIFY_INSTALL=1
RUN_HELLO_WORLD=0
PURGE_DATA=0
KEEP_REPO=0
DRY_RUN=0
ADD_USER=""
FORCE_DISTRO=""
CODENAME_OVERRIDE=""
REPO_BASE_URL="${DOCKER_REPO_BASE_URL:-https://download.docker.com/linux}"

OS_ID=""
OS_ID_LIKE=""
OS_VERSION_CODENAME=""
OS_UBUNTU_CODENAME=""
ADAPTER=""
DOCKER_REPO_ID=""
APT_SUITE=""

ENGINE_PACKAGES=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin)
COMPOSE_PACKAGE=docker-compose-plugin
ROOTLESS_PACKAGE=docker-ce-rootless-extras

log() {
  printf '[INFO] %s\n' "$*"
}

warn() {
  printf '[WARN] %s\n' "$*" >&2
}

die() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<EOF
Usage:
  sudo ./$SCRIPT_NAME install [options]
  sudo ./$SCRIPT_NAME uninstall [options]

Actions:
  install                 Install Docker Engine. Compose plugin is installed by default.
  uninstall               Remove Docker packages. Docker data is kept unless --purge-data is set.

Common options:
  --with-compose          Install/remove Docker Compose CLI plugin (default).
  --without-compose       Do not install/remove Docker Compose CLI plugin.
  --distro ID             Override distro adapter: ubuntu, debian, fedora, centos, rhel.
  --codename NAME         Override apt suite codename, useful for distro derivatives.
  --repo-base-url URL     Override Docker repo base URL (default: $REPO_BASE_URL).
  --dry-run               Print commands without executing them.
  -h, --help              Show this help.

Install options:
  --no-enable             Do not enable/start docker.service automatically.
  --no-verify             Skip docker/docker compose version checks.
  --run-hello-world       Run the official hello-world container after install.
  --add-user USER         Add USER to the docker group after install.
  --add-current-user      Add the sudo caller, or current user, to the docker group.

Uninstall options:
  --purge-data            Also remove /var/lib/docker and /var/lib/containerd.
  --keep-repo             Keep Docker package manager repository files.

Examples:
  sudo ./$SCRIPT_NAME install
  sudo ./$SCRIPT_NAME install --without-compose
  sudo ./$SCRIPT_NAME install --add-current-user
  sudo ./$SCRIPT_NAME uninstall --purge-data
EOF
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

run() {
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '[DRY-RUN]'
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi

  "$@"
}

write_file() {
  local path="$1"
  local content="$2"

  if [[ "$DRY_RUN" == "1" ]]; then
    log "would write $path:"
    printf '%s\n' "$content"
    return 0
  fi

  printf '%s\n' "$content" >"$path"
}

write_file_if_changed() {
  local path="$1"
  local content="$2"

  if [[ -f "$path" ]] && printf '%s\n' "$content" | cmp -s "$path" -; then
    log "$path is already up to date"
    return 0
  fi

  write_file "$path" "$content"
}

safe_remove_path() {
  local path
  for path in "$@"; do
    case "$path" in
      ""|"/"|"/etc"|"/var"|"/var/lib"|"/usr"|"/usr/local")
        die "refusing to remove unsafe path: $path"
        ;;
    esac

    if [[ -e "$path" || -L "$path" ]]; then
      log "removing $path"
      run rm -rf "$path"
    else
      log "skip absent path: $path"
    fi
  done
}

parse_args() {
  if [[ "$#" -eq 0 ]]; then
    usage
    exit 1
  fi

  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      install|uninstall)
        [[ -z "$ACTION" ]] || die "only one action can be specified"
        ACTION="$1"
        ;;
      --with-compose)
        INSTALL_COMPOSE=1
        ;;
      --without-compose|--no-compose)
        INSTALL_COMPOSE=0
        ;;
      --no-enable)
        ENABLE_SERVICE=0
        ;;
      --no-verify)
        VERIFY_INSTALL=0
        ;;
      --run-hello-world)
        RUN_HELLO_WORLD=1
        ;;
      --add-user)
        shift
        [[ "$#" -gt 0 ]] || die "--add-user requires a username"
        ADD_USER="$1"
        ;;
      --add-current-user)
        ADD_USER="${SUDO_USER:-${USER:-}}"
        [[ -n "$ADD_USER" ]] || die "cannot determine current user; use --add-user USER"
        ;;
      --purge-data)
        PURGE_DATA=1
        ;;
      --keep-repo)
        KEEP_REPO=1
        ;;
      --distro)
        shift
        [[ "$#" -gt 0 ]] || die "--distro requires a value"
        FORCE_DISTRO="${1,,}"
        ;;
      --codename)
        shift
        [[ "$#" -gt 0 ]] || die "--codename requires a value"
        CODENAME_OVERRIDE="$1"
        ;;
      --repo-base-url)
        shift
        [[ "$#" -gt 0 ]] || die "--repo-base-url requires a URL"
        REPO_BASE_URL="${1%/}"
        ;;
      --dry-run)
        DRY_RUN=1
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "unknown argument: $1"
        ;;
    esac
    shift
  done

  [[ -n "$ACTION" ]] || die "missing action: install or uninstall"
}

ensure_linux() {
  [[ "$(uname -s)" == "Linux" ]] || die "this script only supports Linux"
}

ensure_root() {
  if [[ "$DRY_RUN" == "1" ]]; then
    return 0
  fi

  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    return 0
  fi

  if command_exists sudo; then
    log "re-running with sudo"
    exec sudo -E bash "$0" "$@"
  fi

  die "root privileges are required; run with sudo"
}

load_os_release() {
  [[ -r /etc/os-release ]] || die "/etc/os-release not found; cannot detect distro"

  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID,,}"
  OS_ID_LIKE="${ID_LIKE:-}"
  OS_ID_LIKE="${OS_ID_LIKE,,}"
  OS_VERSION_CODENAME="${VERSION_CODENAME:-}"
  OS_UBUNTU_CODENAME="${UBUNTU_CODENAME:-}"
}

has_like() {
  local needle="$1"
  [[ " $OS_ID_LIKE " == *" $needle "* ]]
}

select_adapter() {
  local effective_id="${FORCE_DISTRO:-$OS_ID}"

  case "$effective_id" in
    ubuntu)
      ADAPTER="apt"
      DOCKER_REPO_ID="ubuntu"
      APT_SUITE="${CODENAME_OVERRIDE:-${OS_UBUNTU_CODENAME:-$OS_VERSION_CODENAME}}"
      ;;
    debian)
      ADAPTER="apt"
      DOCKER_REPO_ID="debian"
      APT_SUITE="${CODENAME_OVERRIDE:-$OS_VERSION_CODENAME}"
      ;;
    linuxmint|pop|pop_os|elementary|zorin)
      ADAPTER="apt"
      DOCKER_REPO_ID="ubuntu"
      APT_SUITE="${CODENAME_OVERRIDE:-${OS_UBUNTU_CODENAME:-$OS_VERSION_CODENAME}}"
      warn "$effective_id is an Ubuntu derivative; Docker does not officially support all derivatives. Use --codename if repo resolution fails."
      ;;
    kali)
      ADAPTER="apt"
      DOCKER_REPO_ID="debian"
      APT_SUITE="${CODENAME_OVERRIDE:-$OS_VERSION_CODENAME}"
      warn "$effective_id is a Debian derivative; use --codename with a Debian release codename if repo resolution fails."
      ;;
    fedora)
      ADAPTER="rpm"
      DOCKER_REPO_ID="fedora"
      ;;
    centos)
      ADAPTER="rpm"
      DOCKER_REPO_ID="centos"
      ;;
    rhel)
      ADAPTER="rpm"
      DOCKER_REPO_ID="rhel"
      ;;
    rocky|almalinux|ol)
      ADAPTER="rpm"
      DOCKER_REPO_ID="centos"
      warn "$effective_id is RHEL-compatible; using Docker's CentOS repository adapter."
      ;;
    *)
      if has_like ubuntu; then
        ADAPTER="apt"
        DOCKER_REPO_ID="ubuntu"
        APT_SUITE="${CODENAME_OVERRIDE:-${OS_UBUNTU_CODENAME:-$OS_VERSION_CODENAME}}"
        warn "$OS_ID is Ubuntu-like; using Docker's Ubuntu repository adapter."
      elif has_like debian; then
        ADAPTER="apt"
        DOCKER_REPO_ID="debian"
        APT_SUITE="${CODENAME_OVERRIDE:-$OS_VERSION_CODENAME}"
        warn "$OS_ID is Debian-like; using Docker's Debian repository adapter."
      elif has_like rhel || has_like fedora; then
        ADAPTER="rpm"
        DOCKER_REPO_ID="centos"
        warn "$OS_ID is RPM/RHEL-like; using Docker's CentOS repository adapter."
      else
        die "unsupported distro: $OS_ID. Try --distro ubuntu|debian|fedora|centos|rhel."
      fi
      ;;
  esac

  if [[ "$ADAPTER" == "apt" && -z "$APT_SUITE" ]]; then
    die "could not determine apt suite codename; pass --codename NAME"
  fi

  log "selected adapter=$ADAPTER repo=$DOCKER_REPO_ID distro=${OS_ID:-unknown}"
}

service_manager_available() {
  command_exists systemctl && [[ -d /run/systemd/system ]]
}

enable_and_start_docker() {
  [[ "$ENABLE_SERVICE" == "1" ]] || return 0

  if service_manager_available; then
    run systemctl enable --now docker.service
    if systemctl list-unit-files containerd.service >/dev/null 2>&1; then
      run systemctl enable containerd.service
    fi
  else
    warn "systemd is not available; start Docker manually for this environment"
  fi
}

build_install_packages() {
  INSTALL_PACKAGES=("${ENGINE_PACKAGES[@]}")
  if [[ "$INSTALL_COMPOSE" == "1" ]]; then
    INSTALL_PACKAGES+=("$COMPOSE_PACKAGE")
  fi
}

build_uninstall_packages() {
  UNINSTALL_PACKAGES=("${ENGINE_PACKAGES[@]}" "$ROOTLESS_PACKAGE")
  if [[ "$INSTALL_COMPOSE" == "1" ]]; then
    UNINSTALL_PACKAGES+=("$COMPOSE_PACKAGE")
  fi
}

apt_installed_or_configured_packages() {
  local pkg

  if ! command_exists dpkg-query; then
    [[ "$DRY_RUN" == "1" ]] && return 0
    die "dpkg-query is required by the apt adapter"
  fi

  for pkg in "$@"; do
    if dpkg-query -W -f='${db:Status-Abbrev}' "$pkg" 2>/dev/null | grep -Eq '^(ii|rc)'; then
      printf '%s\n' "$pkg"
    fi
  done
}

apt_architecture() {
  if command_exists dpkg; then
    dpkg --print-architecture
  elif [[ "$DRY_RUN" == "1" ]]; then
    printf '<dpkg-architecture>'
  else
    die "dpkg is required by the apt adapter"
  fi
}

apt_source_files() {
  local file
  for file in /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
    [[ -f "$file" ]] && printf '%s\n' "$file"
  done
}

apt_existing_docker_source_files() {
  local file
  while IFS= read -r file; do
    if grep -Eq 'download\.docker\.com/linux' "$file"; then
      printf '%s\n' "$file"
    fi
  done < <(apt_source_files)
}

apt_backup_legacy_docker_sources() {
  local target="$1"
  local existing=()
  local file
  local backup
  local timestamp

  mapfile -t existing < <(apt_existing_docker_source_files)
  if [[ "${#existing[@]}" -eq 0 ]]; then
    log "no existing Docker apt source found"
    return 0
  fi

  timestamp="$(date +%Y%m%d%H%M%S)"
  for file in "${existing[@]}"; do
    if [[ "$file" == "$target" ]]; then
      log "existing Docker apt source found at $file; refreshing managed source"
    elif [[ "$file" == /etc/apt/sources.list.d/docker.* ]]; then
      backup="$file.bak.$timestamp"
      warn "existing Docker apt source found at $file; backing it up to $backup to avoid duplicate apt entries"
      run mv "$file" "$backup"
    else
      die "existing Docker apt source found in $file. Comment or remove it first to avoid duplicate/conflicting apt sources."
    fi
  done
}

apt_remove_if_present() {
  local packages=("$@")
  local present=()
  local pkg

  mapfile -t present < <(apt_installed_or_configured_packages "${packages[@]}")
  if [[ "${#present[@]}" -gt 0 ]]; then
    run env DEBIAN_FRONTEND=noninteractive apt-get remove -y "${present[@]}"
  else
    log "no conflicting apt packages found"
  fi
}

apt_purge_if_present() {
  local packages=("$@")
  local present=()

  mapfile -t present < <(apt_installed_or_configured_packages "${packages[@]}")
  if [[ "${#present[@]}" -gt 0 ]]; then
    run env DEBIAN_FRONTEND=noninteractive apt-get purge -y "${present[@]}"
  else
    log "no Docker apt packages found"
  fi
}

apt_setup_repository() {
  local repo_url="$REPO_BASE_URL/$DOCKER_REPO_ID"
  local source_path="/etc/apt/sources.list.d/docker.sources"
  local source_content

  run env DEBIAN_FRONTEND=noninteractive apt-get update
  run env DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl
  run install -m 0755 -d /etc/apt/keyrings
  run curl -fsSL "$repo_url/gpg" -o /etc/apt/keyrings/docker.asc
  run chmod a+r /etc/apt/keyrings/docker.asc

  printf -v source_content '%s\n' \
    'Types: deb' \
    "URIs: $repo_url" \
    "Suites: $APT_SUITE" \
    'Components: stable' \
    "Architectures: $(apt_architecture)" \
    'Signed-By: /etc/apt/keyrings/docker.asc'

  apt_backup_legacy_docker_sources "$source_path"
  write_file_if_changed "$source_path" "$source_content"
  run env DEBIAN_FRONTEND=noninteractive apt-get update
}

apt_install() {
  local conflicts=(docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc)

  log "removing conflicting distro packages if present"
  apt_remove_if_present "${conflicts[@]}"

  log "setting up Docker apt repository"
  apt_setup_repository

  build_install_packages
  log "installing Docker packages: ${INSTALL_PACKAGES[*]}"
  run env DEBIAN_FRONTEND=noninteractive apt-get install -y "${INSTALL_PACKAGES[@]}"
}

apt_uninstall() {
  build_uninstall_packages
  log "removing Docker apt packages: ${UNINSTALL_PACKAGES[*]}"
  apt_purge_if_present "${UNINSTALL_PACKAGES[@]}"

  if [[ "$KEEP_REPO" == "0" ]]; then
    safe_remove_path /etc/apt/sources.list.d/docker.sources /etc/apt/keyrings/docker.asc
    run env DEBIAN_FRONTEND=noninteractive apt-get update
  fi

  if [[ "$PURGE_DATA" == "1" ]]; then
    safe_remove_path /var/lib/docker /var/lib/containerd
  else
    log "Docker data kept. Re-run uninstall with --purge-data to remove it."
  fi
}

rpm_package_manager() {
  if command_exists dnf; then
    printf 'dnf'
  elif command_exists yum; then
    printf 'yum'
  elif [[ "$DRY_RUN" == "1" ]]; then
    printf 'dnf'
  else
    die "neither dnf nor yum is available"
  fi
}

rpm_installed_packages() {
  local pkg

  if ! command_exists rpm; then
    [[ "$DRY_RUN" == "1" ]] && return 0
    die "rpm is required by the rpm adapter"
  fi

  for pkg in "$@"; do
    if rpm -q "$pkg" >/dev/null 2>&1; then
      printf '%s\n' "$pkg"
    fi
  done
}

rpm_remove_if_present() {
  local pm="$1"
  shift
  local present=()

  mapfile -t present < <(rpm_installed_packages "$@")
  if [[ "${#present[@]}" -gt 0 ]]; then
    run "$pm" remove -y "${present[@]}"
  else
    log "no conflicting rpm packages found"
  fi
}

rpm_add_repo() {
  local pm="$1"
  local repo_url="$2"

  if [[ "$pm" == "dnf" ]]; then
    run "$pm" install -y dnf-plugins-core

    if [[ "$DRY_RUN" == "1" ]]; then
      if [[ "$DOCKER_REPO_ID" == "fedora" ]]; then
        run "$pm" config-manager addrepo --from-repofile "$repo_url"
      else
        run "$pm" config-manager --add-repo "$repo_url"
      fi
      return 0
    fi

    if [[ "$DOCKER_REPO_ID" == "fedora" ]]; then
      "$pm" config-manager addrepo --from-repofile "$repo_url" || "$pm" config-manager --add-repo "$repo_url"
    else
      "$pm" config-manager --add-repo "$repo_url" || "$pm" config-manager addrepo --from-repofile "$repo_url"
    fi
  else
    run "$pm" install -y yum-utils
    run yum-config-manager --add-repo "$repo_url"
  fi
}

rpm_setup_repository() {
  local pm="$1"
  local repo_url="$REPO_BASE_URL/$DOCKER_REPO_ID/docker-ce.repo"

  log "setting up Docker rpm repository: $repo_url"
  rpm_add_repo "$pm" "$repo_url"
}

rpm_install() {
  local pm
  local conflicts=(docker docker-client docker-client-latest docker-common docker-latest docker-latest-logrotate docker-logrotate docker-engine)

  if [[ "$DOCKER_REPO_ID" == "fedora" ]]; then
    conflicts+=(docker-selinux docker-engine-selinux)
  elif [[ "$DOCKER_REPO_ID" == "rhel" ]]; then
    conflicts+=(podman runc)
  fi

  pm="$(rpm_package_manager)"
  log "removing conflicting distro packages if present"
  rpm_remove_if_present "$pm" "${conflicts[@]}"

  rpm_setup_repository "$pm"

  build_install_packages
  log "installing Docker packages: ${INSTALL_PACKAGES[*]}"
  run "$pm" install -y "${INSTALL_PACKAGES[@]}"
}

rpm_uninstall() {
  local pm
  local present=()

  pm="$(rpm_package_manager)"
  build_uninstall_packages

  mapfile -t present < <(rpm_installed_packages "${UNINSTALL_PACKAGES[@]}")
  if [[ "${#present[@]}" -gt 0 ]]; then
    log "removing Docker rpm packages: ${present[*]}"
    run "$pm" remove -y "${present[@]}"
  else
    log "no Docker rpm packages found"
  fi

  if [[ "$KEEP_REPO" == "0" ]]; then
    safe_remove_path /etc/yum.repos.d/docker-ce.repo
  fi

  if [[ "$PURGE_DATA" == "1" ]]; then
    safe_remove_path /var/lib/docker /var/lib/containerd
  else
    log "Docker data kept. Re-run uninstall with --purge-data to remove it."
  fi
}

post_install_user_group() {
  [[ -n "$ADD_USER" ]] || return 0

  if ! id "$ADD_USER" >/dev/null 2>&1; then
    die "user does not exist: $ADD_USER"
  fi

  if ! getent group docker >/dev/null 2>&1; then
    run groupadd docker
  fi

  run usermod -aG docker "$ADD_USER"
  warn "user '$ADD_USER' was added to the docker group. Log out and back in for this to take effect."
  warn "membership in the docker group grants root-equivalent access to the Docker daemon."
}

verify_install() {
  [[ "$VERIFY_INSTALL" == "1" ]] || return 0

  if [[ "$DRY_RUN" == "1" ]]; then
    run docker --version
    if [[ "$INSTALL_COMPOSE" == "1" ]]; then
      run docker compose version
    fi
    if [[ "$RUN_HELLO_WORLD" == "1" ]]; then
      run docker run --rm hello-world
    fi
    return 0
  fi

  if command_exists docker; then
    run docker --version
  else
    die "docker command not found after installation"
  fi

  if [[ "$INSTALL_COMPOSE" == "1" ]]; then
    run docker compose version
  fi

  if [[ "$RUN_HELLO_WORLD" == "1" ]]; then
    run docker run --rm hello-world
  fi
}

install_docker() {
  case "$ADAPTER" in
    apt) apt_install ;;
    rpm) rpm_install ;;
    *) die "internal error: unsupported adapter $ADAPTER" ;;
  esac

  enable_and_start_docker
  post_install_user_group
  verify_install
}

uninstall_docker() {
  case "$ADAPTER" in
    apt) apt_uninstall ;;
    rpm) rpm_uninstall ;;
    *) die "internal error: unsupported adapter $ADAPTER" ;;
  esac
}

main() {
  parse_args "$@"
  ensure_linux
  ensure_root "$@"
  load_os_release
  select_adapter

  case "$ACTION" in
    install) install_docker ;;
    uninstall) uninstall_docker ;;
    *) die "internal error: unknown action $ACTION" ;;
  esac
}

main "$@"
