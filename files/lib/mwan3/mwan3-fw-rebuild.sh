#!/bin/sh
# Rebuild mwan3 dynamic rules after fw4 reload.
# fw4 reload wipes all dynamic chains/rules from table inet fw4.
# The static skeleton (10-mwan3.nft) survives but chains are empty.
# This script repopulates all rules without restarting mwan3 entirely.

. /lib/functions.sh
. /lib/functions/network.sh
. /lib/mwan3/common.sh
. /lib/mwan3/mwan3.sh

SCRIPTNAME="mwan3-fw-rebuild"

# Only rebuild if mwan3 is actually running
[ -f /var/run/mwan3.lock ] || exit 0

# Only rebuild if rules are missing (chain exists but empty after fw4 reload)
$NFT list chain $MWAN3_NFT_TABLE mwan3_prerouting 2>/dev/null | \
	grep -q "meta mark" && exit 0

# Small delay to let fw4 finish completely and mwan3track connected to fire
# mwan3track connected handler does the full rebuild, so we only need to
# rebuild here if mwan3track hasn't fired yet (early boot race)
sleep 2

# Re-check after delay — mwan3track connected may have already rebuilt
$NFT list chain $MWAN3_NFT_TABLE mwan3_prerouting 2>/dev/null | \
	grep -q "meta mark" && exit 0

LOG notice "Rebuilding mwan3 rules after fw4 reload"

mwan3_init
mwan3_set_general_nft
mwan3_set_connected_sets
mwan3_set_custom_sets
config_foreach mwan3_rebuild_iface_nft interface
mwan3_set_policies_nft
mwan3_set_user_rules

# Signal dnsmasq to repopulate nft sets via --nftset
killall -HUP dnsmasq 2>/dev/null

LOG notice "mwan3 rules rebuilt after fw4 reload"
exit 0
