#!/usr/bin/env bash
# Summarize one capture run.
#
# Usage: sudo ./audit/summarize.sh capture/<run-name>
#
# Reads three independent records of the same run:
#   <run-name>.dns.log       the sinkhole's query log (what components wanted)
#   <run-name>.pcap          the packet capture on br-rag (what they sent)
#   <run-name>.kernel.log    the kernel log with firewall entries (what was blocked)
# plus <run-name>.tcpdump.txt for the capture's drop counters.
#
# Each record has blind spots the others cover, so the report ends with a
# coverage section stating what each one contained.

set -euo pipefail

RUN="${1:?Usage: sudo $0 capture/<run-name>}"
PCAP="${RUN}.pcap"
DNSLOG="${RUN}.dns.log"
KERNLOG="${RUN}.kernel.log"
TCPDUMP_OUT="${RUN}.tcpdump.txt"
SUBNET="10.77.0.0/24"

# Replace the fixed stack addresses with component names.
label() {
  sed -E \
    -e 's/\b10\.77\.0\.10\b/vectorai/g' \
    -e 's/\b10\.77\.0\.11\b/ollama/g' \
    -e 's/\b10\.77\.0\.12\b/phoenix/g' \
    -e 's/\b10\.77\.0\.20\b/app/g' \
    -e 's/\b10\.77\.0\.53\b/dns-sinkhole/g' \
    -e 's/\b10\.77\.0\.1\b/docker-dns-forwarder/g'
}

echo "== DNS lookups, UTC (first seen, asked by, record type, hostname, count) =="
if [[ -s "$DNSLOG" ]]; then
  label < "$DNSLOG" | awk '
    /query\[/ {
      time = $3
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^query\[/) { type = substr($i, 7, length($i) - 7); name = $(i + 1) }
        if ($i == "from") { src = $(i + 1) }
      }
      key = src " " type " " name
      if (!(key in first)) { first[key] = time; order[++n] = key }
      count[key]++
    }
    END {
      for (i = 1; i <= n; i++) {
        split(order[i], k, " ")
        printf "%s  %-22s %-5s %-50s x%d\n", first[order[i]], k[1], k[2], k[3], count[order[i]]
      }
    }
  '
else
  echo "(no DNS lookups recorded)"
fi

echo
echo "== Connection attempts leaving the stack, UTC (first seen, from, to, count) =="
if [[ -s "$PCAP" ]]; then
  TZ=UTC tcpdump -nn -tttt -r "$PCAP" \
    "((tcp[tcpflags] & (tcp-syn|tcp-ack)) == tcp-syn or udp) and not dst net $SUBNET" \
    2>/dev/null | label |
  awk '
    {
      time = $2
      src = $4; sub(/\.[0-9]+$/, "", src)
      dst = $6; sub(/:$/, "", dst)
      proto = ($0 ~ /Flags \[/) ? "tcp" : "udp"
      key = src " " dst "/" proto
      if (!(key in first)) { first[key] = time; order[++n] = key }
      count[key]++
    }
    END {
      if (n == 0) print "(no outbound attempts captured)"
      for (i = 1; i <= n; i++) {
        split(order[i], k, " ")
        printf "%s  %-22s -> %-30s x%d\n", substr(first[order[i]], 1, 8), k[1], k[2], count[order[i]]
      }
    }
  '
else
  echo "(no packet capture found at $PCAP)"
fi

echo
echo "== Firewall blocks, UTC (first seen, from, to, count) =="
if [[ -s "$KERNLOG" ]] && grep -q "EGRESS-BLOCK" "$KERNLOG"; then
  grep "EGRESS-BLOCK" "$KERNLOG" | label |
  awk '
    {
      time = substr($1, 12, 8)
      src = ""; dst = ""; dpt = ""; proto = ""
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^SRC=/) src = substr($i, 5)
        if ($i ~ /^DST=/) dst = substr($i, 5)
        if ($i ~ /^DPT=/) dpt = substr($i, 5)
        if ($i ~ /^PROTO=/) proto = tolower(substr($i, 7))
      }
      key = src " " dst "." dpt "/" proto
      if (!(key in first)) { first[key] = time; order[++n] = key }
      count[key]++
    }
    END {
      for (i = 1; i <= n; i++) {
        split(order[i], k, " ")
        printf "%s  %-22s -> %-30s x%d\n", first[order[i]], k[1], k[2], count[order[i]]
      }
    }
  '
else
  echo "(no firewall entries found in $KERNLOG)"
fi

echo
echo "== Coverage =="
if [[ -s "$DNSLOG" ]]; then
  echo "DNS log:        $(grep -c 'query\[' "$DNSLOG") lookups recorded"
else
  echo "DNS log:        MISSING. Lookups for this run are unrecorded."
fi

if [[ -s "$PCAP" ]]; then
  drops="unknown"
  if [[ -s "$TCPDUMP_OUT" ]]; then
    drops="$(grep -oE '[0-9]+ packets dropped by kernel' "$TCPDUMP_OUT" | grep -oE '^[0-9]+' || echo unknown)"
  fi
  echo "Packet capture: present. Packets dropped by kernel during capture: $drops"
else
  echo "Packet capture: MISSING. Packets on br-rag for this run are unrecorded."
fi

if [[ -s "$KERNLOG" ]] && grep -q "EGRESS-BLOCK" "$KERNLOG"; then
  echo "Firewall log:   $(grep -c 'EGRESS-BLOCK' "$KERNLOG") blocked packets logged"
  if grep -q "callbacks suppressed" "$KERNLOG"; then
    echo "                WARNING: the kernel rate-limited log messages during this run,"
    echo "                so the firewall log undercounts blocked packets."
  fi
elif [[ -s "$KERNLOG" ]]; then
  echo "Firewall log:   present but empty. Either nothing was blocked or firewall"
  echo "                logging was unavailable; check egress-deny.sh output for this run."
else
  echo "Firewall log:   MISSING. Firewall decisions for this run are unrecorded."
fi

cat <<'NOTE'

Outside all three records:
  - Traffic from the host itself (Docker daemon, Ubuntu services), which does
    not cross br-rag or the stack's DNS sinkhole.
  - Requests made by a browser viewing a component UI from another machine.
  - Payload contents. Destinations are visible; encrypted contents are not.
  - Behavior that only triggers outside this run's actions or time window.
NOTE
