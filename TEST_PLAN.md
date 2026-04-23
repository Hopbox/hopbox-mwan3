# hopbox-mwan3 v3 nft — Device Test Plan

## Pre-test setup

```bash
# On device: backup current config
cp /etc/config/mwan3 /etc/config/mwan3.bak

# Install v3 package (after building)
opkg install hopbox-mwan3_3.0.0-1_all.ipk

# OR for quick testing, copy files directly:
scp files/lib/mwan3/* root@device:/lib/mwan3/
scp files/etc/hotplug.d/iface/15-mwan3 root@device:/etc/hotplug.d/iface/
scp files/etc/hotplug.d/iface/16-mwan3 root@device:/etc/hotplug.d/iface/
scp files/usr/sbin/mwan3* root@device:/usr/sbin/
scp files/usr/share/nftables.d/table-post/10-mwan3.nft \
    root@device:/usr/share/nftables.d/table-post/

# Register fw4 include (run once)
sh files/etc/uci-defaults/mwan3-firewall-include
fw4 reload
```

## Test 1: Basic start/stop

```bash
mwan3 stop
# Verify: no mwan3 chains in nft
nft list table inet fw4 2>/dev/null | grep mwan3
# Expected: no output (or only empty skeleton chains)

mwan3 start
# Verify: chains and rules present
nft list table inet fw4 | grep -c "mwan3"
# Expected: > 10

# Verify prerouting hook exists
nft list chain inet fw4 mwan3_prerouting
# Expected: rules with ct mark, meta mark, jump mwan3_rules etc.

# Verify sets populated
nft list set inet fw4 mwan3_connected_v4
# Expected: elements with your LAN subnets, 224.0.0.0/3, 127.0.0.0/8
```

## Test 2: Policy chains

```bash
# Verify policy chains built
nft list chain inet fw4 mwan3_policy_balanced 2>/dev/null
# Expected: numgen random rule for LB, or direct mark for single WAN

# Check all configured policies have chains
for policy in $(uci show mwan3 | awk -F'[.=]' '/\.type=policy/{print $2}'); do
  nft list chain inet fw4 "mwan3_policy_${policy}" 2>/dev/null && \
    echo "OK: $policy" || echo "MISSING: $policy"
done
```

## Test 3: Per-interface chains

```bash
# After ifup wana
nft list chain inet fw4 mwan3_iface_in_wana
# Expected: iifname rules marking inbound traffic

# Track chain
nft list chain inet fw4 mwan3_track_wana
# Expected: ip daddr <track_ip> mark rules
```

## Test 4: mwan3track pings go out correct WAN

```bash
# Watch OUTPUT chain marks during mwan3track ping
# On device with tcpdump:
tcpdump -i wana_dev -n icmp &

# Trigger mwan3track ping manually
ping -c1 -I wana_dev <wana_track_ip>
# Expected: captured on wana_dev

# Verify track_hook is working
nft list chain inet fw4 mwan3_track_ifaces
# Expected: jump rules to mwan3_track_wana, mwan3_track_wanb etc.
```

## Test 5: Failover

```bash
# Simulate WAN failure
ip link set wana_dev down

# Wait for mwan3track to detect (check_interval seconds)
sleep 15

# Verify:
# 1. Interface marked offline
cat /var/run/mwan3/wana/STATUS
# Expected: offline

# 2. Recovery rule added
ip rule show | grep "pref 1001\|from.*lookup 1"
# Expected: from <wana_src_ip> lookup 1

# 3. Policy chain updated (wana removed from pool)
nft list chain inet fw4 mwan3_policy_balanced
# Expected: only wanb mark, no numgen (single member)

# 4. Conntrack flushed for wana mark
# (entries with wana mark should be gone)
conntrack -L 2>/dev/null | grep "mark=0x100" | wc -l
# Expected: 0

# Restore
ip link set wana_dev up
sleep 15
cat /var/run/mwan3/wana/STATUS
# Expected: online
```

## Test 6: fw4 reload rebuilds rules

```bash
# Note current rule count
before=$(nft list table inet fw4 | grep -c "mwan3")

# Reload fw4
fw4 reload

# Wait for rebuild script
sleep 3

# Verify rules rebuilt
after=$(nft list table inet fw4 | grep -c "mwan3")
echo "Before: $before, After: $after"
# Expected: similar counts (may differ slightly due to ordering)

# Verify prerouting still has rules
nft list chain inet fw4 mwan3_prerouting | grep -c "meta mark"
# Expected: > 3
```

## Test 7: User rules with nftset

```bash
# Add a test rule using nftset
uci set mwan3.test_rule=rule
uci set mwan3.test_rule.ipset=direct
uci set mwan3.test_rule.use_policy=default
uci commit mwan3
mwan3 restart

# Verify rule appears in mwan3_rules chain
nft list chain inet fw4 mwan3_rules | grep "@direct"
# Expected: ip daddr @direct ... meta mark set ...

# Add test domain to nftset via dnsmasq
echo "nftset=/test.example.com/4#inet#fw4#direct" >> /etc/dnsmasq.conf
# After DNS query: nft list set inet fw4 direct
# Expected: test.example.com's IPs
```

## Test 8: dnsmasq nftset integration

```bash
# Verify dnsmasq nftset format works
# Edit /etc/config/mwan3 to add a rule with ipset option
# Add to dnsmasq: nftset=/autodesk.com/4#inet#fw4#autodesk_direct

# Trigger DNS query
nslookup autodesk.com

# Verify set populated
nft list set inet fw4 autodesk_direct
# Expected: IP addresses of autodesk.com
```

## Test 9: OpenVPN --float auto-rerouting

```bash
# Verify OpenVPN config has --float
grep float /etc/openvpn/*.conf
# Expected: --float present

# With both WANs up and OpenVPN tunnel active:
ip route show table main | grep tun
# Note tunnel state

# Simulate WAN failover (bring down active WAN)
ip link set wana_dev down
sleep 20

# Verify tunnel still up on wanb (no restart needed)
ip route show table main | grep tun
ping -c3 <openvpn_server_internal_ip>
# Expected: tunnel alive, pings succeed via wanb
```

## Test 10: WireGuard re-handshake

```bash
# If WireGuard is configured:
wg show
# Note latest handshake times

# Failover wana
ip link set wana_dev down
sleep 5

# Check WireGuard handshake was triggered
wg show
# Expected: recent handshake time (within last 10s)
```

## Known issues to watch for in logs

```bash
logread | grep mwan3 | tail -50

# Look for:
# "nft batch commit failed" → batch syntax error
# "nft ... : Error" → individual command failure  
# "config_foreach" issues → subshell propagation
# "mwan3_get_iface_id: result=0" → interface not found in config
```
