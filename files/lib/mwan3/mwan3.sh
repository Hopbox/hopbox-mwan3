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
	local tid line device

	$IP4 route list table main | while read -r line; do
		device=$(echo "$line" | awk '{
			for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)
		}')
		[ -n "$device" ] && echo "$line"
	done

	$IP4 monitor route | while read -r line; do
		case "$line" in
			*"table main"*)
				device=$(echo "$line" | awk '{
					for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)
				}')
				[ -n "$device" ] && kill -USR1 $$
			;;
		esac
	done
}

mwan3_rtmon_ipv6()
{
	[ $NO_IPV6 -ne 0 ] && return 1
	return 0
}

# ============================================================
# Core utility functions
# ============================================================

mwan3_count_one_bits()
{
	local bits mask="$1"
	bits=0
	while [ "$mask" -gt 0 ]; do
		bits=$((bits + (mask & 1)))
		mask=$((mask >> 1))
	done
	echo "$bits"
}

mwan3_id2mask()
{
	# Convert iface id to fwmark value given MMX_MASK
	# id starts at 1, mark = id << shift_bits
	local _id _mask shift
	eval "_id=\$$1"
	eval "_mask=\$$2"

	shift=$(mwan3_count_one_bits $(( (~_mask) & 0xFFFFFFFF )))
	echo $(( _id << shift ))
}

mwan3_init()
{
	local bitcount iface_max
	config_load mwan3

	config_get iface_max globals iface_max 250
	[ "$iface_max" -gt 250 ] && iface_max=250
	MWAN3_INTERFACE_MAX="$iface_max"

	bitcount=$(mwan3_count_one_bits $iface_max)
	bitcount=$((bitcount + 1))

	# Build MMX_MASK from interface count
	local mask=0 i=0
	while [ $i -lt $bitcount ]; do
		mask=$(( (mask << 1) | 1 ))
		i=$((i + 1))
	done
	mask=$(( mask << (16 - bitcount) ))
	MMX_MASK=$(printf "0x%08x" $mask)

	MMX_DEFAULT=$(printf "0x%08x" $mask)
	MM_BLACKHOLE=253
	MMX_BLACKHOLE=$(printf "0x%08x" $((MM_BLACKHOLE << (16 - bitcount))))
	MM_UNREACHABLE=254
	MMX_UNREACHABLE=$(printf "0x%08x" $((MM_UNREACHABLE << (16 - bitcount))))

	# Persist mask for hotplug scripts that don't call mwan3_init
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
	local track_chain="mwan3_track_${iface}"

	network_get_device device "$iface"

	mwan3_nft_batch_start

	# Remove jump from ifaces_in by flushing only our specific rule
	# Simpler: find handle by chain name (more reliable than device+chain match)
	if [ -n "$device" ]; then
		local handle
		handle=$($NFT -a list chain $MWAN3_NFT_TABLE mwan3_ifaces_in \
			2>/dev/null | \
			awk -v c="$chain" '$0 ~ "jump "c {print $NF}')
		[ -n "$handle" ] && \
			mwan3_nft_push "delete rule $MWAN3_NFT_TABLE mwan3_ifaces_in handle $handle"
	fi

	# Flush and delete chains
	mwan3_nft_chain_exists "$chain" && {
		mwan3_nft_push "flush chain $MWAN3_NFT_TABLE $chain"
		mwan3_nft_push "delete chain $MWAN3_NFT_TABLE $chain"
	}
	mwan3_nft_chain_exists "$track_chain" && {
		mwan3_nft_push "flush chain $MWAN3_NFT_TABLE $track_chain"
		mwan3_nft_push "delete chain $MWAN3_NFT_TABLE $track_chain"
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

	# Remove jump from mwan3_track_ifaces
	local handle
	handle=$($NFT -a list chain $MWAN3_NFT_TABLE mwan3_track_ifaces 2>/dev/null | \
		awk "/$track_chain/"'{print $NF}')
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
		local running=0
		local map_entries=""
		for m in $active_members; do
			local iface_id weight mark end
			iface_id=$(echo "$m" | cut -d: -f2)
			weight=$(echo "$m" | cut -d: -f3)
			mark=$(mwan3_id2mask iface_id MMX_MASK)
			end=$((running + weight - 1))
			[ -n "$map_entries" ] && map_entries="${map_entries}, "
			map_entries="${map_entries}${running}-${end} : $(mwan3_nft_mark_expr $mark $MMX_MASK)"
			running=$((running + weight))
		done
		mwan3_nft_push "add rule $MWAN3_NFT_TABLE $chain meta mark & $MMX_MASK == 0 numgen random mod $total_weight vmap { $map_entries }"
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

_report_policy_v4()
{
	local policy="$1"
	local chain="mwan3_policy_${policy}"
	echo "  Policy $policy:"
	$NFT list chain $MWAN3_NFT_TABLE "$chain" 2>/dev/null | \
		grep -v "^table\|^chain\|^}" | sed 's/^/    /'
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
	$NFT list chain $MWAN3_NFT_TABLE mwan3_rules 2>/dev/null | \
		grep -v "^table\|^chain\|^}" | sed 's/^/  /'
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

	# Update track_hook nft rules for this interface
	mwan3_update_track_iface_nft "$iface"

	[ -x /usr/sbin/mwan3track ] && \
		/usr/sbin/mwan3track "$iface" "$device" "$src_ip" \
			"$reliability" "$count" "$timeout" "$interval" \
			"$down" "$up" $track_ips &
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

