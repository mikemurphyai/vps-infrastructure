#!/usr/bin/env bash
# cf-lockdown.sh — restrict Docker-published ports 80/443 on eth0 to Cloudflare IPs.
# Docker-published ports bypass ufw, so this hooks into the DOCKER-USER chain.
# Safe to re-run; refreshes Cloudflare ranges each time.
set -euo pipefail

RANGES=$(curl -fsS --max-time 15 https://www.cloudflare.com/ips-v4)
[ -n "$RANGES" ] || { echo "ERROR: failed to fetch Cloudflare ranges; keeping existing rules" >&2; exit 1; }

# (Re)build the allow-list chain
iptables -N CF-ONLY 2>/dev/null || true
iptables -F CF-ONLY
for net in $RANGES; do
  iptables -A CF-ONLY -s "$net" -j RETURN
done
iptables -A CF-ONLY -j DROP

# Hook new inbound 80/443 connections on eth0 into CF-ONLY (idempotent)
iptables -N DOCKER-USER 2>/dev/null || true
while iptables -D DOCKER-USER -i eth0 -p tcp -m multiport --dports 80,443 -m conntrack --ctstate NEW -j CF-ONLY 2>/dev/null; do :; done
iptables -I DOCKER-USER 1 -i eth0 -p tcp -m multiport --dports 80,443 -m conntrack --ctstate NEW -j CF-ONLY

echo "cf-lockdown applied: $(echo "$RANGES" | wc -l) Cloudflare ranges allowed on 80/443, all else dropped"
