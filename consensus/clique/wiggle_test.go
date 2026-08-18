// Copyright 2026 The go-ethereum Authors
// This file is part of the go-ethereum library.
//
// The go-ethereum library is free software: you can redistribute it and/or modify
// it under the terms of the GNU Lesser General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// The go-ethereum library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU Lesser General Public License for more details.
//
// You should have received a copy of the GNU Lesser General Public License
// along with the go-ethereum library. If not, see <http://www.gnu.org/licenses/>.

package clique

import (
	"math/big"
	"testing"
	"time"

	"github.com/ethereum/go-ethereum/common"
)

// TestWiggleStableAcrossReseals asserts that the out-of-turn sealing deadline is
// a property of the block being sealed, not of the Seal call.
//
// Why this matters: taskLoop restarts engine.Seal whenever the seal hash changes,
// which happens on every mid-period rebuild once --miner.recommit is lowered
// below the block period. If Seal drew a fresh wiggle each time, each restart
// would be another chance to draw a small delay, biasing an out-of-turn signer
// toward publishing early and increasing same-height contention on a
// multi-signer chain.
//
// Simulated at 4 signers (wiggle range 0-1500ms) with a 250ms recommit, the mean
// head start drops from ~749ms to ~518ms and ~6.6% of seals fire within 100ms of
// header.Time. Caching the draw per (parent, number) removes that entirely.
func TestWiggleStableAcrossReseals(t *testing.T) {
	c := &Clique{wiggles: newWiggleCache()}

	parent := common.HexToHash("0xaa")
	span := 1500 * time.Millisecond
	t0 := time.Unix(1_700_000_000, 0)

	deadline, drawn := c.wiggle(parent, 10, t0, span)
	if drawn < 0 || drawn >= span {
		t.Fatalf("wiggle %v outside [0,%v)", drawn, span)
	}
	if want := t0.Add(drawn); !deadline.Equal(want) {
		t.Fatalf("deadline %v not anchored at earliest+drawn (%v)", deadline, want)
	}
	// Re-sealing the same block must reuse the original draw AND the original
	// absolute deadline, even when the caller passes a later "earliest" — which
	// is exactly what happens on a rebuild, because Prepare bumps header.Time to
	// "now" for late blocks. Reusing only the duration while re-anchoring at the
	// bumped time would restart the countdown on every rebuild; under a
	// sub-period recommit with steady transaction load that countdown would
	// never complete and the chain would stall (the bug this file guards).
	for i := 0; i < 50; i++ {
		later := t0.Add(time.Duration(i) * 250 * time.Millisecond)
		gotDeadline, gotDrawn := c.wiggle(parent, 10, later, span)
		if gotDrawn != drawn {
			t.Fatalf("re-seal %d drew a different wiggle: got %v, want %v", i, gotDrawn, drawn)
		}
		if !gotDeadline.Equal(deadline) {
			t.Fatalf("re-seal %d moved the deadline: got %v, want %v — countdown was reset", i, gotDeadline, deadline)
		}
	}
	// A different block must be free to draw again, otherwise every block would
	// inherit one signer's delay forever.
	var differs bool
	for n := uint64(11); n < 60 && !differs; n++ {
		if _, d := c.wiggle(parent, n, t0, span); d != drawn {
			differs = true
		}
	}
	if !differs {
		t.Error("every block number produced an identical wiggle; the draw is not per-block")
	}
	// A different parent at the same height is a different block too (reorg).
	_, sameHeightOtherParent := c.wiggle(common.HexToHash("0xbb"), 10, t0, span)
	if sameHeightOtherParent == drawn {
		// Not impossible by chance, but with a 1500ms span it is a 1-in-many event;
		// retry a few distinct parents before concluding the key ignores the parent.
		allSame := true
		for i := 0; i < 20; i++ {
			p := common.BigToHash(big.NewInt(int64(1000 + i)))
			if _, d := c.wiggle(p, 10, t0, span); d != drawn {
				allSame = false
				break
			}
		}
		if allSame {
			t.Error("wiggle ignored the parent hash; reorged blocks would share a draw")
		}
	}
}

// TestWiggleZeroSpan guards the degenerate single-signer case: with one signer
// every block is in-turn, but if the span is ever zero the helper must not panic
// (rand.Int63n panics on a non-positive argument) and must not delay at all.
func TestWiggleZeroSpan(t *testing.T) {
	c := &Clique{wiggles: newWiggleCache()}
	t0 := time.Unix(1_700_000_000, 0)
	deadline, drawn := c.wiggle(common.HexToHash("0xcc"), 1, t0, 0)
	if drawn != 0 {
		t.Fatalf("zero span must yield zero delay, got %v", drawn)
	}
	if !deadline.Equal(t0) {
		t.Fatalf("zero span must not move the deadline: got %v, want %v", deadline, t0)
	}
}
