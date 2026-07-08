# Docker Manager Script

`docker-manager.sh` installs and uninstalls Docker Engine on Linux using Docker's
official package repositories. Docker Compose is installed by default as the
`docker-compose-plugin` package, and can be disabled with `--without-compose`.

See [DEVELOPMENT.md](./DEVELOPMENT.md) for design notes, adapter behavior, and
the development FAQ behind this script.

The script is optimized for Ubuntu today, but its structure is intentionally
adapter-based:

- argument parsing and workflow live in the main entrypoint
- distro detection chooses an `apt` or `rpm` adapter
- package-manager details stay inside adapter functions
- adding a distro should only require mapping the distro to a repository and
  package-manager behavior

## Supported adapters

Primary support:

- Ubuntu
- Debian
- Fedora
- CentOS
- RHEL

Compatible fallbacks:

- Ubuntu derivatives use Docker's Ubuntu repository adapter with a warning
- Debian derivatives that are not Ubuntu-based use Docker's Debian repository
  adapter with a warning
- Rocky Linux, AlmaLinux, and Oracle Linux use the CentOS adapter with a warning

For derivative distributions, pass `--distro` and/or `--codename` when the
auto-detected repository suite is not correct.

## Usage

```bash
chmod +x ./docker-manager.sh
sudo ./docker-manager.sh install
```

Install Docker Engine without Docker Compose:

```bash
sudo ./docker-manager.sh install --without-compose
```

Install and add the sudo caller to the `docker` group:

```bash
sudo ./docker-manager.sh install --add-current-user
```

Uninstall Docker packages while keeping images, containers, and volumes:

```bash
sudo ./docker-manager.sh uninstall
```

Uninstall and remove Docker/containerd data:

```bash
sudo ./docker-manager.sh uninstall --purge-data
```

Preview commands without changing the system:

```bash
./docker-manager.sh install --dry-run
```

## Notes

- The script uses Docker's repository method rather than the convenience script.
- Docker data under `/var/lib/docker` and `/var/lib/containerd` is preserved by
  default during uninstall.
- `--add-current-user` follows Docker's post-install guidance, but the `docker`
  group grants root-equivalent access to the Docker daemon.
- `--run-hello-world` is available when you want the official container smoke
  test; normal verification only checks `docker --version` and
  `docker compose version`.
