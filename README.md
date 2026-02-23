# LumiVPS-Virtarix

Automated migration + bootstrap scripts for bringing OpenClaw back online on a fresh VPS.

## Included scripts

### 1) `migrate-to-nixos-and-setup-openclaw.sh` (recommended)
End-to-end orchestrator:

- **Phase 1 (Ubuntu 24.04):** in-place migration to NixOS via `nixos-infect`
- **Phase 2 (NixOS after reboot):** OpenClaw bootstrap in Nix mode via `nix-openclaw` + Home Manager

Features:

- interactive prompts for admin user, hostname, SSH keys, provider/network hints, Telegram/API keys
- rerunnable flow with persisted state under `/etc/nixos/openclaw-migration`
- report output at `/etc/nixos/openclaw-migration/last-run-report.txt`
- explicit destructive confirmation before migration starts

### 2) `setup-openclaw-nix-ubuntu24.sh` (legacy helper)
Sets up OpenClaw with Nix tooling on Ubuntu 24.04 **without** migrating the OS to NixOS.

---

## Quick start

### A) Full migration (Ubuntu 24.04 → NixOS → OpenClaw)

```bash
sudo bash ./migrate-to-nixos-and-setup-openclaw.sh
```

After reboot into NixOS, rerun:

```bash
sudo bash /etc/nixos/openclaw-migration/migrate.sh
```

### B) Ubuntu-only OpenClaw setup (no OS migration)

```bash
bash ./setup-openclaw-nix-ubuntu24.sh
```

---

## Safety notes

- The full migration script is intentionally **destructive** to the current Ubuntu installation.
- Ensure your provider console/recovery access works before you begin.
- Always provide valid SSH public keys during migration to avoid lockout.
- Test on a disposable VPS before production rollout.

---

## License

Use at your own risk. Review scripts before running on important systems.
