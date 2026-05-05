#!/usr/bin/env bash
# ==============================================================================
#  setup_bond.sh — Bond + VLAN network configuration script
#  Supports locations: nl3, us1 (VLAN 2520) | de1 (VLAN 200)
#
#  USAGE EXAMPLES:
#  1. nl3 / us1 — auto VLAN 2520, IP auto-detected from interface:
#     ./setup_bond.sh --location nl3 --gw 10.0.20.1
#     ./setup_bond.sh --location us1 --gw 10.1.20.1
#
#  2. de1 — auto VLAN 200:
#     ./setup_bond.sh --location de1 --gw 10.2.0.1
#
#  3. Указать IP вручную (без автодетекта):
#     ./setup_bond.sh --location nl3 --ip 10.0.20.5/22 --gw 10.0.20.1
#
#  4. Ручной override VLAN:
#     ./setup_bond.sh --location nl3 --gw 10.0.20.1 --vlan 3000
#
#  5. Dry-run (вывод команд без применения):
#     ./setup_bond.sh --location de1 --gw 10.2.0.1 --dry-run
#
#  6. Dry-run + ручной IP + ручной VLAN:
#     ./setup_bond.sh --location us1 --ip 10.1.20.5/22 --gw 10.1.20.1 --vlan 500 --dry-run
#
#  7. Справка:
#     ./setup_bond.sh --help
# ==============================================================================

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# Helpers
info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
ok()      { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
err()     { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
die()     { err "$*"; exit 1; }
hr()      { echo -e "${CYAN}──────────────────────────────────────────────────${RESET}"; }

usage() {
  cat <<USAGE
${BOLD}Usage:${RESET}
  $0 --location <nl3|us1|de1> --gw <gateway> [--ip <IPv4/prefix>] [--vlan <id>] [--dry-run]

${BOLD}Options:${RESET}
  --location  nl3 / us1 / de1   Server location (determines default VLAN)
  --gw        192.168.0.1       Default gateway (required)
  --ip        192.168.1.10/22   IP+prefix CIDR (optional, auto-detected if omitted)
  --vlan      2520              Override VLAN ID (optional)
  --dry-run                     Print commands without executing them
  -h, --help                    Show this help

${BOLD}VLAN defaults by location:${RESET}
  nl3, us1  ->  2520  (Management, see https://netbox.fotbo.host/ipam/vlans/22/)
  de1       ->  200
USAGE
  exit 0
}

# Argument parsing
LOCATION=""
IPV4=""
GW=""
VLAN_OVERRIDE=""
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --location)  LOCATION="${2:-}";      shift 2 ;;
    --ip)        IPV4="${2:-}";          shift 2 ;;
    --gw)        GW="${2:-}";            shift 2 ;;
    --vlan)      VLAN_OVERRIDE="${2:-}"; shift 2 ;;
    --dry-run)   DRY_RUN=true;          shift   ;;
    -h|--help)   usage ;;
    *) die "Unknown argument: $1. Use --help for usage." ;;
  esac
done

# Validate required args
[[ -z "$LOCATION" ]] && die "--location is required (nl3 | us1 | de1)"
[[ -z "$GW"       ]] && die "--gw is required (e.g. 192.168.0.1)"

if ! [[ "$GW" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  die "Invalid gateway address: $GW"
fi

# Validate --ip if provided manually
if [[ -n "$IPV4" ]]; then
  if ! [[ "$IPV4" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[1-2][0-9]|3[0-2])$ ]]; then
    die "Invalid CIDR format: '$IPV4'. Expected format: 192.168.1.10/22"
  fi
fi

# Determine VLAN
if [[ -n "$VLAN_OVERRIDE" ]]; then
  VLAN="$VLAN_OVERRIDE"
  info "Using manually specified VLAN: ${BOLD}$VLAN${RESET}"
else
  case "$LOCATION" in
    nl3|us1) VLAN=2520 ;;
    de1)     VLAN=200  ;;
    *) die "Unknown location: '$LOCATION'. Supported: nl3, us1, de1" ;;
  esac
  info "Location ${BOLD}$LOCATION${RESET} -> VLAN ${BOLD}$VLAN${RESET}"
fi

# Discover physical interfaces (exclude loopback & virtual)
hr
info "Scanning network interfaces..."

mapfile -t IFACES < <(
  ip -o link show \
    | awk -F': ' '{print $2}' \
    | grep -v -E '^(lo|bond|vlan|docker|br-|veth|tun|tap|dummy|virbr)' \
    | sort
)

if [[ ${#IFACES[@]} -eq 0 ]]; then
  die "No physical interfaces found."
fi

echo ""
echo -e "${BOLD}Detected interfaces:${RESET}"
for i in "${!IFACES[@]}"; do
  IFACE="${IFACES[$i]}"
  ADDR=$(ip -o -4 addr show "$IFACE" 2>/dev/null | awk '{print $4}' | head -1)
  STATE=$(cat /sys/class/net/"$IFACE"/operstate 2>/dev/null || echo "unknown")
  ADDR_DISP="${ADDR:-(no IP)}"
  echo -e "  ${CYAN}[$((i+1))]${RESET}  ${BOLD}${IFACE}${RESET}   IP: ${ADDR_DISP}   State: ${STATE}"
done
echo ""

# Interface selection
if [[ ${#IFACES[@]} -eq 2 ]]; then
  IFACE1="${IFACES[0]}"
  IFACE2="${IFACES[1]}"
  ok "Exactly 2 interfaces found — using them automatically."
  info "  interface1 = ${BOLD}$IFACE1${RESET}"
  info "  interface2 = ${BOLD}$IFACE2${RESET}"

elif [[ ${#IFACES[@]} -gt 2 ]]; then
  warn "More than 2 interfaces detected. Please select the two to bond."
  echo ""

  while true; do
    read -rp "$(echo -e "  ${BOLD}Enter number for interface1:${RESET} ")" SEL1
    if [[ "$SEL1" =~ ^[0-9]+$ ]] && (( SEL1 >= 1 && SEL1 <= ${#IFACES[@]} )); then
      IFACE1="${IFACES[$((SEL1-1))]}"
      break
    fi
    warn "Invalid selection. Enter a number between 1 and ${#IFACES[@]}."
  done

  while true; do
    read -rp "$(echo -e "  ${BOLD}Enter number for interface2:${RESET} ")" SEL2
    if [[ "$SEL2" =~ ^[0-9]+$ ]] && (( SEL2 >= 1 && SEL2 <= ${#IFACES[@]} )); then
      if [[ "$SEL2" == "$SEL1" ]]; then
        warn "interface2 must differ from interface1 (${IFACE1})."
        continue
      fi
      IFACE2="${IFACES[$((SEL2-1))]}"
      break
    fi
    warn "Invalid selection. Enter a number between 1 and ${#IFACES[@]}."
  done

else
  die "Need at least 2 physical interfaces to create a bond. Found: ${#IFACES[@]}"
fi


# Auto-detect IP from selected interfaces (if not provided via --ip)
if [[ -z "$IPV4" ]]; then
  for TRY_IFACE in "$IFACE1" "$IFACE2"; do
    DETECTED=$(ip -o -4 addr show "$TRY_IFACE" 2>/dev/null | awk '{print $4}' | head -1)
    if [[ -n "$DETECTED" ]]; then
      IPV4="$DETECTED"
      ok "Auto-detected IP: ${BOLD}$IPV4${RESET} (from ${TRY_IFACE})"
      break
    fi
  done

  # If still empty — ask manually
  if [[ -z "$IPV4" ]]; then
    warn "Could not auto-detect IP on $IFACE1 or $IFACE2."
    while true; do
      read -rp "$(echo -e "  ${BOLD}Enter IP with prefix manually (e.g. 10.0.0.5/22):${RESET} ")" IPV4
      if [[ "$IPV4" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[1-2][0-9]|3[0-2])$ ]]; then
        break
      fi
      warn "Invalid CIDR format. Example: 10.0.0.5/22"
    done
  fi
fi

# Summary before execution
hr
echo -e "${BOLD}Configuration summary:${RESET}"
echo -e "  Location   : ${CYAN}$LOCATION${RESET}"
echo -e "  VLAN       : ${CYAN}$VLAN${RESET}"
echo -e "  IP/prefix  : ${CYAN}$IPV4${RESET}"
echo -e "  Gateway    : ${CYAN}$GW${RESET}"
echo -e "  DNS        : ${CYAN}8.8.8.8${RESET}"
echo -e "  Interface1 : ${CYAN}$IFACE1${RESET}"
echo -e "  Interface2 : ${CYAN}$IFACE2${RESET}"
echo -e "  Bond iface : ${CYAN}bond0${RESET}"
echo -e "  VLAN iface : ${CYAN}bond0.${VLAN}${RESET}"
hr
echo ""

if [[ "$DRY_RUN" == true ]]; then
  warn "DRY-RUN mode — commands will be printed but NOT executed."
  echo ""
fi

# Command runner
run() {
  echo -e "  ${YELLOW}▶${RESET} $*"
  if [[ "$DRY_RUN" == false ]]; then
    eval "$@"
  fi
}

# Confirm
read -rp "$(echo -e "${BOLD}Proceed with configuration? [y/N]:${RESET} ")" CONFIRM
[[ "${CONFIRM,,}" == "y" ]] || { info "Aborted."; exit 0; }
echo ""

# Apply configuration
info "Creating bond0 (802.3ad LACP)..."
run sudo nmcli connection add \
  type bond \
  ifname bond0 \
  mode 802.3ad \
  connection.autoconnect yes \
  ipv4.method disabled \
  ipv6.method ignore

info "Adding $IFACE1 as bond slave..."
run sudo nmcli connection add \
  type ethernet \
  ifname "$IFACE1" \
  master bond0 \
  connection.autoconnect yes

info "Adding $IFACE2 as bond slave..."
run sudo nmcli connection add \
  type ethernet \
  ifname "$IFACE2" \
  master bond0 \
  connection.autoconnect yes

info "Current connections:"
run sudo nmcli con show

info "Creating VLAN ${VLAN} on bond0..."
run sudo nmcli con add \
  type vlan \
  ifname "bond0.${VLAN}" \
  con-name "bond0.${VLAN}" \
  id "$VLAN" \
  dev bond0 \
  connection.autoconnect yes \
  ip4 "$IPV4" \
  gw4 "$GW" \
  ipv4.dns 8.8.8.8

info "Bringing up bond slave interfaces..."
run sudo nmcli connection up "bond-slave-$IFACE1"
run sudo nmcli connection up "bond-slave-$IFACE2"

hr
ok "Bond configuration complete!"
ok "  bond0.${VLAN}  ->  ${IPV4}  gw ${GW}"
hr
