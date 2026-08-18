// PureChain — Smart Auto-Mining v2
// The sealing policy used by PureChain validators. The rehearsal runs it
// unmodified, so a binary upgrade is tested against the real "on-demand
// mining" mechanism rather than a simplified stand-in.
// ---------------------------------------------------------------------------
// Preserves the on-demand ("smart auto mining") novelty — validators do NOT
// seal empty blocks when the whole network is idle — while eliminating the
// Clique liveness stall described below.
//
// Why v1 stalled: it started/stopped the miner from THIS node's LOCAL
// txpool.status.pending only. Under load, txs propagate with nonce gaps, so a
// validator briefly sees pending==0 (its copies sit in `queued`) and stops.
// When the number of actively-sealing validators M drops below Clique's
// limit = floor(N/2)+1 (=3 for 4 signers), every remaining sealer hits
// "signed recently, must wait for others" and the chain deadlocks.
//
// v2 fix — seal if ANY of:
//   (a) local txpool.pending > 0                 -> I have ready work
//   (b) local txpool.queued  > 0                 -> I have nonce-gapped work (will become ready)
//   (c) a block within IDLE_WINDOW carried txs   -> the NETWORK is active
// (c) is a GLOBAL, identical signal for every validator (they all follow the
// same chain), so all validators stay in the sealer set TOGETHER during any
// activity -> M stays == N >= limit -> no deadlock. When no txs exist anywhere,
// blocks stop carrying txs; after IDLE_WINDOW every validator independently
// observes the same quiet chain and stops -> no perpetual empty blocks.
//
// Run per-validator as a background attach:
//   geth attach <ipc> --exec 'loadScript("/scripts/autoMine-v2.js")'
// ---------------------------------------------------------------------------

var IDLE_WINDOW_MS = 15000;  // keep sealing this long after the last network tx activity
var POLL_S         = 2;      // poll interval (seconds)
var STALL_SECS     = 12;     // watchdog: ready work but head frozen this long -> warn + nudge
var MAX_SCAN       = 25;     // cap block back-scan per poll (catch-up safety)

function unlock() {
    try { miner.setEtherbase(eth.accounts[0]); } catch (e) { console.log("v2 setEtherbase: " + e); }
    // personal namespace may be disabled; the account may already be unlocked via --unlock.
    try { if (typeof personal !== "undefined") personal.unlockAccount(eth.coinbase, "", 0); }
    catch (e) { console.log("v2 unlockAccount (non-fatal, may already be unlocked): " + e); }
    try { miner.setGasPrice(0); } catch (e) {}
}
unlock();

function startMiner() {
    if (eth.mining) return;
    try { miner.start(); }
    catch (e) {
        try { miner.setEtherbase(eth.accounts[0]); miner.start(); }
        catch (e2) { console.log("v2 miner.start failed: " + e2); }
    }
}
function stopMiner() { if (eth.mining) { try { miner.stop(); } catch (e) {} } }

function txCounts() {
    try { var s = txpool.status; return { p: (s.pending || 0), q: (s.queued || 0) }; }
    catch (e) { return { p: 0, q: 0 }; }
}

var lastNetworkActiveMs = 0;   // wall-clock of the last tx-bearing block we observed
var lastSeenHead        = -1;
var headMovedAtMs       = 0;    // wall-clock when the head last advanced

// Inspect blocks that appeared since the previous poll; refresh the
// network-active timer if any carried transactions.
function scanNewBlocks(now) {
    var head;
    try { head = eth.blockNumber; } catch (e) { return -1; }
    if (lastSeenHead < 0) { lastSeenHead = head; headMovedAtMs = now; return head; }
    if (head > lastSeenHead) {
        var from = Math.max(lastSeenHead + 1, head - MAX_SCAN);
        for (var n = from; n <= head; n++) {
            try {
                var b = eth.getBlock(n);
                if (b && b.transactions && b.transactions.length > 0) lastNetworkActiveMs = now;
            } catch (e) {}
        }
        lastSeenHead  = head;
        headMovedAtMs = now;
    }
    return head;
}

console.log("Smart Auto-Mining v2 loaded (trigger: pending||queued||tx-activity<" +
            (IDLE_WINDOW_MS / 1000) + "s; poll " + POLL_S + "s; watchdog " + STALL_SECS + "s). Polling...");

while (true) {
    var now  = new Date().getTime();
    var head = scanNewBlocks(now);
    var c    = txCounts();
    var localWork = (c.p > 0 || c.q > 0);
    if (localWork) lastNetworkActiveMs = now;               // my own work counts as activity
    var networkBusy = (now - lastNetworkActiveMs) < IDLE_WINDOW_MS;

    if (localWork || networkBusy) startMiner();
    else                          stopMiner();

    // Watchdog: ready work present but head not advancing -> surface + nudge.
    // The frozen-timer must only count time while there is PENDING work; when there is
    // no ready work the head is legitimately idle, so reset the timer (otherwise the
    // whole preceding idle gap counts as "frozen" and the watchdog false-fires at the
    // first burst after any quiet period).
    if (c.p === 0) headMovedAtMs = now;
    if (c.p > 0 && (now - headMovedAtMs) > STALL_SECS * 1000) {
        console.log("!! v2 WATCHDOG: pending=" + c.p + " queued=" + c.q +
                    " head=" + head + " frozen " + Math.round((now - headMovedAtMs) / 1000) +
                    "s (mining=" + eth.mining + ", peers=" + admin.peers.length + "). Nudging.");
        stopMiner(); startMiner();
        headMovedAtMs = now;   // avoid tight-loop nudging
    }

    admin.sleep(POLL_S);
}
