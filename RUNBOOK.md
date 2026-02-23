# RUNBOOK.md — Ubuntu 24.04 → NixOS → OpenClaw (Virtarix)

This runbook is the **operational playbook** for executing the migration script with minimal surprises.

---

## 1) Scope

This runbook covers:

- starting from fresh Ubuntu 24.04
- running `migrate-to-nixos-and-setup-openclaw.sh`
- reconnecting after reboot
- finishing OpenClaw bootstrap on NixOS
- handling common failures quickly

Channel setup (Discord/etc.) is intentionally out of scope during bootstrap.

---

## 2) Recommended defaults (use these unless you intentionally override)

- admin user: `lumi`
- timezone: `America/Chicago`
- provider hint: `virtarix`
- NixOS channel: `nixos-24.11`
- static net config during migration: `yes`

---

## 3) Preflight checklist (before touching anything)

- [ ] Snapshot/backup created in VPS panel
- [ ] VPS console/recovery access verified
- [ ] At least 1 valid SSH public key available
- [ ] You can tolerate reboot + brief downtime
- [ ] You have OpenAI and/or Anthropic API key ready

---

## 4) Phase 1 execution (Ubuntu)

## 4.1 Connect

```bash
ssh root@<server-ip>
```

## 4.2 Install bootstrap dependencies

```bash
apt-get update
```

```bash
apt-get install -y ca-certificates curl git openssh-client
```

## 4.3 Clone repo

```bash
git clone https://github.com/lumibot42/LumiVPS-Virtarix.git
```

```bash
cd LumiVPS-Virtarix
```

## 4.4 Run migration script

```bash
sudo bash ./migrate-to-nixos-and-setup-openclaw.sh
```

## 4.5 Prompt answers (recommended)

Use these values at prompts:

- **Admin username to create on NixOS** → `lumi`
- **NixOS hostName** → pick something short, e.g. `lumi-vps`
- **Timezone** → `America/Chicago`
- **NixOS channel** → `nixos-24.11`
- **Generate static networking config during migration?** → `yes`
- **Provider hint** → `virtarix`
- **SSH keys** → include your key(s), end with `END`

Final confirmation phrase will look like:

`MIGRATE-<hostname>`

Type it exactly.

## 4.6 Expected behavior

- script downloads and runs `nixos-infect`
- SSH may drop during migration/reboot
- machine comes back as NixOS

---

## 5) Phase 2 execution (NixOS)

## 5.1 Reconnect

```bash
ssh lumi@<server-ip>
```

## 5.2 Continue from persistent script path

```bash
sudo bash /etc/nixos/openclaw-migration/migrate.sh
```

## 5.3 Prompt answers (recommended)

- **Admin username created during migration** → `lumi`
- **Home Manager profile name** → `lumi`
- **OpenClaw local flake dir** → accept default unless needed
- **OpenClaw documents dir** → accept default unless needed
- **Secrets dir** → accept default unless needed
- **OpenAI key** → set if available
- **Anthropic key** → set if available

At least one model key should be configured.

## 5.4 Expected behavior

- Home Manager applies generated flake
- OpenClaw gateway user service is enabled/started
- report is written under `/etc/nixos/openclaw-migration/`

---

## 6) Post-run verification

## 6.1 Check gateway service

```bash
sudo -u lumi systemctl --user status openclaw-gateway
```

## 6.2 Follow logs

```bash
sudo -u lumi journalctl --user -u openclaw-gateway -f
```

## 6.3 Check migration report

```bash
sudo cat /etc/nixos/openclaw-migration/last-run-report.txt
```

## 6.4 Check PATH/command resolution diagnostics

```bash
sudo grep -E "^(PATH in use|cmd )" /etc/nixos/openclaw-migration/last-run-report.txt
```

---

## 7) Fast recovery map (common issues)

## A) SSH does not return after phase 1

Use Virtarix console, then inspect:

```bash
cat /etc/nixos/openclaw-migration/infect.log
```

```bash
ip -brief address
```

```bash
journalctl -b -p err --no-pager
```

If needed, re-run phase 2 once networking is restored:

```bash
sudo bash /etc/nixos/openclaw-migration/migrate.sh
```

## B) Home Manager apply fails

Check error output first, then retry:

```bash
sudo bash /etc/nixos/openclaw-migration/migrate.sh
```

Most common causes:
- transient network/DNS issue
- invalid custom path/profile override
- temporary Nix fetch hiccup

## C) Gateway service is inactive/failed

```bash
sudo -u lumi systemctl --user --no-pager --full status openclaw-gateway
```

```bash
sudo -u lumi journalctl --user -u openclaw-gateway --no-pager -n 200
```

---

## 8) Re-run behavior (safe)

The script is designed to be rerun.

- On Ubuntu: it prepares and executes migration.
- On NixOS: it continues OpenClaw setup.
- Existing secret files can be reused.
- Reports + artifacts remain in `/etc/nixos/openclaw-migration`.

---

## 9) After bootstrap (optional next step)

Add Discord (or another channel) to `flake.nix`, then apply Home Manager again.

```bash
cd /home/lumi/code/openclaw-local
```

```bash
sudo -u lumi nix run home-manager/master -- switch --flake .#lumi
```

---

## 10) Abort/rollback strategy

If migration quality is unacceptable, restore from your pre-migration VPS snapshot.

That is the fastest and most reliable rollback path.
