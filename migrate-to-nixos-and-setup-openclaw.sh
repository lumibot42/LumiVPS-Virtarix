#!/usr/bin/env bash
set -Eeuo pipefail

# OpenClaw migration orchestrator
# - Phase 1 (Ubuntu 24.04): in-place migration to NixOS via nixos-infect
# - Phase 2 (NixOS): full OpenClaw Nix-mode bootstrap (Home Manager)
#
# IMPORTANT:
# This intentionally uses in-place migration (provider partition layout preserved).
# On remote VPS hosts, this is significantly safer than repartitioning from a live OS.

################################################################################
# Globals
################################################################################
SCRIPT_VERSION="2.0.0"
MIGRATION_DIR="/etc/nixos/openclaw-migration"
STATE_FILE="$MIGRATION_DIR/state.env"
PHASE1_IMPORT_FILE="$MIGRATION_DIR/host-extra.nix"
PHASE1_INFECT_SCRIPT="$MIGRATION_DIR/nixos-infect"
PHASE1_INFECT_LOG="$MIGRATION_DIR/infect.log"
REPORT_FILE="$MIGRATION_DIR/last-run-report.txt"
SCRIPT_COPY_PATH="$MIGRATION_DIR/migrate.sh"
DOC_BACKUP_DIR="$MIGRATION_DIR/documents-backup"

OS_ID="unknown"
OS_VERSION="unknown"
OS_PRETTY="unknown"

################################################################################
# Logging helpers
################################################################################
log()  { printf "\n[+] %s\n" "$*"; }
warn() { printf "\n[!] %s\n" "$*"; }
err()  { printf "\n[✗] %s\n" "$*" >&2; }

die() {
  err "$*"
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

################################################################################
# Prompt helpers
################################################################################
prompt_default() {
  local __var_name="$1"
  local prompt="$2"
  local default="${3:-}"
  local value
  if [[ -n "$default" ]]; then
    read -r -p "$prompt [$default]: " value || true
    value="${value:-$default}"
  else
    read -r -p "$prompt: " value || true
  fi
  printf -v "$__var_name" '%s' "$value"
}

prompt_yes_no() {
  local prompt="$1"
  local default="${2:-no}" # yes|no
  local hint="y/N"
  local value
  [[ "$default" == "yes" ]] && hint="Y/n"
  read -r -p "$prompt ($hint): " value || true
  value="${value,,}"
  if [[ -z "$value" ]]; then
    [[ "$default" == "yes" ]] && return 0 || return 1
  fi
  [[ "$value" == "y" || "$value" == "yes" ]]
}

prompt_secret() {
  local __var_name="$1"
  local prompt="$2"
  local value
  read -r -s -p "$prompt: " value || true
  echo
  printf -v "$__var_name" '%s' "$value"
}

################################################################################
# Runtime detection + state
################################################################################
require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
      warn "Re-running with sudo..."
      exec sudo -E bash "$0" "$@"
    fi
    die "Run this script as root (or with sudo)."
  fi
}

detect_os() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_VERSION="${VERSION_ID:-unknown}"
    OS_PRETTY="${PRETTY_NAME:-unknown}"
  fi
}

load_state() {
  mkdir -p "$MIGRATION_DIR"
  chmod 700 "$MIGRATION_DIR"
  if [[ -f "$STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE"
  fi
}

save_state() {
  umask 077
  {
    echo "# OpenClaw migration state"
    echo "# Generated: $(date -Is)"
    for v in \
      ADMIN_USER HOSTNAME_SHORT TIMEZONE NIXOS_CHANNEL \
      ENABLE_DO_NETCONF PROVIDER_HINT \
      RAM_MIB RECOMMENDED_SWAPFILE_MIB HAS_SWAP_DEVICE \
      SSH_KEYS_B64 \
      OPENCLAW_PROFILE_NAME OPENCLAW_LOCAL_DIR OPENCLAW_DOCS_DIR OPENCLAW_SECRETS_DIR \
      TELEGRAM_CHAT_ID OPENCLAW_GATEWAY_TOKEN \
      HAVE_TELEGRAM HAVE_OPENAI HAVE_ANTHROPIC \
      OPENCLAW_SYSTEM
    do
      printf '%s=%q\n' "$v" "${!v-}"
    done
  } > "$STATE_FILE"
}

write_report_header() {
  mkdir -p "$MIGRATION_DIR"
  chmod 700 "$MIGRATION_DIR"
  cat > "$REPORT_FILE" <<EOF
OpenClaw Migration Report
Generated: $(date -Is)
Script version: $SCRIPT_VERSION
Host OS: $OS_PRETTY ($OS_ID $OS_VERSION)

EOF
}

append_report() {
  printf '%s\n' "$*" >> "$REPORT_FILE"
}

persist_script_copy() {
  mkdir -p "$MIGRATION_DIR"
  chmod 700 "$MIGRATION_DIR"
  if [[ ! -f "$SCRIPT_COPY_PATH" ]] || ! cmp -s "$0" "$SCRIPT_COPY_PATH"; then
    install -m 700 "$0" "$SCRIPT_COPY_PATH"
  fi
}

################################################################################
# Validation helpers
################################################################################
validate_hostname() {
  local h="$1"
  [[ "$h" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{0,62}$ ]]
}

validate_int() {
  local v="$1"
  [[ "$v" =~ ^-?[0-9]+$ ]]
}

detect_openclaw_system() {
  case "$(uname -m)" in
    x86_64) OPENCLAW_SYSTEM="x86_64-linux" ;;
    aarch64|arm64) OPENCLAW_SYSTEM="aarch64-linux" ;;
    *) die "Unsupported architecture: $(uname -m)" ;;
  esac
}

################################################################################
# Infra probing (phase 1)
################################################################################
collect_host_facts() {
  need_cmd lsblk
  need_cmd findmnt
  need_cmd awk

  ROOT_SOURCE="$(findmnt -n -o SOURCE / || true)"
  ROOT_SOURCE_REAL="$(readlink -f "$ROOT_SOURCE" 2>/dev/null || echo "$ROOT_SOURCE")"

  ROOT_PART=""
  ROOT_DISK=""
  if [[ -n "$ROOT_SOURCE_REAL" ]]; then
    ROOT_PART="$ROOT_SOURCE_REAL"
    ROOT_DISK_BASE="$(lsblk -ndo PKNAME "$ROOT_SOURCE_REAL" 2>/dev/null || true)"
    if [[ -n "$ROOT_DISK_BASE" ]]; then
      ROOT_DISK="/dev/$ROOT_DISK_BASE"
    fi
  fi

  RAM_MIB="$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)"

  HAS_SWAP_DEVICE="no"
  if swapon --show --noheadings --raw 2>/dev/null | awk '{print $1}' | grep -q '^/dev/'; then
    HAS_SWAP_DEVICE="yes"
  fi

  if (( RAM_MIB <= 2048 )); then
    RECOMMENDED_SWAPFILE_MIB=2048
  elif (( RAM_MIB <= 8192 )); then
    RECOMMENDED_SWAPFILE_MIB="$RAM_MIB"
  elif (( RAM_MIB <= 32768 )); then
    RECOMMENDED_SWAPFILE_MIB=8192
  elif (( RAM_MIB <= 65536 )); then
    RECOMMENDED_SWAPFILE_MIB=16384
  else
    RECOMMENDED_SWAPFILE_MIB=32768
  fi

  if [[ "$HAS_SWAP_DEVICE" == "yes" ]]; then
    RECOMMENDED_SWAPFILE_MIB=0
  fi
}

capture_diagnostics() {
  mkdir -p "$MIGRATION_DIR"
  lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS > "$MIGRATION_DIR/lsblk-before.txt" || true
  ip -brief address > "$MIGRATION_DIR/ip-before.txt" || true
  cp -f /etc/resolv.conf "$MIGRATION_DIR/resolv-before.conf" 2>/dev/null || true
}

handle_tmpfs_tmp_if_needed() {
  local tmp_fstype tmp_avail_mib
  tmp_fstype="$(findmnt -n -o FSTYPE /tmp 2>/dev/null || true)"
  tmp_avail_mib="$(df -Pm /tmp 2>/dev/null | awk 'NR==2{print $4+0}')"

  if [[ "$tmp_fstype" == "tmpfs" && "$tmp_avail_mib" -lt 1500 ]]; then
    warn "/tmp is tmpfs with low free space (${tmp_avail_mib} MiB)."
    warn "nixos-infect uses /tmp for temporary swap; this can fail on some VPS setups."
    if prompt_yes_no "Try to unmount /tmp before migration?" "yes"; then
      if umount /tmp; then
        log "Unmounted /tmp successfully."
      else
        warn "Could not unmount /tmp. Continuing, but migration may fail if /tmp is too small."
      fi
    fi
  fi
}

################################################################################
# SSH key handling (phase 1)
################################################################################
collect_default_ssh_keys() {
  local candidates=()
  local f

  candidates+=("/root/.ssh/authorized_keys")
  if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
    candidates+=("/home/$SUDO_USER/.ssh/authorized_keys")
  fi

  local merged=""
  for f in "${candidates[@]}"; do
    if [[ -r "$f" ]]; then
      merged+="$(grep -E '^(ssh-|ecdsa-|sk-ssh-|sk-ecdsa-)' "$f" || true)"$'\n'
    fi
  done

  # Deduplicate while preserving order
  DEFAULT_SSH_KEYS="$(printf '%s' "$merged" | awk 'NF && !seen[$0]++')"
}

prompt_ssh_keys() {
  local final_keys=""

  collect_default_ssh_keys

  if [[ -n "${DEFAULT_SSH_KEYS:-}" ]]; then
    log "Found existing SSH public keys on this host."
    if prompt_yes_no "Use detected SSH keys as baseline?" "yes"; then
      final_keys+="$DEFAULT_SSH_KEYS"$'\n'
    fi
  fi

  echo
  echo "Paste any additional SSH public keys (one per line)."
  echo "End input with a single line: END"

  while IFS= read -r line; do
    [[ "$line" == "END" ]] && break
    [[ -z "$line" ]] && continue
    if [[ "$line" =~ ^(ssh-|ecdsa-|sk-ssh-|sk-ecdsa-) ]]; then
      final_keys+="$line"$'\n'
    else
      warn "Skipping line that does not look like an SSH public key: $line"
    fi
  done

  final_keys="$(printf '%s' "$final_keys" | awk 'NF && !seen[$0]++')"

  if [[ -z "$final_keys" ]]; then
    warn "No SSH keys configured. This is dangerous for remote VPS migration."
    warn "Without keys, you may lose access after reboot."
    if ! prompt_yes_no "Continue WITHOUT SSH keys (not recommended)?" "no"; then
      die "Aborted by user."
    fi
  fi

  SSH_KEYS_B64="$(printf '%s' "$final_keys" | base64 | tr -d '\n')"
}

################################################################################
# NixOS import generation (phase 1)
################################################################################
generate_phase1_import() {
  local keys_decoded keys_block swap_block

  keys_decoded="$(printf '%s' "${SSH_KEYS_B64:-}" | base64 -d 2>/dev/null || true)"
  keys_block=""
  if [[ -n "$keys_decoded" ]]; then
    while IFS= read -r k; do
      [[ -z "$k" ]] && continue
      keys_block+="      \"$k\"\n"
    done <<< "$keys_decoded"
  fi

  if [[ "${HAS_SWAP_DEVICE:-no}" == "yes" ]]; then
    swap_block="  # Existing swap block device detected; nixos-infect will carry it over."
  else
    swap_block="  # No swap block device detected; create swapfile sized to RAM tier.\n  swapDevices = [ { device = \"/swapfile\"; size = ${RECOMMENDED_SWAPFILE_MIB}; } ];"
  fi

  mkdir -p "$MIGRATION_DIR"
  cat > "$PHASE1_IMPORT_FILE" <<EOF
{ pkgs, ... }:
{
  networking.hostName = "${HOSTNAME_SHORT}";
  time.timeZone = "${TIMEZONE}";

  services.openssh.enable = true;
  services.openssh.settings = {
    PermitRootLogin = "prohibit-password";
    PasswordAuthentication = false;
    KbdInteractiveAuthentication = false;
  };

  users.users.${ADMIN_USER} = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = [
${keys_block}    ];
  };

  # For first-boot operability in headless VPS migration flows.
  security.sudo.wheelNeedsPassword = false;

  networking.firewall.enable = true;
  networking.firewall.allowedTCPPorts = [ 22 ];

  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  boot.tmp.cleanOnBoot = true;
  zramSwap.enable = true;
${swap_block}

  environment.systemPackages = with pkgs; [
    git curl wget vim jq tmux htop
  ];

  system.stateVersion = "24.11";
}
EOF
  chmod 600 "$PHASE1_IMPORT_FILE"
}

backup_workspace_documents() {
  mkdir -p "$DOC_BACKUP_DIR"
  chmod 700 "$DOC_BACKUP_DIR"

  local src_root
  src_root="/root/.openclaw/workspace"

  if [[ -d "$src_root" ]]; then
    for f in AGENTS.md SOUL.md TOOLS.md IDENTITY.md USER.md HEARTBEAT.md MEMORY.md; do
      if [[ -f "$src_root/$f" ]]; then
        cp -L "$src_root/$f" "$DOC_BACKUP_DIR/$f"
      fi
    done
  fi
}

run_nixos_infect() {
  need_cmd curl

  log "Downloading nixos-infect script..."
  curl -fsSL https://raw.githubusercontent.com/elitak/nixos-infect/master/nixos-infect -o "$PHASE1_INFECT_SCRIPT"
  chmod 700 "$PHASE1_INFECT_SCRIPT"

  log "Starting migration (this can disrupt SSH and trigger reboot)."
  warn "If connection drops: wait for reboot, reconnect as '${ADMIN_USER}', then run:"
  warn "  sudo bash $SCRIPT_COPY_PATH"

  local do_netconf_env=""
  [[ "${ENABLE_DO_NETCONF:-yes}" == "yes" ]] && do_netconf_env="doNetConf=y"

  # shellcheck disable=SC2086
  env \
    NIX_CHANNEL="$NIXOS_CHANNEL" \
    NIXOS_IMPORT="$PHASE1_IMPORT_FILE" \
    PROVIDER="${PROVIDER_HINT:-}" \
    $do_netconf_env \
    bash -x "$PHASE1_INFECT_SCRIPT" 2>&1 | tee "$PHASE1_INFECT_LOG"
}

phase1_prompt_inputs() {
  collect_host_facts

  local default_host
  default_host="$(hostname -s 2>/dev/null || echo openclaw-vps)"
  default_host="${default_host%%.*}"
  [[ -z "$default_host" ]] && default_host="openclaw-vps"

  ADMIN_USER="${ADMIN_USER:-lumi}"
  HOSTNAME_SHORT="${HOSTNAME_SHORT:-$default_host}"
  TIMEZONE="${TIMEZONE:-Europe/Berlin}"
  NIXOS_CHANNEL="${NIXOS_CHANNEL:-nixos-24.11}"
  ENABLE_DO_NETCONF="${ENABLE_DO_NETCONF:-yes}"
  PROVIDER_HINT="${PROVIDER_HINT:-virtarix}"

  log "Host facts"
  echo "  Root mount source : ${ROOT_SOURCE:-unknown}"
  echo "  Root disk         : ${ROOT_DISK:-unknown}"
  echo "  RAM               : ${RAM_MIB:-0} MiB"
  echo "  Swap device exists: ${HAS_SWAP_DEVICE:-no}"
  if [[ "${HAS_SWAP_DEVICE:-no}" != "yes" ]]; then
    echo "  Suggested swapfile: ${RECOMMENDED_SWAPFILE_MIB} MiB"
  fi

  echo
  prompt_default ADMIN_USER "Admin username to create on NixOS" "$ADMIN_USER"

  while true; do
    prompt_default HOSTNAME_SHORT "NixOS hostName (short RFC1035 label, no dots)" "$HOSTNAME_SHORT"
    if validate_hostname "$HOSTNAME_SHORT"; then
      break
    fi
    warn "Invalid hostname: '$HOSTNAME_SHORT'. Use letters/numbers/hyphen only, max 63 chars."
  done

  prompt_default TIMEZONE "Timezone" "$TIMEZONE"
  prompt_default NIXOS_CHANNEL "NixOS channel" "$NIXOS_CHANNEL"

  if prompt_yes_no "Generate static networking config during migration (recommended for VPS)?" "yes"; then
    ENABLE_DO_NETCONF="yes"
  else
    ENABLE_DO_NETCONF="no"
  fi

  prompt_default PROVIDER_HINT "Provider hint for nixos-infect (optional, e.g. hetznercloud/lightsail)" "$PROVIDER_HINT"

  prompt_ssh_keys

  save_state
}

phase1_run() {
  [[ "$OS_ID" == "ubuntu" ]] || die "Phase 1 is intended for Ubuntu. Detected: $OS_PRETTY"
  if [[ "$OS_VERSION" != "24.04" ]]; then
    warn "Expected Ubuntu 24.04, detected $OS_PRETTY. Continuing anyway."
  fi

  write_report_header
  append_report "Phase: Ubuntu -> NixOS migration"

  need_cmd awk
  need_cmd sed
  need_cmd base64
  need_cmd findmnt
  need_cmd lsblk
  need_cmd tee

  persist_script_copy
  capture_diagnostics
  phase1_prompt_inputs
  backup_workspace_documents
  handle_tmpfs_tmp_if_needed
  generate_phase1_import

  append_report "Admin user: $ADMIN_USER"
  append_report "Hostname: $HOSTNAME_SHORT"
  append_report "Timezone: $TIMEZONE"
  append_report "NixOS channel: $NIXOS_CHANNEL"
  append_report "Root disk detected: ${ROOT_DISK:-unknown}"
  append_report "RAM MiB: ${RAM_MIB:-0}"
  append_report "Swap device exists: ${HAS_SWAP_DEVICE:-no}"
  append_report "Recommended swapfile MiB: ${RECOMMENDED_SWAPFILE_MIB:-0}"
  append_report "doNetConf enabled: ${ENABLE_DO_NETCONF}"
  append_report "Provider hint: ${PROVIDER_HINT:-<none>}"
  append_report "Import file: $PHASE1_IMPORT_FILE"

  echo
  warn "You are about to replace Ubuntu with NixOS (in-place) on this VPS."
  warn "Partition table is preserved (best-practice for remote VPS migration)."
  warn "Root disk detected: ${ROOT_DISK:-unknown}"
  warn "A reboot is expected."

  local confirm_phrase="MIGRATE-${HOSTNAME_SHORT}"
  local typed
  read -r -p "Type '$confirm_phrase' to proceed: " typed
  [[ "$typed" == "$confirm_phrase" ]] || die "Confirmation phrase mismatch. Aborted."

  run_nixos_infect

  append_report "nixos-infect invoked. Log: $PHASE1_INFECT_LOG"
  append_report "Next step after reboot: sudo bash $SCRIPT_COPY_PATH"

  log "Migration command finished (or reboot triggered)."
  log "After reconnecting to NixOS, run: sudo bash $SCRIPT_COPY_PATH"
  log "Report written: $REPORT_FILE"
}

################################################################################
# Phase 2: NixOS + OpenClaw
################################################################################
run_as_admin() {
  local cmd="$1"
  if command -v sudo >/dev/null 2>&1; then
    sudo -H -u "$ADMIN_USER" bash -lc "$cmd"
  else
    su - "$ADMIN_USER" -c "$cmd"
  fi
}

write_secret_file() {
  local owner="$1"
  local path="$2"
  local value="$3"
  [[ -n "$value" ]] || return 0

  local tmp
  tmp="$(mktemp)"
  chmod 600 "$tmp"
  printf '%s' "$value" > "$tmp"
  install -o "$owner" -g "$owner" -m 600 "$tmp" "$path"
  rm -f "$tmp"
}

prompt_phase2_inputs() {
  # Defaults
  ADMIN_USER="${ADMIN_USER:-${SUDO_USER:-lumi}}"
  OPENCLAW_PROFILE_NAME="${OPENCLAW_PROFILE_NAME:-$ADMIN_USER}"

  local admin_home
  admin_home="$(getent passwd "$ADMIN_USER" | cut -d: -f6 || true)"

  if [[ -z "$admin_home" ]]; then
    while true; do
      prompt_default ADMIN_USER "Admin username created during migration" "$ADMIN_USER"
      admin_home="$(getent passwd "$ADMIN_USER" | cut -d: -f6 || true)"
      [[ -n "$admin_home" ]] && break
      warn "User '$ADMIN_USER' does not exist on this host."
    done
  fi

  OPENCLAW_LOCAL_DIR="${OPENCLAW_LOCAL_DIR:-$admin_home/code/openclaw-local}"
  OPENCLAW_DOCS_DIR="${OPENCLAW_DOCS_DIR:-$OPENCLAW_LOCAL_DIR/documents}"
  OPENCLAW_SECRETS_DIR="${OPENCLAW_SECRETS_DIR:-$admin_home/.secrets}"

  prompt_default OPENCLAW_PROFILE_NAME "Home Manager profile name" "$OPENCLAW_PROFILE_NAME"
  prompt_default OPENCLAW_LOCAL_DIR "OpenClaw local flake dir" "$OPENCLAW_LOCAL_DIR"
  prompt_default OPENCLAW_DOCS_DIR "OpenClaw documents dir" "$OPENCLAW_DOCS_DIR"
  prompt_default OPENCLAW_SECRETS_DIR "Secrets dir" "$OPENCLAW_SECRETS_DIR"

  # Telegram is required for "ready to go" remote control
  HAVE_TELEGRAM="yes"
  while true; do
    prompt_secret TELEGRAM_BOT_TOKEN "Telegram bot token (@BotFather)"
    [[ -n "$TELEGRAM_BOT_TOKEN" ]] && break
    warn "Telegram bot token is required for a usable remote setup."
  done

  while true; do
    prompt_default TELEGRAM_CHAT_ID "Telegram user ID from @userinfobot (integer)" "${TELEGRAM_CHAT_ID:-}"
    if validate_int "$TELEGRAM_CHAT_ID"; then
      break
    fi
    warn "Chat ID must be an integer (e.g. 12345678)."
  done

  HAVE_OPENAI="no"
  HAVE_ANTHROPIC="no"

  if prompt_yes_no "Add OpenAI API key?" "yes"; then
    prompt_secret OPENAI_API_KEY "OpenAI API key"
    [[ -n "$OPENAI_API_KEY" ]] && HAVE_OPENAI="yes"
  fi

  if prompt_yes_no "Add Anthropic API key?" "yes"; then
    prompt_secret ANTHROPIC_API_KEY "Anthropic API key"
    [[ -n "$ANTHROPIC_API_KEY" ]] && HAVE_ANTHROPIC="yes"
  fi

  if [[ "$HAVE_OPENAI" != "yes" && "$HAVE_ANTHROPIC" != "yes" ]]; then
    warn "No model API key configured. Gateway can start, but AI responses will fail."
    if ! prompt_yes_no "Continue anyway?" "no"; then
      die "Aborted: configure at least one model API key."
    fi
  fi

  if [[ -z "${OPENCLAW_GATEWAY_TOKEN:-}" ]]; then
    need_cmd openssl
    OPENCLAW_GATEWAY_TOKEN="$(openssl rand -hex 32)"
  fi

  detect_openclaw_system
  save_state
}

prepare_openclaw_directories() {
  run_as_admin "mkdir -p '$OPENCLAW_LOCAL_DIR' '$OPENCLAW_DOCS_DIR' '$OPENCLAW_SECRETS_DIR'"
  run_as_admin "chmod 700 '$OPENCLAW_SECRETS_DIR'"

  # Restore any backed-up docs from phase 1 first
  if [[ -d "$DOC_BACKUP_DIR" ]]; then
    local f
    for f in AGENTS.md SOUL.md TOOLS.md IDENTITY.md USER.md HEARTBEAT.md MEMORY.md; do
      if [[ -f "$DOC_BACKUP_DIR/$f" && ! -f "$OPENCLAW_DOCS_DIR/$f" ]]; then
        install -o "$ADMIN_USER" -g "$ADMIN_USER" -m 600 "$DOC_BACKUP_DIR/$f" "$OPENCLAW_DOCS_DIR/$f"
      fi
    done
  fi

  # Ensure mandatory docs exist
  run_as_admin "touch '$OPENCLAW_DOCS_DIR/AGENTS.md' '$OPENCLAW_DOCS_DIR/SOUL.md' '$OPENCLAW_DOCS_DIR/TOOLS.md'"
}

write_openclaw_secrets() {
  local openai_path anthropic_path telegram_token_path

  telegram_token_path="$OPENCLAW_SECRETS_DIR/telegram-bot-token"
  write_secret_file "$ADMIN_USER" "$telegram_token_path" "$TELEGRAM_BOT_TOKEN"

  if [[ "$HAVE_OPENAI" == "yes" ]]; then
    openai_path="$OPENCLAW_SECRETS_DIR/openai-api-key"
    write_secret_file "$ADMIN_USER" "$openai_path" "$OPENAI_API_KEY"
  fi

  if [[ "$HAVE_ANTHROPIC" == "yes" ]]; then
    anthropic_path="$OPENCLAW_SECRETS_DIR/anthropic-api-key"
    write_secret_file "$ADMIN_USER" "$anthropic_path" "$ANTHROPIC_API_KEY"
  fi
}

generate_openclaw_flake() {
  local admin_home plugin_env_lines
  admin_home="$(getent passwd "$ADMIN_USER" | cut -d: -f6)"

  plugin_env_lines=""
  if [[ "$HAVE_OPENAI" == "yes" ]]; then
    plugin_env_lines+="                    OPENAI_API_KEY = \"$OPENCLAW_SECRETS_DIR/openai-api-key\";\n"
  fi
  if [[ "$HAVE_ANTHROPIC" == "yes" ]]; then
    plugin_env_lines+="                    ANTHROPIC_API_KEY = \"$OPENCLAW_SECRETS_DIR/anthropic-api-key\";\n"
  fi

  cat > "$OPENCLAW_LOCAL_DIR/flake.nix" <<EOF
{
  description = "OpenClaw local";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
    nix-openclaw.url = "github:openclaw/nix-openclaw";
  };

  outputs =
    {
      self,
      nixpkgs,
      home-manager,
      nix-openclaw,
    }:
    let
      system = "${OPENCLAW_SYSTEM}";
      pkgs = import nixpkgs {
        inherit system;
        overlays = [ nix-openclaw.overlays.default ];
      };
    in
    {
      homeConfigurations."${OPENCLAW_PROFILE_NAME}" = home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        modules = [
          nix-openclaw.homeManagerModules.openclaw
          {
            home.username = "${ADMIN_USER}";
            home.homeDirectory = "${admin_home}";
            home.stateVersion = "24.11";
            programs.home-manager.enable = true;

            programs.openclaw = {
              enable = true;
              documents = ./documents;

              config = {
                gateway = {
                  mode = "local";
                  auth = {
                    mode = "token";
                    token = "${OPENCLAW_GATEWAY_TOKEN}";
                  };
                };

                channels.telegram = {
                  tokenFile = "${OPENCLAW_SECRETS_DIR}/telegram-bot-token";
                  allowFrom = [ ${TELEGRAM_CHAT_ID} ];
                  groups = {
                    "*" = {
                      requireMention = true;
                    };
                  };
                };
              };

              customPlugins = [
                {
                  source = "github:openclaw/nix-steipete-tools?dir=tools/summarize";
                  config = {
                    env = {
${plugin_env_lines}                    };
                  };
                }
              ];
            };
          }
        ];
      };
    };
}
EOF

  chown "$ADMIN_USER":"$ADMIN_USER" "$OPENCLAW_LOCAL_DIR/flake.nix"

  # Copy local docs into flake documents dir if they are not already there
  local f
  for f in AGENTS.md SOUL.md TOOLS.md IDENTITY.md USER.md HEARTBEAT.md MEMORY.md; do
    if [[ -f "$OPENCLAW_DOCS_DIR/$f" ]]; then
      chown "$ADMIN_USER":"$ADMIN_USER" "$OPENCLAW_DOCS_DIR/$f"
    fi
  done

  # flake expects ./documents relative to flake root
  if [[ "$OPENCLAW_DOCS_DIR" != "$OPENCLAW_LOCAL_DIR/documents" ]]; then
    run_as_admin "rm -rf '$OPENCLAW_LOCAL_DIR/documents' && ln -s '$OPENCLAW_DOCS_DIR' '$OPENCLAW_LOCAL_DIR/documents'"
  fi
}

apply_home_manager_and_verify() {
  local admin_uid runtime_dir
  admin_uid="$(id -u "$ADMIN_USER")"
  runtime_dir="/run/user/$admin_uid"

  # Ensure user services can stay online after reboot
  loginctl enable-linger "$ADMIN_USER" >/dev/null 2>&1 || true
  loginctl start-user "$ADMIN_USER" >/dev/null 2>&1 || true

  run_as_admin "cd '$OPENCLAW_LOCAL_DIR' && nix run home-manager/master -- switch --flake '.#${OPENCLAW_PROFILE_NAME}'"

  # Try to manage user service explicitly (best effort)
  run_as_admin "export XDG_RUNTIME_DIR='$runtime_dir'; export DBUS_SESSION_BUS_ADDRESS='unix:path=$runtime_dir/bus'; systemctl --user daemon-reload || true"
  run_as_admin "export XDG_RUNTIME_DIR='$runtime_dir'; export DBUS_SESSION_BUS_ADDRESS='unix:path=$runtime_dir/bus'; systemctl --user enable --now openclaw-gateway || true"

  run_as_admin "export XDG_RUNTIME_DIR='$runtime_dir'; export DBUS_SESSION_BUS_ADDRESS='unix:path=$runtime_dir/bus'; systemctl --user --no-pager --full status openclaw-gateway || true"
  run_as_admin "command -v openclaw >/dev/null 2>&1 && openclaw gateway status || true"
}

phase2_run() {
  [[ "$OS_ID" == "nixos" ]] || die "Phase 2 must run on NixOS. Detected: $OS_PRETTY"

  write_report_header
  append_report "Phase: NixOS OpenClaw setup"

  need_cmd nix
  need_cmd getent
  need_cmd install
  need_cmd loginctl

  persist_script_copy
  load_state
  prompt_phase2_inputs

  append_report "Admin user: $ADMIN_USER"
  append_report "Profile: $OPENCLAW_PROFILE_NAME"
  append_report "OpenClaw system: $OPENCLAW_SYSTEM"
  append_report "Local dir: $OPENCLAW_LOCAL_DIR"
  append_report "Docs dir: $OPENCLAW_DOCS_DIR"
  append_report "Secrets dir: $OPENCLAW_SECRETS_DIR"
  append_report "Telegram configured: $HAVE_TELEGRAM"
  append_report "OpenAI key configured: $HAVE_OPENAI"
  append_report "Anthropic key configured: $HAVE_ANTHROPIC"

  prepare_openclaw_directories
  write_openclaw_secrets
  generate_openclaw_flake
  apply_home_manager_and_verify

  append_report "Home Manager applied successfully."
  append_report "OpenClaw service verification attempted."

  log "OpenClaw setup complete."
  log "Report written: $REPORT_FILE"
  log "If bot does not respond immediately, check logs:"
  log "  sudo -u $ADMIN_USER journalctl --user -u openclaw-gateway -f"
}

################################################################################
# Main
################################################################################
main() {
  require_root "$@"
  detect_os
  load_state

  echo "OpenClaw migration orchestrator v$SCRIPT_VERSION"
  echo "Detected OS: $OS_PRETTY"

  case "$OS_ID" in
    ubuntu)
      phase1_run
      ;;
    nixos)
      phase2_run
      ;;
    *)
      die "Unsupported OS for this script: $OS_PRETTY"
      ;;
  esac
}

main "$@"
