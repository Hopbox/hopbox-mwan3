#!/bin/sh
# fw4 script include: triggers mwan3 rule rebuild after firewall reload.
# This runs AFTER fw4 has loaded its nftables ruleset (ACTION=includes phase).
# fw4 blocks UCI access in this shell, so we fork a clean background process.

[ "$ACTION" = "include" ] || exit 0

# Fork rebuild as background process with clean environment
/lib/mwan3/mwan3-fw-rebuild.sh &
