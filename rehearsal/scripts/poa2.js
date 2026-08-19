// PoA² — automatic validator replacement (v5).
//
// Same policy as the original PoA2.js: watch clique.status().sealerActivity,
// and when a signer stops sealing, vote in a pre-vetted standby and vote the
// dead signer out — add first, remove second, so the set never dips below its
// starting size.
//
// Five changes, each forced by a failure observed in the rehearsal:
//
//  1. DRIVE LOOP, not setInterval. `geth attach --preload` runs the script,
//     hits EOF on stdin and exits, so a timer never fires. Measured: the
//     banner printed 229 times (the supervisor restarting the attach) while
//     the check ran 0 times — the controller looked alive in the logs and did
//     nothing. A blocking loop with admin.sleep() runs inside the preload,
//     which is why the sealing sidecar has always worked.
//
//  2. CONFIRM BEFORE ACTING. The original replaced a signer the first poll it
//     read zero activity. A validator restarting for a routine upgrade reads
//     exactly the same, so PoA² tried to evict a healthy node mid-upgrade
//     (observed: all three controllers proposed a replacement for a node that
//     was simply rebooting). A restarting node recovers on its own; a dead one
//     does not. So a flagged signer must STAY at zero for CONFIRM_BLOCKS
//     before anything is proposed, and recovering clears the flag.
//
//  3. CYCLE WATCHDOG. The original's `ddd` latch left the detector permanently
//     deaf if a replacement cycle never completed — and one did not, because
//     the vote could not reach a majority. After that the controller ignored
//     every later failure, silently. A cycle that does not finish within
//     CYCLE_TIMEOUT_BLOCKS now resets the state machine so the detector
//     re-arms.
//
//  4. VERIFY THE REPLACEMENT BEFORE REMOVING ANYONE. A standby address with no
//     live node behind it never seals, but still counts toward len(signers) and
//     so raises Clique's recent-signer bar — a controller meant to heal the
//     chain can halt it instead. A promoted standby must prove it seals within
//     VERIFY_BLOCKS; if it does not, it is rolled back, remembered as a
//     phantom, and the next candidate is tried. The failed validator is never
//     removed until a working replacement is in place.
//
//  5. TELL "DOWN" APART FROM "NOT SEALING". Both read as zero activity, but a
//     node that is down leaves the p2p network while one whose sealing sidecar
//     died stays connected. Measured: PoA² replaced a healthy, synced,
//     RPC-serving validator ~193s after its miner stopped, spending a standby
//     on something a sidecar restart fixes. A suspect that is still in
//     admin.peers now gets PEERED_GRACE_BLOCKS and a loud warning instead of
//     CONFIRM_BLOCKS — still replaced if it never recovers, because a
//     validator that does not seal is not contributing, but only after an
//     operator has had a real chance to act.
//
// Deployment note learned the same way: run this on EVERY validator, including
// standbys once promoted. clique.propose() is a local vote, so a proposal only
// carries with a majority of the CURRENT signer set. A promoted standby with
// no controller silently erodes the voting quorum with each replacement.

var POLL_S                = 2;    // seconds between checks
var CONFIRM_BLOCKS        = 120;  // unreachable node: silence before acting (~2 min at period 1)
var PEERED_GRACE_BLOCKS   = 600;  // reachable node that stopped sealing: much longer (~10 min)
var CYCLE_TIMEOUT_BLOCKS  = 300;  // abandon and reset a stuck replacement (~5 min)
var TARGET_SIZE           = 4;    // intended number of active signers
var MIN_SIZE              = 3;    // never shrink below this (below 3, removing hurts)
var VERIFY_BLOCKS         = 60;   // a promoted standby must seal within this many blocks

// address -> the node's --identity string, so a suspect can be looked up in
// admin.peers. A validator that is DOWN vanishes from the peer list; one that
// is merely not sealing (its sealing sidecar died) stays in it. Without this
// the two are indistinguishable and the controller spends a standby on a
// problem that restarting a sidecar would fix.
var PEER_TAG = {
        "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266": "Rehearsal-Validator-1",
        "0x70997970c51812dc3a010c7d01b50e0d17dc79c8": "Rehearsal-Validator-2",
        "0x3c44cdddb6a900fa2b585dd299e03d12fa4293bc": "Rehearsal-Validator-3",
        "0x90f79bf6eb2c4f870365e785982e1f101e93b906": "Rehearsal-Validator-4",
        "0x9965507d1a55bcc2695c58ba16fb37d819b0a4dc": "Rehearsal-Idle-1",
        "0x976ea74026e726554db657fa54763abd0c3a0aa9": "Rehearsal-Idle-2"
};

// The pool: every address that may ever be a validator here — current signers
// first, then standbys. MUST be byte-identical on every controller, or they
// pick different candidates and no proposal reaches a majority.
var POOL = [
        "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266",
        "0x70997970c51812dc3a010c7d01b50e0d17dc79c8",
        "0x3c44cdddb6a900fa2b585dd299e03d12fa4293bc",
        "0x90f79bf6eb2c4f870365e785982e1f101e93b906",
        "0x9965507d1a55bcc2695c58ba16fb37d819b0a4dc",
        "0x976ea74026e726554db657fa54763abd0c3a0aa9"
];

var suspectAddr  = null;   // signer seen with zero activity, not yet confirmed
var suspectSince = 0;      // block at which we first saw it idle
var cycleStart   = 0;      // block at which the active replacement began
var warned       = false;  // operator warning already printed for this suspect
var promoted     = null;   // standby voted in, still being verified
var verifySince  = 0;      // block at which verification of `promoted` began
var deadPool     = [];     // standbys that were promoted but never sealed
// watch -> confirming -> adding -> verifying -> removing        (happy path)
//                                 verifying -> rollback -> watch (phantom standby)
var phase        = "watch";

function lower(a){ return String(a).toLowerCase(); }

function inList(list, addr){
        for (var i = 0; i < list.length; i++) if (lower(list[i]) === lower(addr)) return true;
        return false;
}

// First pool entry that is neither a current signer nor a known phantom.
// Order-deterministic, so every controller nominates the same standby.
function pickStandby(signers){
        for (var i = 0; i < POOL.length; i++) {
                if (inList(signers, POOL[i])) continue;
                if (inList(deadPool, POOL[i])) continue;
                return POOL[i];
        }
        return null;
}

function reset(why){
        if (phase !== "watch") console.log("PoA^2 reset (" + why + ")");
        suspectAddr = null; suspectSince = 0; cycleStart = 0; warned = false;
        promoted = null; verifySince = 0; phase = "watch";
}

// Is the node behind this signer still reachable on the p2p network?
// A node that is down disappears from admin.peers; one whose sealing sidecar
// died stays connected. Our OWN node is never in our peer list, so treat self
// as reachable — otherwise a controller whose own miner stopped would classify
// itself as gone and vote itself out.
function reachable(addr){
        try {
                if (lower(addr) === lower(eth.coinbase)) return true;
        } catch (e) {}
        var tag = PEER_TAG[lower(addr)];
        if (!tag) return null;                    // unmapped: cannot tell
        var peers = admin.peers;
        for (var i = 0; i < peers.length; i++) {
                if (peers[i].name && peers[i].name.indexOf(tag) >= 0) return true;
        }
        return false;
}

function tick(){
        var head    = eth.blockNumber;
        var signers = clique.getSigners();
        var act     = clique.status().sealerActivity;

        // Watchdog: never let an unfinished cycle latch the detector off.
        if (phase !== "watch" && cycleStart > 0 && (head - cycleStart) > CYCLE_TIMEOUT_BLOCKS) {
                reset("cycle exceeded " + CYCLE_TIMEOUT_BLOCKS + " blocks without completing");
        }

        // ---- finish an in-flight replacement -------------------------------
        if (phase === "adding") {
                if (signers.length > TARGET_SIZE) {          // standby is in
                        verifySince = head; phase = "verifying";
                        console.log("PoA^2 " + promoted + " added; verifying it seals within " + VERIFY_BLOCKS + " blocks");
                }
                return;
        }

        // A promoted standby with no live node behind it never seals, yet still
        // counts toward len(signers) and so raises the recent-signer bar — that
        // is how a controller meant to heal a chain can halt it instead. Never
        // remove the failed validator until the replacement has PROVEN it can
        // seal; if it cannot, roll it back and try the next candidate.
        if (phase === "verifying") {
                if (act[promoted] > 0) {
                        console.log("PoA^2 " + promoted + " is sealing; removing " + suspectAddr);
                        clique.propose(suspectAddr, false);
                        phase = "removing";
                } else if ((head - verifySince) > VERIFY_BLOCKS) {
                        console.log("PoA^2 PHANTOM STANDBY " + promoted +
                                    " never sealed in " + VERIFY_BLOCKS + " blocks — rolling it back");
                        clique.propose(promoted, false);
                        deadPool.push(promoted);
                        phase = "rollback";
                }
                return;
        }

        if (phase === "rollback") {
                if (!inList(signers, promoted)) {
                        console.log("PoA^2 phantom removed; set size " + signers.length +
                                    "; will retry with the next standby");
                        reset("phantom rolled back");
                }
                return;
        }
        if (phase === "removing") {
                // `promoted` is null on the pool-exhausted path (shrink, no
                // replacement), so key this purely on the suspect being gone.
                if (!inList(signers, suspectAddr)) {
                        console.log("PoA^2 replacement COMPLETE; set size " + signers.length);
                        reset("done");
                }
                return;
        }

        // ---- watch / confirm -----------------------------------------------
        var idle = null;
        for (var i = 0; i < signers.length; i++) {
                if (act[signers[i]] === 0) { idle = signers[i]; break; }
        }

        if (idle === null) {
                if (suspectAddr !== null) console.log("PoA^2 " + suspectAddr + " resumed sealing — no action");
                reset("suspect recovered");
                return;
        }

        if (suspectAddr === null || lower(suspectAddr) !== lower(idle)) {
                // a different signer than last time: start its clock afresh,
                // including the one-shot operator warning
                suspectAddr = idle; suspectSince = head; warned = false; phase = "confirming";
                console.log("PoA^2 " + idle + " is not mining — confirming over " + CONFIRM_BLOCKS + " blocks");
                return;
        }

        // How long to wait depends on WHY it is silent. A node that has left the
        // network is genuinely gone — replace it promptly. A node that is still
        // connected is alive and merely not sealing (typically a dead sealing
        // sidecar); replacing it burns a standby on something an operator can
        // fix in seconds, so it gets a much longer grace period and a loud
        // warning first. It is still replaced eventually: a validator that
        // never seals is not contributing, whatever the reason.
        var live = reachable(suspectAddr);
        var need = (live === true) ? PEERED_GRACE_BLOCKS : CONFIRM_BLOCKS;
        var waited = head - suspectSince;

        // >= with a fire-once flag, not == : polls are 2s apart while blocks
        // arrive roughly every second, so `waited` advances ~2 per poll and can
        // step straight over an exact value. Measured: only 4 of 6 controllers
        // ever printed this warning. With fewer controllers it could be none,
        // and this warning is the operator's only cue to restart a sidecar
        // before the grace period runs out.
        if (live === true && waited >= CONFIRM_BLOCKS && !warned) {
                warned = true;
                console.log("PoA^2 WARNING " + suspectAddr + " is REACHABLE but not sealing" +
                            " — its sealing sidecar is probably dead. Restart it. Replacing in " +
                            (PEERED_GRACE_BLOCKS - CONFIRM_BLOCKS) + " more blocks if it stays silent.");
        }
        if (waited < need) return;                            // still confirming

        // Confirmed dead. Nominate a standby and vote it in.
        var standby = pickStandby(signers);

        // Nothing left to promote. Before giving up, retry candidates that were
        // written off as phantoms: a standby whose node was down an hour ago may
        // be running now, and a permanent blacklist turns a transient outage
        // into a permanent loss of capacity.
        if (standby === null && deadPool.length > 0) {
                console.log("PoA^2 pool exhausted; retrying " + deadPool.length +
                            " previously-unreachable standby(s)");
                deadPool = [];
                standby = pickStandby(signers);
        }

        if (standby === null) {
                // Genuinely no replacement available. Removing the dead signer
                // anyway is NOT giving up — it is the safer state. Clique needs
                // floor(n/2)+1 signers to seal, so with 4 signers and one dead
                // there are exactly 3 of 3 required and no margin at all; drop
                // to 3 signers and the requirement falls to 2, leaving a spare.
                // Shrinking below MIN_SIZE reverses that, so stop there.
                if (signers.length > MIN_SIZE) {
                        console.log("PoA^2 standby pool EXHAUSTED — removing " + suspectAddr +
                                    " without replacement: " + signers.length + " signers with one dead needs " +
                                    (Math.floor(signers.length / 2) + 1) + " sealers, " + (signers.length - 1) +
                                    " signers needs " + (Math.floor((signers.length - 1) / 2) + 1) +
                                    ". Restore a standby as soon as possible.");
                        clique.propose(suspectAddr, false);
                        cycleStart = head;
                        phase = "removing";
                } else {
                        console.log("PoA^2 standby pool EXHAUSTED and the set is already at the minimum of " +
                                    MIN_SIZE + " — cannot shrink further without making liveness worse. " +
                                    suspectAddr + " is dead and OPERATOR ACTION IS REQUIRED.");
                        reset("pool exhausted at minimum size");
                }
                return;
        }
        console.log("PoA^2 " + suspectAddr + " confirmed " +
                    (live === true ? "unresponsive (reachable but never sealed)" : "dead (off the network)") +
                    "; proposing standby " + standby);
        clique.propose(standby, true);
        promoted = standby;
        cycleStart = head;
        phase = "adding";
}

console.log("PoA^2 v5 running (poll " + POLL_S + "s; confirm " + CONFIRM_BLOCKS +
            " blocks if unreachable, " + PEERED_GRACE_BLOCKS + " if still peered; verify " +
            VERIFY_BLOCKS + "; cycle timeout " + CYCLE_TIMEOUT_BLOCKS + ")");

while (true) {
        try { tick(); } catch (e) { console.log("PoA^2 tick error (continuing): " + e); }
        admin.sleep(POLL_S);
}
