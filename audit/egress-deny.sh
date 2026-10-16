#!/usr/bin/env bash
# Deny-all egress for the RAG stack's Docker network.
#
# Usage: sudo ./audit/egress-deny.sh on|off|status
#
# The rules live in DOCKER-USER, the chain Docker evaluates before its own
# forwarding rules. Traffic between containers on the stack network is
# allowed, and so are replies to connections that started outside it, such
# as your browser opening the Phoenix UI. Every other packet leaving the
# network is logged with the prefix EGRESS-BLOCK and rejected, so the sender
# fails immediately instead of waiting for a timeout.
#
# The firewall log is one of three records the audit keeps, alongside the
# DNS sinkhole log and the packet capture. Each one misses things the others
# catch, so no single record is treated as complete.

set -euo pipefail

BRIDGE="br-rag"
LOG_PREFIX="EGRESS-BLOCK "

if [[ $EUID -ne 0 ]]; then
  echo "Run with sudo." >&2
  exit 1
fi

if ! iptables -L DOCKER-USER -n >/dev/null 2>&1; then
  echo "DOCKER-USER chain not found. Is Docker Engine running?" >&2
  exit 1
fi

is_on() {
  iptables -C DOCKER-USER -i "$BRIDGE" -j REJECT 2>/dev/null
}

rules_on() {
  if is_on; then
    echo "Egress deny is already on."
    return
  fi

  iptables -I DOCKER-USER 1 -i "$BRIDGE" -o "$BRIDGE" -j RETURN
  iptables -I DOCKER-USER 2 -i "$BRIDGE" \
    -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN

  local next=3
  local logging="enabled"
  if iptables -I DOCKER-USER 3 -i "$BRIDGE" \
      -j LOG --log-prefix "$LOG_PREFIX" 2>/dev/null; then
    next=4
  else
    logging="UNAVAILABLE"
  fi

  iptables -I DOCKER-USER "$next" -i "$BRIDGE" -j REJECT
  echo "Egress deny is on for $BRIDGE."
  echo "Firewall-level logging: $logging"

  if [[ "$logging" == "UNAVAILABLE" ]]; then
    cat >&2 <<'MSG'
WARNING: this kernel does not support the iptables LOG target, so blocked
attempts will NOT appear in the kernel log. Traffic is still blocked. The
DNS log and packet capture remain, but they miss attempts the firewall log
would have caught. Record this gap in the audit report for this run.
MSG
  fi
}

rules_off() {
  iptables -D DOCKER-USER -i "$BRIDGE" -j REJECT 2>/dev/null || true
  iptables -D DOCKER-USER -i "$BRIDGE" \
    -j LOG --log-prefix "$LOG_PREFIX" 2>/dev/null || true
  iptables -D DOCKER-USER -i "$BRIDGE" \
    -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN 2>/dev/null || true
  iptables -D DOCKER-USER -i "$BRIDGE" -o "$BRIDGE" -j RETURN 2>/dev/null || true
  echo "Egress deny is off for $BRIDGE."
}

case "${1:-}" in
  on) rules_on ;;
  off) rules_off ;;
  status)
    iptables -L DOCKER-USER -n -v --line-numbers
    echo
    if ! is_on; then
      echo "Egress deny: off"
    elif iptables -C DOCKER-USER -i "$BRIDGE" \
        -j LOG --log-prefix "$LOG_PREFIX" 2>/dev/null; then
      echo "Egress deny: on. Firewall-level logging: enabled"
    else
      echo "Egress deny: on. Firewall-level logging: UNAVAILABLE"
    fi
    ;;
  *)
    echo "Usage: sudo $0 on|off|status" >&2
    exit 1
    ;;
esac
