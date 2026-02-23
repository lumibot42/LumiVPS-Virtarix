#!/usr/bin/env bash
set -euo pipefail

# OpenClaw + nix-openclaw bootstrap on fresh Ubuntu 24.04
# - Installs Determinate Nix (if missing)
# - Creates local flake from nix-openclaw template
# - Creates docs/persona files
# - Stores secrets in ~/.secrets
# - Applies Home Manager config
# - Verifies gateway service

#######################################
# Helpers
#######################################
log() { printf "\n[+] %s\n" "$*"; }
warn() { printf "\n[!] %s\n" "$*"; }
err() { printf "\n[✗] %s\n" "$*" >&2; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || { err "Missing command: $1"; exit 1; }; }

#######################################
# Inputs (can be pre-set via env)
#######################################
: "${OPENCLAW_LOCAL_DIR:=$HOME/code/openclaw-local}"
: "${OPENCLAW_FLAKE_TEMPLATE:=github:openclaw/nix-openclaw#agent-first}"
: "${OPENCLAW_PROFILE_NAME:=$USER}"
: "${OPENCLAW_DOCS_DIR:=$OPENCLAW_LOCAL_DIR/documents}"
: "${OPENCLAW_SECRETS_DIR:=$HOME/.secrets}"

# Optional provider settings
: "${OPENAI_API_KEY:=}"
: "${ANTHROPIC_API_KEY:=}"

#######################################
# Preflight
#######################################
if [[ "$(id -u)" -eq 0 ]]; then
  warn "Running as root is not recommended for Home Manager setup."
  warn "Use your normal user account if possible."
fi

if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  if [[ "${ID:-}" != "ubuntu" || "${VERSION_ID:-}" != "24.04" ]]; then
    warn "This script is designed for Ubuntu 24.04; detected: ${PRETTY_NAME:-unknown}."
  fi
fi

#######################################
# 1) Install Determinate Nix if missing
#######################################
if ! command -v nix >/dev/null 2>&1; then
  log "Installing Determinate Nix..."
  need_cmd curl
  curl --proto '=https' --tlsv1.2 -fsSL https://install.determinate.systems/nix | sh -s -- install --determinate
else
  log "Nix already installed: $(nix --version)"
fi

# Load nix profile for this shell
if [[ -e /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]]; then
  # shellcheck disable=SC1091
  . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
fi

need_cmd nix

#######################################
# 2) Ensure flakes + nix-command are enabled
#######################################
mkdir -p "$HOME/.config/nix"
if [[ -f "$HOME/.config/nix/nix.conf" ]]; then
  if ! grep -q '^experimental-features' "$HOME/.config/nix/nix.conf"; then
    printf '\nexperimental-features = nix-command flakes\n' >> "$HOME/.config/nix/nix.conf"
  fi
else
  printf 'experimental-features = nix-command flakes\n' > "$HOME/.config/nix/nix.conf"
fi

#######################################
# 3) Create local flake from template
#######################################
mkdir -p "$OPENCLAW_LOCAL_DIR"
cd "$OPENCLAW_LOCAL_DIR"

if [[ ! -f flake.nix ]]; then
  log "Initializing flake from template: $OPENCLAW_FLAKE_TEMPLATE"
  nix flake init -t "$OPENCLAW_FLAKE_TEMPLATE"
else
  log "flake.nix already exists, leaving it in place."
fi

#######################################
# 4) Create docs dir and seed core docs
#######################################
mkdir -p "$OPENCLAW_DOCS_DIR"
for f in AGENTS.md SOUL.md TOOLS.md IDENTITY.md USER.md HEARTBEAT.md; do
  if [[ -L "$HOME/.openclaw/workspace/$f" || -f "$HOME/.openclaw/workspace/$f" ]]; then
    cp -Lf "$HOME/.openclaw/workspace/$f" "$OPENCLAW_DOCS_DIR/$f"
  elif [[ ! -f "$OPENCLAW_DOCS_DIR/$f" ]]; then
    touch "$OPENCLAW_DOCS_DIR/$f"
  fi
done

#######################################
# 5) Save secrets in ~/.secrets (plain files)
#######################################
mkdir -p "$OPENCLAW_SECRETS_DIR"
chmod 700 "$OPENCLAW_SECRETS_DIR"

write_secret_file() {
  local path="$1"
  local value="$2"
  if [[ -n "$value" ]]; then
    printf '%s' "$value" > "$path"
    chmod 600 "$path"
  fi
}

write_secret_file "$OPENCLAW_SECRETS_DIR/openai-api-key" "$OPENAI_API_KEY"
write_secret_file "$OPENCLAW_SECRETS_DIR/anthropic-api-key" "$ANTHROPIC_API_KEY"

#######################################
# 6) Patch flake placeholders (best effort)
#######################################
if grep -q 'x86_64-darwin\|aarch64-darwin\|x86_64-linux\|aarch64-linux' flake.nix; then
  # Ensure system is x86_64-linux on Ubuntu 24.04 VPS.
  sed -i 's/system *= *"[^"]*"/system = "x86_64-linux"/g' flake.nix || true
fi

# Best-effort username/home path replacement for common template keys
sed -i "s|home.username *= *\"[^\"]*\"|home.username = \"$USER\"|g" flake.nix || true
sed -i "s|home.homeDirectory *= *\"[^\"]*\"|home.homeDirectory = \"$HOME\"|g" flake.nix || true

#######################################
# 7) Guidance for secrets wiring
#######################################
if [[ -z "$OPENAI_API_KEY" && -z "$ANTHROPIC_API_KEY" ]]; then
  warn "No model API keys provided. Set one of these env vars before rerun for full automation:"
  echo "  OPENAI_API_KEY"
  echo "  ANTHROPIC_API_KEY"
  warn "You can continue now and wire providers/channels later in flake.nix."
fi

#######################################
# 8) Apply Home Manager
#######################################
log "Applying Home Manager profile: $OPENCLAW_PROFILE_NAME"
# This will build/install home-manager via nix if needed and apply the flake.
nix run home-manager/master -- switch --flake ".#$OPENCLAW_PROFILE_NAME"

#######################################
# 9) Verify OpenClaw gateway service
#######################################
log "Verifying service..."
if systemctl --user status openclaw-gateway >/dev/null 2>&1; then
  systemctl --user --no-pager --full status openclaw-gateway || true
else
  warn "openclaw-gateway user service not found yet."
  warn "Check your flake module options in $OPENCLAW_LOCAL_DIR/flake.nix"
fi

if command -v openclaw >/dev/null 2>&1; then
  log "OpenClaw CLI status"
  openclaw status || true
else
  warn "openclaw command not found in current shell PATH yet; open a new shell and retry."
fi

log "Done."
log "Next: configure channels/providers in flake.nix as needed, then rerun Home Manager."
