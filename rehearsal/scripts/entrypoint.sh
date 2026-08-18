#!/bin/bash
# Entrypoint script for Geth nodes — the same one PureChain validators use.
# Runs Geth, then adds static peers once the IPC is actually accepting connections.

# Start Geth in the background with all passed arguments
exec geth "$@" &
GETH_PID=$!

# Add static peers.
#
# A socket file existing (-S) does NOT mean geth is accepting IPC connections yet,
# so we retry the attach itself until it succeeds AND the node reports at least one
# peer. The previous version attached once as soon as the socket appeared and then
# broke out unconditionally; when that single attempt raced geth's IPC startup it
# failed with "Fatal: Unable to attach ... connection refused" and the node came up
# isolated with 0 peers (observed during the Istanbul->Cancun upgrade, 2026-07-04).
echo "Waiting for Geth IPC to accept connections, then adding peers..."
for i in $(seq 1 60); do
    if [ -S /data/geth.ipc ]; then
        geth attach --exec 'loadScript("/scripts/addpeers.js")' /data/geth.ipc 2>/dev/null
        # Confirm peers actually registered; retry if still isolated. addPeer is
        # idempotent, so repeated calls during the startup window are harmless.
        PEERS=$(geth attach --exec 'admin.peers.length' /data/geth.ipc 2>/dev/null)
        if [ -n "$PEERS" ] && [ "$PEERS" -gt 0 ] 2>/dev/null; then
            echo "Peers added (count=$PEERS)."
            break
        fi
    fi
    sleep 2
done

# Wait for Geth process (foreground the background process)
wait $GETH_PID
