# SSH server setup

[中文说明](README.zh-CN.md)

Run on the **target machine**, using an existing console or administrative session. These scripts do not bootstrap remote access from the client.

| Target | Entry point | Scope |
| --- | --- | --- |
| Windows | [windows/Configure-RestrictedOpenSsh.ps1](windows/Configure-RestrictedOpenSsh.ps1) | Elevated PowerShell, administrator authorized keys, Windows Firewall allowlist |
| macOS | [unix/configure-restricted-openssh.sh](unix/configure-restricted-openssh.sh) | sudo, Bash 3.2+, built-in Remote Login, existing non-root account |
| Ubuntu / Debian | Same Unix entry | sudo, Bash, systemd, ssh-keygen, util-linux (runuser), apt installation of openssh-server if absent |

Other Linux distributions and environments without systemd are not supported yet. macOS uses its system OpenSSH, without Homebrew.

## Usage

Generate or select a client key on the **client**, and copy only the `.pub` file to the target:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_demo -C demo@example.com
```

The following commands run from the repository root on the target machine. Replace the example addresses and public key.

### Windows

Run in **elevated PowerShell** on the target Windows computer:

```powershell
.\openssh\windows\Configure-RestrictedOpenSsh.ps1 `
    -LocalAddress '192.0.2.10' `
    -RemoteAddress '192.0.2.1', '192.0.2.2' `
    -PublicKey 'ssh-ed25519 AAAA... admin@example.invalid'
```

`LocalAddress` identifies the target's local SSH addresses; `RemoteAddress` lists permitted client source addresses. Both accept multiple IPs. `PublicKey` is the full client public key text.

Each call with the same `RuleName` replaces the firewall allowlist; omitted addresses are no longer allowed. The built-in `OpenSSH-Server-In-TCP` rule stays disabled so it cannot bypass the allowlist.

[Configure-RestrictedOpenSsh.ps1](windows/Configure-RestrictedOpenSsh.ps1) orchestrates the reusable functions in [OpenSshServerTools.psm1](windows/OpenSshServerTools.psm1):

| Function | Parameters | Purpose |
| --- | --- | --- |
| `Ensure-OpenSshServer` | None | Install sshd, enable automatic startup, and start it |
| `Set-OpenSshFirewallAllowRule` | `LocalAddress`, `RemoteAddress`, optional `RuleName` | Replace the SSH firewall allowlist |
| `Add-AdminSshAuthorizedKey` | `PublicKey` | Add an administrator public key without duplicates; restrict the file ACL to Administrators and SYSTEM |
| `Restart-OpenSshServerSafely` | None | Validate with `sshd -t` before restarting |
| `Test-OpenSshServer` | Optional `RuleName` | Report service, port 22 listener, and allowlist status |

This entry uses `administrators_authorized_keys`, which applies only to administrator accounts. Standard accounts use `%USERPROFILE%\.ssh\authorized_keys` instead.

### macOS / Ubuntu / Debian

Run in the target machine's terminal:

```bash
bash openssh/unix/configure-restricted-openssh.sh \
  --user demo --local-address 192.0.2.10 --remote-address 192.0.2.1 \
  --public-key-file ./client.pub --dry-run

sudo bash openssh/unix/configure-restricted-openssh.sh \
  --user demo --local-address 192.0.2.10 --remote-address 192.0.2.1 \
  --public-key-file ./client.pub
```

Replace the example addresses and account. Repeat `--local-address` for multiple target IPs; repeat `--remote-address` for multiple client IPs or networks. Both support IPv4/IPv6; only remote addresses accept CIDRs, using a network address such as `198.51.100.0/24` or `2001:db8:1::/64`. Hostnames, IPv6 scope IDs, and mixed IPv6/IPv4 notation are not accepted. Supply one plain OpenSSH public key without authorized_keys options. Dry run validates arguments and the public key without writes or privilege requirements; existing account/config/service checks happen during apply.

On macOS, first-time `systemsetup` activation may require Full Disk Access for the terminal. Alternatively enable Remote Login in System Settings > General > Sharing first. When Remote Login permits only selected users, add the target account there; the script does not modify that list.

Both macOS and Linux generate missing server host keys before validating configuration. Existing host keys are preserved.

## Unix access policy and recovery

The Unix entry appends a managed `Match` / `DenyUsers` block to `/etc/ssh/sshd_config`. **Only the selected user may authenticate, and only from the listed sources to the listed destination IPs. Other accounts are denied too.** Existing sessions are not disconnected. The allowlist is replaced on every run; previous public keys remain and require manual removal when retired.

Unlike Windows Firewall filtering, this is an SSH authentication policy. Rejected clients may still establish TCP connections. UFW/nftables/PF, routing, and cloud rules remain your responsibility. Existing SSH ports, listeners, password policy, and other restrictions are preserved; public-key-only authentication is not enforced.

Existing authorized_keys content is preserved; plain keys are deduplicated by type and key data. The script sets the target `.ssh` directory to mode 700 and authorized_keys to 600. Existing directories/files must already be owned by the target user; incorrect ownership must be corrected separately. Symlinked paths are refused. Home-directory snapshots, writes, permission changes, and rollback all run as the target user via Linux runuser or macOS sudo, so a path replacement cannot redirect a privileged root write. Keys are installed using a temporary file replacement. If a replaced path prevents safe restoration, rollback reports the failure instead of forcing a root write.

Existing `DenyUsers`, including inside conditional/recursive Includes, requires manual reconciliation because it can override the new rules. Simple and glob Includes are supported; complex quoting/paths containing spaces and recursive/deep Includes fail closed.

Configuration must pass `sshd -t` and effective `sshd -T -C` public-key/path checks before service activation. Existing account and authentication restrictions still apply; custom AuthorizedKeysFile paths must include the standard user file. Failed file writes or activation restore the previous main config and authorized_keys. Linux service state is restored on a best-effort basis. Package installation, generated host keys, and `/run/sshd` are not rolled back. A temporary Debian `policy-rc.d` prevents package installation from starting unrestricted SSH; if one already exists, install the server using that policy before rerunning.

`/etc/ssh/.restricted-openssh.lock` prevents concurrent runs. After a forced termination or power loss, verify no setup process is running before removing a stale lock. Keep a console available until a real client login succeeds. Numeric allowlists need updating when DHCP addresses change; allowing a subnet permits every source in that subnet.

To remove the Unix allowlist, use the console to delete the entire managed block between `# BEGIN shell-scripts restricted-openssh` and its matching END marker. Validate the config before restarting Linux SSH; new macOS SSH connections read the restored file. Removing the block removes this tool's login restrictions.

## Client alias

Client configuration is separate. Add to `~/.ssh/config` (Windows: `$HOME\.ssh\config`):

```sshconfig
Host demo-pc
    HostName demo-pc.local
    User demo
    Port 22
    IdentityFile ~/.ssh/id_ed25519_demo
    IdentitiesOnly yes
```

Use a resolvable hostname or target IP and the actual SSH port, then run `ssh demo-pc`. Keep the private key on the client.

## Validation

```bash
bash -n openssh/unix/configure-restricted-openssh.sh
bash openssh/tests/test-configure-restricted-openssh.sh
```

Tests use private temporary files and mocked service operations, covering macOS host-key preparation and file/directory symlink replacements during install and rollback as well as the existing policy tests. Real sshd configuration checks run when `/usr/sbin/sshd` is available. Running tests through sudo delegates home-file operations to the original sudo caller to exercise real privilege dropping, still entirely within the test fixture. Tests do not install software, modify system SSH configuration, or change services/firewalls. Real OpenSSH parsing has been verified on Ubuntu. macOS Remote Login permissions, activation, and end-to-end login still require validation on a Mac.

References: [OpenSSH sshd_config](https://man.openbsd.org/sshd_config), [Ubuntu OpenSSH Server](https://ubuntu.com/server/docs/how-to/security/openssh-server/), [Apple Remote Login](https://support.apple.com/guide/mac-help/allow-a-remote-computer-to-access-your-mac-mchlp1066/mac), [Apple systemsetup](https://support.apple.com/guide/remote-desktop/about-systemsetup-apd95406b8d/mac).
