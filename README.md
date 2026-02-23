# LumiVPS-Virtarix

Automated path from a **fresh Ubuntu 24.04 VPS** to:

1. NixOS (in-place migration)
2. OpenClaw in Nix mode
3. Post-reboot continuation using the same script

---

## Assumptions (explicit)

This guide assumes:

- starting OS is **Ubuntu 24.04**
- the machine is fresh/minimal and may have **no extra dependencies installed**
- you have `root` or `sudo` access
- outbound internet works
- you have provider console/recovery access

Defaults in this repo:

- admin user: `lumi`
- timezone: `America/Chicago`
- provider hint: `virtarix`

---

## Files in this repo

- `migrate-to-nixos-and-setup-openclaw.sh` (**recommended**)
  - Phase 1 on Ubuntu: migration prep + `nixos-infect`
  - Phase 2 on NixOS: OpenClaw bootstrap via Home Manager
- `setup-openclaw-nix-ubuntu24.sh` (legacy helper)
  - Ubuntu-only Nix/OpenClaw bootstrap (no OS migration)

---

## Step-by-step: fresh Ubuntu 24.04 → NixOS → OpenClaw

## 0) Connect to server

```bash
ssh root@<server-ip>
```

## 1) Install baseline tools (dependency bootstrap)

```bash
apt-get update
```

```bash
apt-get install -y ca-certificates curl git openssh-client
```

## 2) Clone this repository

```bash
git clone https://github.com/lumibot42/LumiVPS-Virtarix.git
```

```bash
cd LumiVPS-Virtarix
```

## 3) Run migration script (Phase 1 on Ubuntu)

```bash
sudo bash ./migrate-to-nixos-and-setup-openclaw.sh
```

You will be prompted for:

- admin username (default `lumi`)
- hostname
- timezone (default `America/Chicago`)
- SSH public keys
- provider/network hints (default provider `virtarix`)

Expected result: migration starts and server reboots into NixOS.

## 4) Reconnect after reboot

```bash
ssh lumi@<server-ip>
```

## 5) Continue setup (Phase 2 on NixOS)

```bash
sudo bash /etc/nixos/openclaw-migration/migrate.sh
```

You will be prompted for:

- OpenClaw directories/profile options
- OpenAI and/or Anthropic API key

Channel setup is intentionally deferred (Discord/channels can be added later in `flake.nix`).

## 6) Validate service

```bash
sudo -u lumi systemctl --user status openclaw-gateway
```

```bash
sudo -u lumi journalctl --user -u openclaw-gateway -f
```

---

## If `git` is unavailable and you want direct script download

```bash
apt-get update
```

```bash
apt-get install -y ca-certificates curl
```

```bash
curl -fsSL https://raw.githubusercontent.com/lumibot42/LumiVPS-Virtarix/main/migrate-to-nixos-and-setup-openclaw.sh -o /root/migrate.sh
```

```bash
chmod +x /root/migrate.sh
```

```bash
sudo bash /root/migrate.sh
```

---

## Windows: generate SSH keys (if needed)

Use these for VPS SSH access and/or GitHub SSH auth.

## 1) Generate key

```powershell
ssh-keygen -t ed25519 -C "your_email@example.com"
```

## 2) Print public key

```powershell
type $env:USERPROFILE\.ssh\id_ed25519.pub
```

## 3) Optional: start ssh-agent

```powershell
Get-Service ssh-agent | Set-Service -StartupType Automatic
```

```powershell
Start-Service ssh-agent
```

```powershell
ssh-add $env:USERPROFILE\.ssh\id_ed25519
```

## 4) Test GitHub SSH auth

```powershell
ssh -T git@github.com
```

---

## Channel setup after bootstrap (optional)

The migration script does not configure messaging channels.
After bootstrap, add Discord (or any supported channel) in `flake.nix`, then apply Home Manager.

---

## Recovery / troubleshooting

## Show migration artifacts

```bash
sudo ls -la /etc/nixos/openclaw-migration
```

## View migration report

```bash
sudo cat /etc/nixos/openclaw-migration/last-run-report.txt
```

## Show PATH and command resolution captured by script

```bash
sudo grep -E "^(PATH in use|cmd )" /etc/nixos/openclaw-migration/last-run-report.txt
```

## View infect log

```bash
sudo cat /etc/nixos/openclaw-migration/infect.log
```

## Re-run phase 2 safely

```bash
sudo bash /etc/nixos/openclaw-migration/migrate.sh
```

---

## Security notes

- migration is destructive to current Ubuntu install
- take a VPS snapshot before starting
- keep private keys private (`id_ed25519`)
- keep API keys in secret files, not in public repos
- reports are redacted for common secret patterns

---

## License

Use at your own risk. Review scripts before running in production.
