# LumiVPS-Virtarix

End-to-end automation for:

1. **Ubuntu 24.04 VPS → NixOS migration**
2. **OpenClaw setup in Nix mode**
3. **Post-reboot continuation using the same script**

This guide is thorough but concise, with **one code block per command** for easy copy/paste.

---

## Defaults used by this repo

- **Default admin user:** `lumi`
- **Default timezone:** `America/Chicago` (Central Time)
- **Default provider hint:** `virtarix`

You can override prompts during runtime, but docs below assume `lumi`.

Input validation highlights:
- admin username must be a valid Linux username format (e.g. `lumi`)
- timezone must exist on system (e.g. `America/Chicago`)
- custom paths should be absolute paths

---

## What is in this repo

- `migrate-to-nixos-and-setup-openclaw.sh` (**recommended**)
  - Phase 1 on Ubuntu: migration prep + `nixos-infect`
  - Phase 2 on NixOS: OpenClaw bootstrap with Home Manager
- `setup-openclaw-nix-ubuntu24.sh` (legacy helper)
  - Nix-based OpenClaw setup on Ubuntu only (no OS migration)

---

## Before you start (important)

- Use a **fresh or disposable Ubuntu 24.04 VPS**.
- The migration is **destructive** to the current OS install.
- Ensure provider console/recovery access is available.
- Have at least one valid SSH public key ready.

---

## Quick start (full migration flow)

### 1) Clone repo on your Ubuntu VPS

```bash
git clone https://github.com/lumibot42/LumiVPS-Virtarix.git
```

```bash
cd LumiVPS-Virtarix
```

### 2) Run migration script (Phase 1 on Ubuntu)

```bash
sudo bash ./migrate-to-nixos-and-setup-openclaw.sh
```

The script prompts for:
- admin username (default `lumi`)
- hostname
- timezone
- SSH public keys
- provider/network hints (provider default `virtarix`)

It then starts migration and reboots.

### 3) Reconnect after reboot (now on NixOS)

```bash
ssh lumi@<server-ip>
```

### 4) Run Phase 2 (OpenClaw setup)

```bash
sudo bash /etc/nixos/openclaw-migration/migrate.sh
```

The script prompts for:
- Telegram bot token
- Telegram chat ID
- OpenAI and/or Anthropic API key
- OpenClaw directories/profile options

On reruns, if secret files already exist, you can choose to reuse them instead of retyping values.

### 5) Validate service

```bash
sudo -u lumi systemctl --user status openclaw-gateway
```

```bash
sudo -u lumi journalctl --user -u openclaw-gateway -f
```

---

## Legacy path (Ubuntu-only, no NixOS migration)

```bash
bash ./setup-openclaw-nix-ubuntu24.sh
```

Use this only if you do **not** want to migrate to NixOS.

---

## Windows: generate SSH keys (when needed)

Use this if you need SSH keys for:
- VPS login
- GitHub authentication

### PowerShell (Windows 10/11 built-in OpenSSH)

```powershell
ssh-keygen -t ed25519 -C "your_email@example.com"
```

When prompted for path, press Enter for default:
`C:\Users\<You>\.ssh\id_ed25519`

### Show public key (copy this value)

```powershell
type $env:USERPROFILE\.ssh\id_ed25519.pub
```

### Optional: start ssh-agent and load key

```powershell
Get-Service ssh-agent | Set-Service -StartupType Automatic
```

```powershell
Start-Service ssh-agent
```

```powershell
ssh-add $env:USERPROFILE\.ssh\id_ed25519
```

### Test GitHub SSH auth

```powershell
ssh -T git@github.com
```

If prompted to trust host, type `yes`.

---

## Add your SSH key to GitHub

1. GitHub → **Settings** → **SSH and GPG keys** → **New SSH key**
2. Key type: **Authentication key**
3. Paste `id_ed25519.pub`

Then test from terminal:

```bash
ssh -T git@github.com
```

---

## Telegram prerequisites

### Create bot token

Message `@BotFather` and create a bot.

### Get your chat ID

Message `@userinfobot` and copy your numeric user ID.

You will enter both during script prompts.

---

## Recovery / troubleshooting

### If SSH does not come back after migration

Use VPS web console/recovery mode and inspect boot/network.

### Check migration artifacts

```bash
sudo ls -la /etc/nixos/openclaw-migration
```

### View migration report

```bash
sudo cat /etc/nixos/openclaw-migration/last-run-report.txt
```

### View infect log

```bash
sudo cat /etc/nixos/openclaw-migration/infect.log
```

### Re-run post-migration setup safely

```bash
sudo bash /etc/nixos/openclaw-migration/migrate.sh
```

---

## Security notes

- Treat API keys and bot tokens as secrets.
- Rotate tokens if accidentally exposed.
- Keep private keys private (`id_ed25519`, never share it).
- Migration reports are redacted for common secret patterns.
- Persistent state avoids storing raw API key/token values.

---

## License

Use at your own risk. Review scripts before running on production systems.
