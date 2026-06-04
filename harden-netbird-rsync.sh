#!/usr/bin/env bash
set -euo pipefail

# Harden rsync exposure so it is only reachable on wt0 (Netbird tunnel).
# Works on Raspberry Pi OS / Debian-like systems.
# Roles:
#   server (pi5): keep rsync daemon, bind it to wt0, firewall allow only peer wt0 IP
#   client (pi4): disable rsync daemon listener, block inbound 873

ROLE=""
PEER_WT0_IP=""
YES=0

usage() {
  cat <<USAGE
Usage:
  ./harden-netbird-rsync.sh --role server --peer-wt0-ip 100.127.65.220 [--yes]
  ./harden-netbird-rsync.sh --role client --peer-wt0-ip 100.127.232.204 [--yes]

Options:
  --role server|client      Required for non-interactive use.
  --peer-wt0-ip IP          Required. Netbird IP of the opposite Pi.
  --yes                     Non-interactive confirmation.
  -h, --help                Show help.

Notes:
  - Server role binds rsync daemon to local wt0 IP in /etc/rsyncd.conf.
  - UFW is used if present. If UFW is missing, script prints manual commands.
USAGE
}

log() { printf '[*] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die() { printf '[x] %s\n' "$*" >&2; exit 1; }

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    command -v sudo >/dev/null 2>&1 || die "This script needs root privileges and sudo is not installed."
    log "Re-running with sudo."
    exec sudo -- "$0" "$@"
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --role)
        ROLE="${2:-}"; shift 2 ;;
      --peer-wt0-ip)
        PEER_WT0_IP="${2:-}"; shift 2 ;;
      --yes)
        YES=1; shift ;;
      -h|--help)
        usage; exit 0 ;;
      *)
        die "Unknown option: $1" ;;
    esac
  done
}

prompt_if_needed() {
  if [[ -z "${ROLE}" ]]; then
    echo "Select role:"
    echo "  1) server (pi5, runs rsync daemon)"
    echo "  2) client (pi4, pulls/pushes, no rsync daemon listener)"
    read -r -p "Enter 1 or 2: " ans
    case "$ans" in
      1) ROLE="server" ;;
      2) ROLE="client" ;;
      *) die "Invalid selection." ;;
    esac
  fi

  if [[ "${ROLE}" != "server" && "${ROLE}" != "client" ]]; then
    die "--role must be server or client."
  fi

  if [[ -z "${PEER_WT0_IP}" ]]; then
    read -r -p "Enter peer wt0 IP (other Pi Netbird IP): " PEER_WT0_IP
  fi

  [[ "${PEER_WT0_IP}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "Invalid --peer-wt0-ip."
}

get_local_ips() {
  WT0_IP="$(ip -4 -o addr show dev wt0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 || true)"
  ETH0_IP="$(ip -4 -o addr show dev eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 || true)"

  [[ -n "${WT0_IP}" ]] || die "wt0 interface/IP not found. Is Netbird up?"
  [[ -n "${ETH0_IP}" ]] || warn "eth0 IPv4 not found."
}

confirm_plan() {
  echo
  echo "Role:            ${ROLE}"
  echo "Local wt0 IP:    ${WT0_IP}"
  echo "Peer wt0 IP:     ${PEER_WT0_IP}"
  echo "Local eth0 IP:   ${ETH0_IP:-N/A}"
  echo

  if [[ "${YES}" -eq 0 ]]; then
    read -r -p "Proceed with changes? [y/N] " ok
    [[ "${ok}" =~ ^[Yy]$ ]] || die "Aborted."
  fi
}

backup_file() {
  local f="$1"
  if [[ -f "${f}" ]]; then
    cp -a "${f}" "${f}.bak.$(date +%Y%m%d%H%M%S)"
  fi
}

ensure_rsync_bind_wt0() {
  local conf="/etc/rsyncd.conf"
  local tmp=""
  backup_file "${conf}"
  touch "${conf}"

  # Keep a single global address directive before the first module block.
  sed -i -E '/^# Bound by harden-netbird-rsync\.sh$/d' "${conf}"
  sed -i -E '/^\s*address\s*=.*/d' "${conf}"
  tmp="$(mktemp)"
  awk -v ip="${WT0_IP}" '
    BEGIN { inserted = 0 }
    /^[[:space:]]*\[/ && inserted == 0 {
      print "# Bound by harden-netbird-rsync.sh"
      print "address = " ip
      inserted = 1
    }
    { print }
    END {
      if (inserted == 0) {
        print ""
        print "# Bound by harden-netbird-rsync.sh"
        print "address = " ip
      }
    }
  ' "${conf}" > "${tmp}"
  mv "${tmp}" "${conf}"

  # Basic safety defaults if absent.
  grep -Eq '^\s*use chroot\s*=' "${conf}" || echo "use chroot = yes" >> "${conf}"
  grep -Eq '^\s*read only\s*=' "${conf}" || echo "read only = true" >> "${conf}"

  systemctl enable rsync >/dev/null 2>&1 || true
  systemctl restart rsync
}

ensure_rsync_wait_for_wt0() {
  local dropin_dir="/etc/systemd/system/rsync.service.d"
  local dropin_file="${dropin_dir}/wt0-wait.conf"
  mkdir -p "${dropin_dir}"

  cat > "${dropin_file}" <<'EOF'
[Unit]
After=network-online.target
Wants=network-online.target

[Service]
ExecStartPre=/bin/sh -c 'for i in $(seq 1 30); do ip -4 -o addr show dev wt0 | grep -q "inet " && exit 0; sleep 1; done; echo "wt0 IPv4 not ready" >&2; exit 1'
Restart=on-failure
RestartSec=5
StartLimitIntervalSec=0
EOF

  systemctl daemon-reload
}

disable_rsync_daemon() {
  systemctl disable --now rsync >/dev/null 2>&1 || true
}

ufw_exists() {
  command -v ufw >/dev/null 2>&1
}

ufw_active() {
  ufw status | head -n1 | grep -qi "Status: active"
}

ufw_has_rule() {
  local rule="$1"
  ufw status | grep -Fq -- "$rule"
}

clear_ufw_rsync_rules() {
  local nums=()
  # Remove all existing 873/tcp rules so role switches stay consistent.
  mapfile -t nums < <(ufw status numbered | sed -n 's/^\[ *\([0-9][0-9]*\)\].*873\/tcp.*/\1/p' | sort -rn)
  for n in "${nums[@]}"; do
    ufw --force delete "$n" >/dev/null
  done
}

configure_ufw_server() {
  log "Applying UFW rules for server role."
  clear_ufw_rsync_rules
  # Allow rsync only from peer over wt0.
  if ! ufw_has_rule "873/tcp on wt0 ALLOW IN ${PEER_WT0_IP}"; then
    ufw allow in on wt0 from "${PEER_WT0_IP}" to any port 873 proto tcp comment 'rsync over netbird'
  fi
  # Explicitly block LAN/Wi-Fi rsync exposure.
  if ! ufw_has_rule "873/tcp on eth0 DENY IN Anywhere"; then
    ufw deny in on eth0 to any port 873 proto tcp comment 'block rsync on LAN' || true
  fi
  if ip link show wlan0 >/dev/null 2>&1; then
    if ! ufw_has_rule "873/tcp on wlan0 DENY IN Anywhere"; then
      ufw deny in on wlan0 to any port 873 proto tcp comment 'block rsync on Wi-Fi' || true
    fi
  fi
}

configure_ufw_client() {
  log "Applying UFW rules for client role."
  clear_ufw_rsync_rules
  if ! ufw_has_rule "873/tcp DENY IN Anywhere"; then
    ufw deny in to any port 873 proto tcp comment 'client should not accept rsync daemon'
  fi
}

manual_firewall_instructions() {
  warn "UFW is not installed. No firewall changes were applied."
  echo
  echo "Manual nftables/iptables intent:"
  if [[ "${ROLE}" == "server" ]]; then
    echo "  - allow tcp/873 from ${PEER_WT0_IP} on wt0"
    echo "  - drop tcp/873 on eth0 and wlan0"
  else
    echo "  - drop inbound tcp/873 on all interfaces"
  fi
  echo
}

show_postcheck() {
  echo
  log "Post-check listeners (22/873):"
  ss -tulpen | awk 'NR==1 || /:22[[:space:]]|:873[[:space:]]/'
  echo
  if ufw_exists; then
    log "UFW status:"
    ufw status numbered
  fi
}

main() {
  require_root "$@"
  parse_args "$@"
  prompt_if_needed
  get_local_ips
  confirm_plan

  if [[ "${ROLE}" == "server" ]]; then
    log "Configuring server role."
    ensure_rsync_wait_for_wt0
    ensure_rsync_bind_wt0
    if ufw_exists; then
      if ufw_active; then
        configure_ufw_server
      else
        warn "UFW is installed but inactive; skipping rule changes."
        warn "Enable UFW first, then rerun this script."
      fi
    else
      manual_firewall_instructions
    fi
  else
    log "Configuring client role."
    disable_rsync_daemon
    if ufw_exists; then
      if ufw_active; then
        configure_ufw_client
      else
        warn "UFW is installed but inactive; skipping rule changes."
        warn "Enable UFW first, then rerun this script."
      fi
    else
      manual_firewall_instructions
    fi
  fi

  show_postcheck
  log "Done."
}

main "$@"
