#!/bin/sh

. /lib/functions.sh
. /lib/functions/network.sh
. /lib/mwan3/common.sh

# Default lowest metric sentinel
DEFAULT_LOWEST_METRIC=256

# ============================================================
# Route monitoring (unchanged from v2 — ip route based)
# ============================================================

mwan3_rtmon_ipv4()
{
	local idx=0 ret=1 tbl tid family enabled

	mkdir -p /tmp/mwan3rtmon
	($IP4 route list table main | grep -v "^default\|linkdown" | sort -n
	 echo "empty fixup") > /tmp/mwan3rtmon/ipv4.main

	while uci get mwan3.@interface[$idx] >/dev/null 2>&1; do
		tid=$((idx + 1))
		family=$(uci -q get mwan3.@interface[$idx].family)
		[ -z "$family" ] && family="ipv4"
		enabled=$(uci -q get mwan3.@interface[$idx].enabled)
		[ -z "$enabled" ] && enabled="0"

		[ "$family" = "ipv4" ] && {
			tbl=$($IP4 route list table $tid 2>/dev/null)
			if echo "$tbl" | grep -q "^default"; then
				(echo "$tbl" | grep -v "^default\|linkdown" | sort -n
				 echo "empty fixup") > /tmp/mwan3rtmon/ipv4.$tid
				grep -v -x -F -f /tmp/mwan3rtmon/ipv4.main \
					/tmp/mwan3rtmon/ipv4.$tid | while read line; do
					$IP4 route del table $tid $line 2>/dev/null
				done
				grep -v -x -F -f /tmp/mwan3rtmon/ipv4.$tid \
					/tmp/mwan3rtmon/ipv4.main | while read line; do
					$IP4 route add table $tid $line 2>/dev/null
				done
			fi
		}
		[ "$enabled" = "1" ] && ret=0
		idx=$((idx + 1))
	done
	rm -f /tmp/mwan3rtmon/ipv4.*
	return $ret
}

mwan3_rtmon_ipv6()
{
	[ $NO_IPV6 -ne 0 ] && return 1
	local idx=0 ret=1 tbl tid family enabled

	mkdir -p /tmp/mwan3rtmon
	($IP6 route list table main | \
		grep -v "^default\|^::/0\|^fe80::/64\|^unreachable" | sort -n
	 echo "empty fixup") > /tmp/mwan3rtmon/ipv6.main

	while uci get mwan3.@interface[$idx] >/dev/null 2>&1; do
		tid=$((idx + 1))
		family=$(uci -q get mwan3.@interface[$idx].family)
		[ -z "$family" ] && family="ipv4"
		enabled=$(uci -q get mwan3.@interface[$idx].enabled)
		[ -z "$enabled" ] && enabled="0"

		[ "$family" = "ipv6" ] && {
			tbl=$($IP6 route list table $tid 2>/dev/null)
			if echo "$tbl" | grep -q "^default\|^::/0"; then
				(echo "$tbl" | \
					grep -v "^default\|^::/0\|^unreachable" | sort -n
				 echo "empty fixup") > /tmp/mwan3rtmon/ipv6.$tid
				grep -v -x -F -f /tmp/mwan3rtmon/ipv6.main \
					/tmp/mwan3rtmon/ipv6.$tid | while read line; do
					$IP6 route del table $tid $line 2>/dev/null
				done
				grep -v -x -F -f /tmp/mwan3rtmon/ipv6.$tid \
					/tmp/mwan3rtmon/ipv6.main | while read line; do
					$IP6 route add table $tid $line 2>/dev/null
				done
			fi
		}
		[ "$enabled" = "1" ] && ret=0
		idx=$((idx + 1))
	done
	rm -f /tmp/mwan3rtmon/ipv6.*
	return $ret
}

# ============================================================
# Core utility functions
# ============================================================

mwan3_count_one_bits()
{
	local count n
	count=0
	n=$(($1))
	while [ "$n" -gt "0" ]; do
		n=$(( n & (n-1) ))
		count=$(( count + 1 ))
	done
	echo $count
}

mwan3_id2mask()
{
	# $1 = variable name containing id
	# $2 = variable name containing mask
	# Maps id bits into mask bit positions.
	local _id _mask bit_msk bit_val result
	eval "_id=\$((\$$1))"
	eval "_mask=\$((\$$2))"
	bit_val=0
	result=0
	for bit_msk in $(seq 0 31); do
		if [ $(( (_mask >> bit_msk) & 1 )) = "1" ]; then
			if [ $(( (_id >> bit_val) & 1 )) = "1" ]; then
				result=$(( result | (1 << bit_msk) ))
			fi
			bit_val=$(( bit_val + 1 ))
		fi
	done
	printf "0x%x" $result
}

mwan3_init()
{
	local bitcnt mmdefault

	config_load mwan3

	# Read MMX_MASK from UCI or use default
	if [ -e "${MWAN3_STATUS_DIR}/mmx_mask" ]; then
		MMX_MASK=$(cat "${MWAN3_STATUS_DIR}/mmx_mask")
	else
		config_get MMX_MASK globals mmx_mask '0x3F00'
		mkdir -p "$MWAN3_STATUS_DIR"
		echo "$MMX_MASK" > "${MWAN3_STATUS_DIR}/mmx_mask"
	fi

	# Compute interface max from mask bit count
	bitcnt=$(mwan3_count_one_bits $MMX_MASK)
	mmdefault=$(( (1 << bitcnt) - 1 ))
	MWAN3_INTERFACE_MAX=$(( mmdefault - 3 ))

	# Special marks using mwan3_id2mask (same bit-mapping as interface ids)
	MM_BLACKHOLE=$(( mmdefault - 2 ))
	MM_UNREACHABLE=$(( mmdefault - 1 ))

	MMX_DEFAULT=$(mwan3_id2mask mmdefault MMX_MASK)
	MMX_BLACKHOLE=$(mwan3_id2mask MM_BLACKHOLE MMX_MASK)
	MMX_UNREACHABLE=$(mwan3_id2mask MM_UNREACHABLE MMX_MASK)

	# Persist for hotplug scripts that don't call mwan3_init
	mkdir -p "$MWAN3_STATUS_DIR"
	echo "$MMX_MASK" > "${MWAN3_STATUS_DIR}/mmx_mask"
	echo "$MMX_DEFAULT" > "${MWAN3_STATUS_DIR}/mmx_default"
	echo "$MMX_UNREACHABLE" > "${MWAN3_STATUS_DIR}/mmx_unreachable"
	echo "$MMX_BLACKHOLE" > "${MWAN3_STATUS_DIR}/mmx_blackhole"
}

mwan3_lock()
{
	lock "/var/run/mwan3_${1}_${2}.lock"
}

mwan3_unlock()
{
	lock -u "/var/run/mwan3_${1}_${2}.lock"
}

# Helper for mwan3_get_iface_id — must be top-level for ash
_mwan3_count_iface() {
	_MWAN3_IFACE_COUNT=$((_MWAN3_IFACE_COUNT + 1))
	[ "$1" = "$_MWAN3_IFACE_TARGET" ] && _MWAN3_IFACE_RESULT=$_MWAN3_IFACE_COUNT
}

mwan3_get_iface_id()
{
	_MWAN3_IFACE_RESULT=0
	_MWAN3_IFACE_COUNT=0
	_MWAN3_IFACE_TARGET="$2"
	config_foreach _mwan3_count_iface interface
	eval "$1=$_MWAN3_IFACE_RESULT"
}

# ============================================================
# nft Set management — connected/custom/dynamic networks
# ============================================================

mwan3_set_custom_sets()
{
	mwan3_nft_batch_start

	# Flush and rebuild custom_v4 set
	mwan3_nft_push "flush set $MWAN3_NFT_TABLE mwan3_custom_v4"

	config_load mwan3
	config_list_foreach globals custom_network_v4 _add_custom_v4

	[ $NO_IPV6 -eq 0 ] && {
		mwan3_nft_push "flush set $MWAN3_NFT_TABLE mwan3_custom_v6"
		config_list_foreach globals custom_network_v6 _add_custom_v6
	}

	mwan3_nft_batch_commit
}

_add_custom_v4() {
	[ -n "$1" ] && \
		mwan3_nft_push "add element $MWAN3_NFT_TABLE mwan3_custom_v4 { $1 }"
}

_add_custom_v6() {
	[ -n "$1" ] && \
		mwan3_nft_push "add element $MWAN3_NFT_TABLE mwan3_custom_v6 { $1 }"
}

mwan3_set_connected_sets()
{
	local net routes

	# Collect connected IPv4 prefixes — awk avoids pipe subshell issue
	routes=$($IP4 route show table main 2>/dev/null | \
		awk '!/via/ && /[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+/{print $1}')

	mwan3_nft_batch_start
	mwan3_nft_push "flush set $MWAN3_NFT_TABLE mwan3_connected_v4"

	for net in $routes; do
		mwan3_nft_push "add element $MWAN3_NFT_TABLE mwan3_connected_v4 { $net }"
	done

	# Always include multicast and loopback
	mwan3_nft_push "add element $MWAN3_NFT_TABLE mwan3_connected_v4 { 224.0.0.0/3 }"
	mwan3_nft_push "add element $MWAN3_NFT_TABLE mwan3_connected_v4 { 127.0.0.0/8 }"

	mwan3_nft_batch_commit
}

# ============================================================
# General nft framework setup
# Called once on mwan3 start and after fw4 reload
# ============================================================

mwan3_set_general_nft()
{
	# Load marks from state if not set (hotplug context)
	[ -z "$MMX_MASK" ] && MMX_MASK=$(cat "${MWAN3_STATUS_DIR}/mmx_mask" 2>/dev/null)
	[ -z "$MMX_DEFAULT" ] && MMX_DEFAULT=$(cat "${MWAN3_STATUS_DIR}/mmx_default" 2>/dev/null)
	[ -z "$MMX_UNREACHABLE" ] && MMX_UNREACHABLE=$(cat "${MWAN3_STATUS_DIR}/mmx_unreachable" 2>/dev/null)

	mwan3_ensure_nft_framework

	mwan3_nft_batch_start

	# === mwan3_prerouting hook ===
	mwan3_nft_push "flush chain $MWAN3_NFT_TABLE $MWAN3_NFT_CHAIN_PRE"

	# IPv6 bypass — all IPv6 falls through to main routing table
	[ $NO_IPV6 -ne 0 ] && \
		mwan3_nft_push "add rule $MWAN3_NFT_TABLE $MWAN3_NFT_CHAIN_PRE meta nfproto ipv6 return"

	# Restore connmark for established flows
	mwan3_nft_push "add rule $MWAN3_NFT_TABLE $MWAN3_NFT_CHAIN_PRE ct mark != 0 meta mark set ct mark & $MMX_MASK"

	# New flows: classify via ifaces_in, connected, rules
	mwan3_nft_push "add rule $MWAN3_NFT_TABLE $MWAN3_NFT_CHAIN_PRE meta mark & $MMX_MASK == 0 jump mwan3_ifaces_in"
	mwan3_nft_push "add rule $MWAN3_NFT_TABLE $MWAN3_NFT_CHAIN_PRE meta mark & $MMX_MASK == 0 jump mwan3_connected"
	mwan3_nft_push "add rule $MWAN3_NFT_TABLE $MWAN3_NFT_CHAIN_PRE meta mark & $MMX_MASK == 0 jump mwan3_custom"
	mwan3_nft_push "add rule $MWAN3_NFT_TABLE $MWAN3_NFT_CHAIN_PRE meta mark & $MMX_MASK == 0 jump mwan3_dynamic"
	mwan3_nft_push "add rule $MWAN3_NFT_TABLE $MWAN3_NFT_CHAIN_PRE meta mark & $MMX_MASK == 0 jump mwan3_rules"

	# Save mark back to conntrack
	mwan3_nft_push "add rule $MWAN3_NFT_TABLE $MWAN3_NFT_CHAIN_PRE ct mark set meta mark & $MMX_MASK"

	# Re-check connected for marked packets (policy routing sanity)
	mwan3_nft_push "add rule $MWAN3_NFT_TABLE $MWAN3_NFT_CHAIN_PRE meta mark & $MMX_MASK != $MMX_DEFAULT jump mwan3_connected"

	# === mwan3_output hook ===
	mwan3_nft_push "flush chain $MWAN3_NFT_TABLE $MWAN3_NFT_CHAIN_OUT"

	# IPv6 bypass
	[ $NO_IPV6 -ne 0 ] && \
		mwan3_nft_push "add rule $MWAN3_NFT_TABLE $MWAN3_NFT_CHAIN_OUT meta nfproto ipv6 return"

	# track_hook: mark mwan3track pings BEFORE connmark restore
	# Matches ICMP echo-request size 28 bytes (ping -s 0 → 28 byte ICMP)
	# This replicates the old 1.5 era mwan3_track_hook behaviour
	# mwan3track sends ping -s 1 → ICMP payload 1 byte → IP total 29 bytes
	# We use ip length 29 to match specifically
	mwan3_nft_push "add rule $MWAN3_NFT_TABLE $MWAN3_NFT_CHAIN_OUT meta l4proto icmp icmp type echo-request jump mwan3_track_ifaces"

	# Restore connmark for established flows
	mwan3_nft_push "add rule $MWAN3_NFT_TABLE $MWAN3_NFT_CHAIN_OUT ct mark != 0 meta mark set ct mark & $MMX_MASK"

	# New flows: classify
	mwan3_nft_push "add rule $MWAN3_NFT_TABLE $MWAN3_NFT_CHAIN_OUT meta mark & $MMX_MASK == 0 jump mwan3_connected"
	mwan3_nft_push "add rule $MWAN3_NFT_TABLE $MWAN3_NFT_CHAIN_OUT meta mark & $MMX_MASK == 0 jump mwan3_custom"
	mwan3_nft_push "add rule $MWAN3_NFT_TABLE $MWAN3_NFT_CHAIN_OUT meta mark & $MMX_MASK == 0 jump mwan3_dynamic"
	mwan3_nft_push "add rule $MWAN3_NFT_TABLE $MWAN3_NFT_CHAIN_OUT meta mark & $MMX_MASK == 0 jump mwan3_rules"

	# Save mark
	mwan3_nft_push "add rule $MWAN3_NFT_TABLE $MWAN3_NFT_CHAIN_OUT ct mark set meta mark & $MMX_MASK"

	# Re-check connected
	mwan3_nft_push "add rule $MWAN3_NFT_TABLE $MWAN3_NFT_CHAIN_OUT meta mark & $MMX_MASK != $MMX_DEFAULT jump mwan3_connected"

	# === mwan3_connected chain ===
	mwan3_nft_push "flush chain $MWAN3_NFT_TABLE mwan3_connected"
	mwan3_nft_push "add rule $MWAN3_NFT_TABLE mwan3_connected ip daddr @mwan3_connected_v4 $(mwan3_nft_mark_expr $MMX_DEFAULT $MMX_MASK) return"

	# === mwan3_custom chain ===
	mwan3_nft_push "flush chain $MWAN3_NFT_TABLE mwan3_custom"
	mwan3_nft_push "add rule $MWAN3_NFT_TABLE mwan3_custom ip daddr @mwan3_custom_v4 $(mwan3_nft_mark_expr $MMX_DEFAULT $MMX_MASK) return"

	# === mwan3_dynamic chain ===
	mwan3_nft_push "flush chain $MWAN3_NFT_TABLE mwan3_dynamic"
	mwan3_nft_push "add rule $MWAN3_NFT_TABLE mwan3_dynamic ip daddr @mwan3_dynamic_v4 $(mwan3_nft_mark_expr $MMX_DEFAULT $MMX_MASK) return"

	mwan3_nft_batch_commit
}

# ============================================================
# Per-interface nft rules
# ============================================================

mwan3_create_iface_nft()
{
	local iface="$1" device family
	local iface_id mark

	network_get_device device "$iface"
	[ -z "$device" ] && return

	mwan3_get_iface_id iface_id "$iface"
	[ "$iface_id" -eq 0 ] && return

	mark=$(mwan3_id2mask iface_id MMX_MASK)

	mwan3_nft_batch_start

	# Create per-iface chain in mwan3_ifaces_in
	local chain="mwan3_iface_in_${iface}"
	mwan3_nft_chain_exists "$chain" || \
		mwan3_nft_push "add chain $MWAN3_NFT_TABLE $chain"
	mwan3_nft_push "flush chain $MWAN3_NFT_TABLE $chain"

	# Mark inbound traffic from this interface
	mwan3_nft_push "add rule $MWAN3_NFT_TABLE $chain iifname \"$device\" meta nfproto ipv4 ip saddr @mwan3_connected_v4 meta mark & $MMX_MASK == 0 $(mwan3_nft_mark_expr $MMX_DEFAULT $MMX_MASK)"
	mwan3_nft_push "add rule $MWAN3_NFT_TABLE $chain iifname \"$device\" meta nfproto ipv4 ip saddr @mwan3_custom_v4 meta mark & $MMX_MASK == 0 $(mwan3_nft_mark_expr $MMX_DEFAULT $MMX_MASK)"
	mwan3_nft_push "add rule $MWAN3_NFT_TABLE $chain iifname \"$device\" meta nfproto ipv4 ip saddr @mwan3_dynamic_v4 meta mark & $MMX_MASK == 0 $(mwan3_nft_mark_expr $MMX_DEFAULT $MMX_MASK)"
	mwan3_nft_push "add rule $MWAN3_NFT_TABLE $chain iifname \"$device\" meta mark & $MMX_MASK == 0 $(mwan3_nft_mark_expr $mark $MMX_MASK)"

	# Jump from ifaces_in to this chain
	# Remove existing jump first to avoid duplicates
	local handle
	handle=$($NFT -a list chain $MWAN3_NFT_TABLE mwan3_ifaces_in 2>/dev/null | \
		awk -v c="$chain" '$0 ~ "jump "c {print $NF}')
	[ -n "$handle" ] && \
		mwan3_nft_push "delete rule $MWAN3_NFT_TABLE mwan3_ifaces_in handle $handle"
	mwan3_nft_push "add rule $MWAN3_NFT_TABLE mwan3_ifaces_in iifname \"$device\" jump $chain"

	# Per-interface track chain for mwan3track ping marking (track_hook pattern)
	local track_chain="mwan3_track_${iface}"
	mwan3_nft_chain_exists "$track_chain" || \
		mwan3_nft_push "add chain $MWAN3_NFT_TABLE $track_chain"
	mwan3_nft_push "flush chain $MWAN3_NFT_TABLE $track_chain"

	mwan3_nft_batch_commit
}

mwan3_delete_iface_nft()
{
	local iface="$1" device
	local chain="mwan3_iface_in_${iface}"

	network_get_device device "$iface"

	mwan3_nft_batch_start

	# Remove jump from ifaces_in
	if [ -n "$device" ]; then
		local handle
		handle=$($NFT -a list chain $MWAN3_NFT_TABLE mwan3_ifaces_in \
			2>/dev/null | \
			awk -v c="$chain" '$0 ~ "jump "c {print $NF}')
		[ -n "$handle" ] && \
			mwan3_nft_push "delete rule $MWAN3_NFT_TABLE mwan3_ifaces_in handle $handle"
	fi

	# Flush and delete iface_in chain only
	# (track chain handled separately by mwan3_delete_track_iface_nft)
	mwan3_nft_chain_exists "$chain" && {
		mwan3_nft_push "flush chain $MWAN3_NFT_TABLE $chain"
		mwan3_nft_push "delete chain $MWAN3_NFT_TABLE $chain"
	}

	mwan3_nft_batch_commit
}

# Rebuild iface nft rules — called by mwan3-fw-rebuild.sh after fw4 reload
mwan3_rebuild_iface_nft()
{
	local iface="$1"
	local enabled
	config_get enabled "$iface" enabled 0
	[ "$enabled" -eq 1 ] || return

	# Only rebuild if interface is actually online
	local status
	mwan3_get_iface_hotplug_state status "$iface"
	[ "$status" = "online" ] || return

	mwan3_create_iface_nft "$iface"
	mwan3_update_track_iface_nft "$iface"
}

# ============================================================
# Track hook — mwan3track ping marking (1.5 era pattern restored)
# ============================================================

mwan3_update_track_iface_nft()
{
	local iface="$1"
	local track_chain="mwan3_track_${iface}"
	local device iface_id mark

	network_get_device device "$iface"
	[ -z "$device" ] && return

	mwan3_get_iface_id iface_id "$iface"
	[ "$iface_id" -eq 0 ] && return

	mark=$(mwan3_id2mask iface_id MMX_MASK)

	# Get track IPs for this interface — use tempfile to avoid subshell issue
	local track_ip_file="/tmp/mwan3_track_ips_${iface}.$$"
	rm -f "$track_ip_file"
	_collect_track_ip() { echo "$1" >> "$track_ip_file"; }
	config_list_foreach "$iface" track_ip _collect_track_ip

	[ -f "$track_ip_file" ] || return
	local track_ips
	track_ips=$(cat "$track_ip_file")
	rm -f "$track_ip_file"
	[ -z "$track_ips" ] && return

	mwan3_nft_batch_start

	# Ensure track chain exists
	mwan3_nft_chain_exists "$track_chain" || \
		mwan3_nft_push "add chain $MWAN3_NFT_TABLE $track_chain"
	mwan3_nft_push "flush chain $MWAN3_NFT_TABLE $track_chain"

	# For each track IP: match ICMP echo-request to that destination
	# → mark to go out this WAN
	for track_ip in $track_ips; do
		mwan3_nft_push "add rule $MWAN3_NFT_TABLE $track_chain ip daddr $track_ip $(mwan3_nft_mark_expr $mark $MMX_MASK)"
	done

	# Ensure jump from mwan3_track_ifaces → this track chain exists
	local handle
	handle=$($NFT -a list chain $MWAN3_NFT_TABLE mwan3_track_ifaces 2>/dev/null | \
		awk -v c="$track_chain" '$0 ~ "jump "c {print $NF}')
	[ -z "$handle" ] && \
		mwan3_nft_push "add rule $MWAN3_NFT_TABLE mwan3_track_ifaces jump $track_chain"

	mwan3_nft_batch_commit
}

mwan3_delete_track_iface_nft()
{
	local iface="$1"
	local track_chain="mwan3_track_${iface}"

	mwan3_nft_batch_start

	# Remove jump from mwan3_track_ifaces FIRST — must happen before
	# chain deletion or nft reports "Resource busy"
	local handle
	handle=$($NFT -a list chain $MWAN3_NFT_TABLE mwan3_track_ifaces \
		2>/dev/null | \
		awk -v c="$track_chain" '$0 ~ "jump "c" " || $0 ~ "jump "c"$" {print $NF}')
	[ -n "$handle" ] && \
		mwan3_nft_push "delete rule $MWAN3_NFT_TABLE mwan3_track_ifaces handle $handle"

	mwan3_nft_chain_exists "$track_chain" && {
		mwan3_nft_push "flush chain $MWAN3_NFT_TABLE $track_chain"
		mwan3_nft_push "delete chain $MWAN3_NFT_TABLE $track_chain"
	}

	mwan3_nft_batch_commit
}

# ============================================================
# ip rules and routes (unchanged from v2 — iproute2 based)
# ============================================================

mwan3_create_iface_route()
{
	local iface="$1" device gateway family iface_id
	local defaultroute table

	network_get_device device "$iface"
	config_get family "$iface" family ipv4

	mwan3_get_iface_id iface_id "$iface"
	table=$iface_id

	if [ "$family" = "ipv4" ]; then
		network_get_gateway gateway "$iface"
		$IP4 route flush table $table
		if [ -n "$gateway" ]; then
			$IP4 route add table $table default via "$gateway" dev "$device"
		else
			$IP4 route add table $table default dev "$device"
		fi
	fi
}

mwan3_delete_iface_route()
{
	local iface="$1" iface_id
	mwan3_get_iface_id iface_id "$iface"
	$IP4 route flush table $iface_id 2>/dev/null
}

mwan3_create_iface_rules()
{
	local iface="$1" iface_id family
	local pref_fwmark pref_iif

	config_get family "$iface" family ipv4
	mwan3_get_iface_id iface_id "$iface"

	local mark
	mark=$(mwan3_id2mask iface_id MMX_MASK)

	pref_iif=$((iface_id + 1000))
	pref_fwmark=$((iface_id + 2000))

	if [ "$family" = "ipv4" ]; then
		# Remove stale rules
		$IP4 rule del pref $pref_iif 2>/dev/null
		$IP4 rule del pref $pref_fwmark 2>/dev/null

		local device
		network_get_device device "$iface"
		[ -n "$device" ] && \
			$IP4 rule add pref $pref_iif iif "$device" lookup $iface_id
		$IP4 rule add pref $pref_fwmark fwmark $mark/$MMX_MASK lookup $iface_id
	fi

	# Default unreachable/blackhole rules (set once at id+500)
	$IP4 rule del pref 2254 2>/dev/null
	$IP4 rule del pref 2255 2>/dev/null
	$IP4 rule add pref 2254 fwmark $MMX_BLACKHOLE/$MMX_MASK unreachable 2>/dev/null
	$IP4 rule add pref 2255 fwmark $MMX_UNREACHABLE/$MMX_MASK unreachable 2>/dev/null
}

mwan3_delete_iface_rules()
{
	local iface="$1" iface_id
	mwan3_get_iface_id iface_id "$iface"

	local pref_iif=$((iface_id + 1000))
	local pref_fwmark=$((iface_id + 2000))
	local pref_recovery=$((iface_id + 1500))

	$IP4 rule del pref $pref_iif 2>/dev/null
	$IP4 rule del pref $pref_fwmark 2>/dev/null
	$IP4 rule del pref $pref_recovery 2>/dev/null
}

# ============================================================
# Recovery rule — src-IP based ip rule so mwan3track pings
# can reach their targets when interface is offline.
# Complemented by track_hook nft rules for when interface is online.
# ============================================================

mwan3_set_recovery_rule()
{
	local iface="$1" iface_id src_ip
	mwan3_get_iface_id iface_id "$iface"
	[ "$iface_id" -eq 0 ] && return

	local pref=$((iface_id + 1500))

	# Read SRC_IP written by mwan3track
	src_ip=$(cat "${MWAN3TRACK_STATUS_DIR}/${iface}/SRC_IP" 2>/dev/null)
	[ -z "$src_ip" ] || [ "$src_ip" = "0.0.0.0" ] && return

	$IP4 rule del pref $pref 2>/dev/null
	$IP4 rule add pref $pref from "$src_ip" lookup $iface_id
	LOG info "Recovery rule added: from $src_ip lookup $iface_id (pref $pref)"
}

mwan3_del_recovery_rule()
{
	local iface="$1" iface_id
	mwan3_get_iface_id iface_id "$iface"
	[ "$iface_id" -eq 0 ] && return

	local pref=$((iface_id + 1500))
	$IP4 rule del pref $pref 2>/dev/null
}

# ============================================================
# Conntrack flush — selective per-interface mark (our v2 fix)
# ============================================================

CONNTRACK_FILE="/proc/net/nf_conntrack"

mwan3_flush_conntrack()
{
	local iface="$1"
	local action="$2"

	handle_flush()
	{
		local flush_conntrack="$1"
		local action="$2"

		[ "$action" = "$flush_conntrack" ] || return

		# Selective flush: only flows marked for this interface
		local iface_id mark
		mwan3_get_iface_id iface_id "$MWAN3_FLUSH_IFACE"
		if [ "$iface_id" -gt 0 ] && command -v conntrack >/dev/null 2>&1; then
			[ -z "$MMX_MASK" ] && \
				MMX_MASK=$(cat "${MWAN3_STATUS_DIR}/mmx_mask" 2>/dev/null)
			mark=$(mwan3_id2mask iface_id MMX_MASK)
			conntrack -D -m "$mark" 2>/dev/null && \
				LOG info "Selective conntrack flush: mark $mark for $MWAN3_FLUSH_IFACE on $action" || \
				LOG warn "conntrack flush failed for $MWAN3_FLUSH_IFACE"
		elif [ -e "$CONNTRACK_FILE" ]; then
			echo f > "$CONNTRACK_FILE"
			LOG info "Full conntrack flush for $MWAN3_FLUSH_IFACE on $action"
		fi
	}

	MWAN3_FLUSH_IFACE="$iface"
	config_list_foreach "$iface" flush_conntrack handle_flush "$action"
}

# ============================================================
# WireGuard re-handshake on WAN failover
# ============================================================

mwan3_wg_rehandshake()
{
	local wg_iface peers
	for wg_iface in $(wg show interfaces 2>/dev/null); do
		for peer in $(wg show "$wg_iface" peers 2>/dev/null); do
			local endpoint
			endpoint=$(wg show "$wg_iface" endpoints 2>/dev/null | \
				awk -v p="$peer" '$1==p {print $2}')
			[ -n "$endpoint" ] && \
				wg set "$wg_iface" peer "$peer" endpoint "$endpoint" 2>/dev/null
		done
	done
}

# ============================================================
# Policy chains — nft with numgen load balancing
# ============================================================

# Tempfile for policy member collection (avoids subshell issue)
MWAN3_POLICY_FILE=""

# Accumulator variables for mwan3_set_policy (called per member)
policy_members=""

mwan3_set_policy()
{
	local member="$1" policy="$2"
	local iface metric weight enabled family iface_id

	config_get iface "$member" interface
	config_get metric "$member" metric 1
	config_get weight "$member" weight 1
	config_get enabled "$member" enabled 1
	[ "$enabled" -eq 1 ] || return

	[ -z "$iface" ] && return

	mwan3_get_iface_id iface_id "$iface"
	[ "$iface_id" -eq 0 ] && return

	# Check if interface is online
	local status
	mwan3_get_iface_hotplug_state status "$iface"
	[ "$status" = "online" ] || return

	# Write to tempfile (avoid subshell variable propagation issue)
	echo "$iface:$iface_id:$weight:$metric" >> "$MWAN3_POLICY_FILE"
}

mwan3_set_policies_nft()
{
	config_foreach _build_policy_chain policy
}

_build_policy_chain()
{
	local policy="$1"
	local last_resort lowest_metric
	local has_online=0

	config_get last_resort "$policy" last_resort unreachable

	# Check chain name length (nft limit)
	local chain="mwan3_policy_${policy}"
	if [ "${#chain}" -gt 31 ]; then
		LOG warn "Policy name $policy too long (chain $chain > 31 chars)"
		return
	fi

	# Create/flush policy chain
	mwan3_nft_chain_exists "$chain" || \
		mwan3_nft_exec add chain $MWAN3_NFT_TABLE "$chain"
	mwan3_nft_exec flush chain $MWAN3_NFT_TABLE "$chain"

	# Collect online members via tempfile (config_list_foreach subshell issue)
	local policy_file="/tmp/mwan3_policy_${policy}.$$"
	rm -f "$policy_file"
	MWAN3_POLICY_FILE="$policy_file"
	config_list_foreach "$policy" use_member mwan3_set_policy "$policy"
	policy_members=""
	[ -f "$policy_file" ] && policy_members=$(cat "$policy_file") && \
		rm -f "$policy_file"

	# Find lowest metric among online members
	lowest_metric=$DEFAULT_LOWEST_METRIC
	for m in $policy_members; do
		local metric="${m##*:}"
		[ "$metric" -lt "$lowest_metric" ] && lowest_metric=$metric
	done

	# Filter to lowest metric only
	local active_members=""
	local total_weight=0
	for m in $policy_members; do
		local metric="${m##*:}"
		[ "$metric" -eq "$lowest_metric" ] || continue
		active_members="$active_members $m"
		local weight
		weight=$(echo "$m" | cut -d: -f3)
		total_weight=$((total_weight + weight))
		has_online=1
	done

	mwan3_nft_batch_start

	if [ "$has_online" -eq 0 ] || [ "$total_weight" -eq 0 ]; then
		# No online members — apply last_resort
		case "$last_resort" in
			blackhole)
				mwan3_nft_push "add rule $MWAN3_NFT_TABLE $chain $(mwan3_nft_mark_expr $MMX_BLACKHOLE $MMX_MASK)"
				;;
			default)
				mwan3_nft_push "add rule $MWAN3_NFT_TABLE $chain $(mwan3_nft_mark_expr $MMX_DEFAULT $MMX_MASK)"
				;;
			unreachable|*)
				mwan3_nft_push "add rule $MWAN3_NFT_TABLE $chain $(mwan3_nft_mark_expr $MMX_UNREACHABLE $MMX_MASK)"
				;;
		esac
	elif [ "$(echo $active_members | wc -w)" -eq 1 ]; then
		# Single member — direct mark
		local m="$active_members"
		local iface_id
		iface_id=$(echo "$m" | cut -d: -f2)
		local mark
		mark=$(mwan3_id2mask iface_id MMX_MASK)
		mwan3_nft_push "add rule $MWAN3_NFT_TABLE $chain meta mark & $MMX_MASK == 0 $(mwan3_nft_mark_expr $mark $MMX_MASK)"
	else
		# Multiple members — numgen weighted random
		# nft vmap only accepts verdicts (jump/goto) not statements
		# Use separate rules with numgen range comparisons instead
		local running=0
		local m iface_id weight mark end
		for m in $active_members; do
			iface_id=$(echo "$m" | cut -d: -f2)
			weight=$(echo "$m" | cut -d: -f3)
			mark=$(mwan3_id2mask iface_id MMX_MASK)
			end=$((running + weight - 1))
			if [ $running -eq 0 ]; then
				# First range: numgen < weight
				mwan3_nft_push "add rule $MWAN3_NFT_TABLE $chain meta mark & $MMX_MASK == 0 numgen random mod $total_weight < $weight $(mwan3_nft_mark_expr $mark $MMX_MASK)"
			else
				# Subsequent ranges: numgen >= start
				# Previous rule already handled lower range so >= is sufficient
				mwan3_nft_push "add rule $MWAN3_NFT_TABLE $chain meta mark & $MMX_MASK == 0 numgen random mod $total_weight >= $running $(mwan3_nft_mark_expr $mark $MMX_MASK)"
			fi
			running=$((running + weight))
		done
	fi

	mwan3_nft_batch_commit
}

# ============================================================
# User rules (mwan3 config rules → nft rules in mwan3_rules)
# ============================================================

mwan3_set_user_rules()
{
	mwan3_nft_exec flush chain $MWAN3_NFT_TABLE mwan3_rules
	config_foreach mwan3_set_user_nft_rule rule
}

mwan3_set_user_nft_rule()
{
	local rule="$1"
	local proto src_ip src_port src_iface src_dev
	local dest_ip dest_port use_policy family sticky timeout
	local ipset policy_chain

	config_get sticky "$rule" sticky 0
	config_get timeout "$rule" timeout 600
	config_get ipset "$rule" ipset
	config_get proto "$rule" proto all
	config_get src_ip "$rule" src_ip
	config_get src_iface "$rule" src_iface
	network_get_device src_dev "$src_iface"
	config_get src_port "$rule" src_port
	config_get dest_ip "$rule" dest_ip
	config_get dest_port "$rule" dest_port
	config_get use_policy "$rule" use_policy
	config_get family "$rule" family any

	[ -z "$use_policy" ] && return

	# Build nft match expression
	local match=""

	# IPv6 family filter
	[ "$family" = "ipv4" ] && match="$match meta nfproto ipv4"
	[ "$family" = "ipv6" ] && match="$match meta nfproto ipv6"

	# Protocol — nft uses l4proto for matching, but tcp/udp keywords
	# work directly for port matching
	local proto_match=""
	case "$proto" in
		all) ;;
		tcp|udp)
			proto_match="$proto"
			match="$match meta l4proto $proto"
			;;
		icmp)
			match="$match ip protocol icmp"
			proto_match="icmp"
			;;
		*)
			match="$match ip protocol $proto"
			proto_match="$proto"
			;;
	esac

	# Source
	[ -n "$src_ip" ] && match="$match ip saddr $src_ip"
	[ -n "$src_dev" ] && match="$match iifname \"$src_dev\""
	if [ -n "$src_port" ] && [ -n "$proto_match" ] && \
	   [ "$proto_match" = "tcp" -o "$proto_match" = "udp" ]; then
		# Normalize port list: "80,443" → "{ 80, 443 }"
		local port_list
		port_list=$(echo "$src_port" | sed 's/,/, /g')
		match="$match $proto_match sport { $port_list }"
	fi

	# Destination
	[ -n "$dest_ip" ] && match="$match ip daddr $dest_ip"
	if [ -n "$dest_port" ] && [ -n "$proto_match" ] && \
	   [ "$proto_match" = "tcp" -o "$proto_match" = "udp" ]; then
		local port_list
		port_list=$(echo "$dest_port" | sed 's/,/, /g')
		match="$match $proto_match dport { $port_list }"
	fi

	# nftset match (replaces ipset)
	[ -n "$ipset" ] && match="$match ip daddr @${ipset}"

	# Mark must be unset
	match="$match meta mark & $MMX_MASK == 0"

	# Determine policy
	case "$use_policy" in
		default)
			policy_chain="$(mwan3_nft_mark_expr $MMX_DEFAULT $MMX_MASK)"
			;;
		unreachable)
			policy_chain="$(mwan3_nft_mark_expr $MMX_UNREACHABLE $MMX_MASK)"
			;;
		blackhole)
			policy_chain="$(mwan3_nft_mark_expr $MMX_BLACKHOLE $MMX_MASK)"
			;;
		*)
			policy_chain="jump mwan3_policy_${use_policy}"
			;;
	esac

	mwan3_nft_exec add rule $MWAN3_NFT_TABLE mwan3_rules \
		$match $policy_chain
}

# ============================================================
# Sticky sessions — nft timeout sets
# ============================================================

mwan3_create_sticky_set()
{
	local rule="$1" timeout="${2:-600}"

	local set_v4="mwan3_sticky_v4_${rule}"

	mwan3_nft_set_exists "$set_v4" || \
		mwan3_nft_exec add set $MWAN3_NFT_TABLE "$set_v4" \
			"{ type ipv4_addr . mark; flags timeout,dynamic; timeout ${timeout}s; }"
}

# ============================================================
# Status/reporting
# ============================================================

mwan3_get_iface_hotplug_state()
{
	local _state
	readfile _state "${MWAN3_STATUS_DIR}/$2/STATUS"
	eval "$1=${_state:-offline}"
}

mwan3_set_iface_hotplug_state()
{
	mkdir -p "${MWAN3_STATUS_DIR}/$1"
	echo "$2" > "${MWAN3_STATUS_DIR}/$1/STATUS"
}

mwan3_report_iface_status()
{
	local iface="$1" status device iface_id
	mwan3_get_iface_hotplug_state status "$iface"
	network_get_device device "$iface"
	mwan3_get_iface_id iface_id "$iface"

	echo "Interface $iface ($device) [id: $iface_id] is $status"
}

mwan3_report_policies()
{
	config_foreach _report_policy policy
}

_report_policy()
{
	local policy="$1"
	local chain="mwan3_policy_${policy}"
	echo "Policy $policy:"
	$NFT list chain $MWAN3_NFT_TABLE "$chain" 2>/dev/null || \
		echo "  (not loaded)"
}

mwan3_report_connected_v4()
{
	$NFT list set $MWAN3_NFT_TABLE mwan3_connected_v4 2>/dev/null | \
		awk '/elements/{p=1} p && /[0-9]+\.[0-9]/{print}' | \
		tr ',' '\n' | tr -d '{}' | awk '{print "  "$1}'
}

mwan3_report_policies_v4()
{
	config_foreach _report_policy_v4 policy
}

_report_member_status()
{
	local member="$1" policy="$2"
	local iface weight metric status
	config_get iface "$member" interface
	config_get weight "$member" weight 1
	config_get metric "$member" metric 1
	[ -z "$iface" ] && return
	mwan3_get_iface_hotplug_state status "$iface"
	[ "$status" = "online" ] && \
		echo "$iface:$weight:$metric" >> "/tmp/mwan3_report_${policy}.$$"
}

_report_offline_member()
{
	local member="$1"
	local iface weight metric status
	config_get iface "$member" interface
	config_get weight "$member" weight 1
	config_get metric "$member" metric 1
	[ -z "$iface" ] && return
	mwan3_get_iface_hotplug_state status "$iface"
	[ "$status" = "online" ] || \
		printf "  %-20s offline (metric:%s)\n" "$iface" "$metric"
}

_report_policy_v4()
{
	local policy="$1"
	local last_resort

	config_get last_resort "$policy" last_resort unreachable

	echo "$policy:"

	# Collect online members via tempfile
	local members_file="/tmp/mwan3_report_${policy}.$$"
	rm -f "$members_file"
	config_list_foreach "$policy" use_member _report_member_status "$policy"

	if [ ! -f "$members_file" ]; then
		echo "  $last_resort"
		echo ""
		return
	fi

	# Find lowest metric
	local lowest=256 m metric
	while IFS= read -r m; do
		metric="${m##*:}"
		[ "$metric" -lt "$lowest" ] && lowest=$metric
	done < "$members_file"

	# Total weight at lowest metric
	local total_weight=0 weight
	while IFS= read -r m; do
		metric="${m##*:}"; weight=$(echo "$m" | cut -d: -f2)
		[ "$metric" -eq "$lowest" ] && total_weight=$((total_weight + weight))
	done < "$members_file"

	# Print active members with percentage
	local iface pct
	while IFS= read -r m; do
		iface=$(echo "$m" | cut -d: -f1)
		weight=$(echo "$m" | cut -d: -f2)
		metric="${m##*:}"
		if [ "$metric" -eq "$lowest" ] && [ "$total_weight" -gt 0 ]; then
			pct=$(( weight * 100 / total_weight ))
			printf "  %-20s %d%%\n" "$iface" "$pct"
		fi
	done < "$members_file"
	rm -f "$members_file"

	# Show offline members
	config_list_foreach "$policy" use_member _report_offline_member

	echo ""
}

mwan3_report_policies_v6()
{
	[ $NO_IPV6 -eq 0 ] && mwan3_report_policies_v4
}

mwan3_report_connected_v6()
{
	[ $NO_IPV6 -eq 0 ] && \
		$NFT list set $MWAN3_NFT_TABLE mwan3_connected_v6 2>/dev/null | \
		awk '/elements/{p=1} p && /[0-9a-f:]+/{print}' | \
		tr ',' '\n' | tr -d '{}' | awk '{print "  "$1}'
}

mwan3_report_rules_v4()
{
	config_foreach _report_rule_v4 rule
}

_report_rule_v4()
{
	local rule="$1"
	local proto src_ip src_port dest_ip dest_port use_policy family
	local ipset sticky

	config_get proto "$rule" proto all
	config_get src_ip "$rule" src_ip
	config_get src_port "$rule" src_port
	config_get dest_ip "$rule" dest_ip
	config_get dest_port "$rule" dest_port
	config_get use_policy "$rule" use_policy
	config_get family "$rule" family any
	config_get ipset "$rule" ipset
	config_get sticky "$rule" sticky 0

	[ -z "$use_policy" ] && return

	local desc=""
	[ "$family" != "any" ] && desc="${family} "
	[ "$proto" != "all" ] && desc="${desc}${proto} "
	[ -n "$src_ip" ] && desc="${desc}src:${src_ip} "
	[ -n "$src_port" ] && desc="${desc}sport:${src_port} "
	[ -n "$dest_ip" ] && desc="${desc}dst:${dest_ip} "
	[ -n "$dest_port" ] && desc="${desc}dport:${dest_port} "
	[ -n "$ipset" ] && desc="${desc}set:${ipset} "
	[ "$sticky" = "1" ] && desc="${desc}[sticky] "

	[ -z "$desc" ] && desc="all traffic "

	printf "  %-30s → %s\n" "${desc% }" "$use_policy"
}

mwan3_report_rules_v6()
{
	[ $NO_IPV6 -eq 0 ] && mwan3_report_rules_v4
}

mwan3_track_clean()
{
	rm -rf "${MWAN3_STATUS_DIR:?}/${1}" 2>/dev/null
	rmdir --ignore-fail-on-non-empty "$MWAN3_STATUS_DIR" 2>/dev/null
}

# ============================================================
# mwan3track interface
# ============================================================

mwan3_track()
{
	local iface="$1" device
	local reliability count timeout interval down up track_ips src_ip

	network_get_device device "$iface"
	[ -z "$device" ] && return

	config_get reliability "$iface" reliability 1
	config_get count "$iface" count 1
	config_get timeout "$iface" timeout 4
	config_get interval "$iface" interval 10
	config_get down "$iface" down 5
	config_get up "$iface" up 5

	# Collect track IPs via tempfile (config_list_foreach runs in subshell)
	local track_ip_file="/tmp/mwan3_track_ips_${iface}.$$"
	rm -f "$track_ip_file"
	_collect_ip() { echo "$1" >> "$track_ip_file"; }
	config_list_foreach "$iface" track_ip _collect_ip
	local track_ips=""
	[ -f "$track_ip_file" ] && track_ips=$(cat "$track_ip_file") && \
		rm -f "$track_ip_file"

	[ -z "$track_ips" ] && return

	mwan3_get_src_ip src_ip "$iface"

	mkdir -p "${MWAN3TRACK_STATUS_DIR}/${iface}"
	echo "$src_ip" > "${MWAN3TRACK_STATUS_DIR}/${iface}/SRC_IP"

	# Determine initial STATUS from hotplug state
	local status
	mwan3_get_iface_hotplug_state status "$iface"
	[ -z "$status" ] && status="online"

	# Update track_hook nft rules for this interface
	mwan3_update_track_iface_nft "$iface"

	[ -x /usr/sbin/mwan3track ] && \
		/usr/sbin/mwan3track "$iface" "$device" "$status" "$src_ip" \
			$track_ips &
}

mwan3_track_signal()
{
	local iface="$1"
	kill -USR1 $(cat "${MWAN3TRACK_STATUS_DIR}/${iface}/PID" 2>/dev/null) \
		2>/dev/null
}

# ============================================================
# rtmon
# ============================================================

mwan3_rtmon()
{
	local iface="$1"
	mwan3_rtmon_ipv4 || mwan3_rtmon_ipv6
}

