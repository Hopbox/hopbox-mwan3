#!/bin/sh

IP4="ip -4"
IP6="ip -6"
SCRIPTNAME="$(basename "$0")"

MWAN3_STATUS_DIR="/var/run/mwan3"
MWAN3TRACK_STATUS_DIR="/var/run/mwan3track"

MWAN3_INTERFACE_MAX=""

MMX_MASK=""
MMX_DEFAULT=""
MMX_BLACKHOLE=""
MM_BLACKHOLE=""

MMX_UNREACHABLE=""
MM_UNREACHABLE=""
MAX_SLEEP=$(((1<<31)-1))

# nft table and family — colocate with fw4 so fw4 manages table lifecycle
MWAN3_NFT_TABLE="inet fw4"
MWAN3_NFT_CHAIN_PRE="mwan3_prerouting"
MWAN3_NFT_CHAIN_OUT="mwan3_output"

# Batch file path set per-invocation to avoid collisions
MWAN3_NFT_BATCH=""

NFT="nft"

# IPv6 disabled?
[ -d /proc/sys/net/ipv6 ]
NO_IPV6=$?

LOG()
{
	local facility=$1; shift
	[ "$facility" = "debug" ] && return
	logger -t "${SCRIPTNAME}[$$]" -p "$facility" "$*"
}

# Execute a single nft command with error logging
mwan3_nft_exec()
{
	local error
	error=$($NFT "$@" 2>&1) || {
		LOG error "nft $*: $error"
		return 1
	}
}

# Start an nft batch transaction
mwan3_nft_batch_start()
{
	# Use /proc/self to get actual PID even in subshells
	# (in ash, $$ returns parent PID in subshells)
	local mypid
	mypid=$(cut -d' ' -f1 /proc/self/stat 2>/dev/null || echo $$)
	MWAN3_NFT_BATCH="/tmp/mwan3_nft_batch.${mypid}"
	: > "$MWAN3_NFT_BATCH"
}

# Add a line to the batch
mwan3_nft_push()
{
	echo "$*" >> "$MWAN3_NFT_BATCH"
}

# Commit the batch atomically
mwan3_nft_batch_commit()
{
	local error
	error=$($NFT -f "$MWAN3_NFT_BATCH" 2>&1) || {
		LOG error "nft batch commit failed: $error"
		LOG error "batch contents: $(cat $MWAN3_NFT_BATCH)"
		rm -f "$MWAN3_NFT_BATCH"
		return 1
	}
	rm -f "$MWAN3_NFT_BATCH"
}

# Build nft mark set expression
# iptables: -j MARK --set-xmark VALUE/MASK
# nft: meta mark set (meta mark & ~MASK) | VALUE
mwan3_nft_mark_expr()
{
	local value="$1" mask="$2"
	local complement
	complement=$(printf "0x%08x" $(( (~mask) & 0xFFFFFFFF )))
	echo "meta mark set meta mark & $complement | $value"
}

# Check if nft chain exists in mwan3 table
mwan3_nft_chain_exists()
{
	$NFT list chain $MWAN3_NFT_TABLE "$1" >/dev/null 2>&1
}

# Check if nft set exists in mwan3 table
mwan3_nft_set_exists()
{
	$NFT list set $MWAN3_NFT_TABLE "$1" >/dev/null 2>&1
}

# Ensure all mwan3 nft framework objects exist.
# Called on start and after fw4 reload (which wipes our chains/sets).
mwan3_ensure_nft_framework()
{
	# Delete existing sets to allow flag changes (auto-merge etc.)
	local setname
	for setname in mwan3_connected_v4 mwan3_connected_v6 \
		       mwan3_custom_v4 mwan3_custom_v6 \
		       mwan3_dynamic_v4 mwan3_dynamic_v6; do
		$NFT delete set $MWAN3_NFT_TABLE "$setname" >/dev/null 2>&1
	done

	mwan3_nft_batch_start

	# Network classification sets (interval + auto-merge for CIDR)
	mwan3_nft_push "add set $MWAN3_NFT_TABLE mwan3_connected_v4 { type ipv4_addr; flags interval; auto-merge; }"
	mwan3_nft_push "add set $MWAN3_NFT_TABLE mwan3_custom_v4 { type ipv4_addr; flags interval; auto-merge; }"
	mwan3_nft_push "add set $MWAN3_NFT_TABLE mwan3_dynamic_v4 { type ipv4_addr; flags interval; auto-merge; }"
	[ $NO_IPV6 -eq 0 ] && {
		mwan3_nft_push "add set $MWAN3_NFT_TABLE mwan3_connected_v6 { type ipv6_addr; flags interval; auto-merge; }"
		mwan3_nft_push "add set $MWAN3_NFT_TABLE mwan3_custom_v6 { type ipv6_addr; flags interval; auto-merge; }"
		mwan3_nft_push "add set $MWAN3_NFT_TABLE mwan3_dynamic_v6 { type ipv6_addr; flags interval; auto-merge; }"
	}

	# Hook chains (base chains with type/hook/priority)
	# priority mangle+1 so we run after fw4's mangle rules
	mwan3_nft_push "add chain $MWAN3_NFT_TABLE $MWAN3_NFT_CHAIN_PRE { type filter hook prerouting priority mangle + 1; policy accept; }"
	mwan3_nft_push "add chain $MWAN3_NFT_TABLE $MWAN3_NFT_CHAIN_OUT { type route hook output priority mangle + 1; policy accept; }"

	# Internal chains (jumped to from hook chains)
	mwan3_nft_push "add chain $MWAN3_NFT_TABLE mwan3_ifaces_in"
	mwan3_nft_push "add chain $MWAN3_NFT_TABLE mwan3_rules"
	mwan3_nft_push "add chain $MWAN3_NFT_TABLE mwan3_connected"
	mwan3_nft_push "add chain $MWAN3_NFT_TABLE mwan3_custom"
	mwan3_nft_push "add chain $MWAN3_NFT_TABLE mwan3_dynamic"

	# Track hook chain — for mwan3track ping marking (old 1.5 pattern)
	# Matches ICMP echo requests of specific size → mark to correct WAN
	mwan3_nft_push "add chain $MWAN3_NFT_TABLE mwan3_track_ifaces"

	mwan3_nft_batch_commit
}

# Get source IP for an interface
mwan3_get_src_ip()
{
	local _src_ip interface family device addr_cmd default_ip
	interface=$2
	config_get family "$interface" family ipv4

	if [ "$family" = "ipv4" ]; then
		addr_cmd='network_get_ipaddr'
		default_ip="0.0.0.0"
	elif [ "$family" = "ipv6" ]; then
		addr_cmd='network_get_ipaddr6'
		default_ip="::"
	fi

	$addr_cmd _src_ip "$interface"
	if [ -z "$_src_ip" ]; then
		network_get_device device "$interface"
		if [ "$family" = "ipv4" ]; then
			_src_ip=$($IP4 address show dev "$device" 2>/dev/null | \
				awk '/inet /{sub("/.*","",$2); print $2; exit}')
		fi
	fi
	[ -z "$_src_ip" ] && _src_ip="$default_ip"
	export "$1=$_src_ip"
}

readfile() {
	[ -f "$2" ] || return 1
	read -d'\0' "$1" <"$2" || :
}

get_uptime() {
    awk '{print int($1)}' /proc/uptime
}
