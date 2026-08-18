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
	"math/rand"
	"time"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/common/lru"
)

// inmemoryWiggles is how many recent out-of-turn deadlines to remember. Only
// blocks currently being sealed matter, so this only has to outlive the re-seals
// of one block; a small cache covers deep reorgs comfortably.
const inmemoryWiggles = 256

// wiggleKey identifies the block a delay was drawn for. Number alone is not
// enough: two candidates at the same height on different parents are different
// blocks and must be free to draw independently.
type wiggleKey struct {
	parent common.Hash
	number uint64
}

// wiggleEntry is the outcome of one draw: the random offset itself, and the
// absolute wall-clock moment sealing may proceed. The deadline — not the
// offset — is what re-seals must share. If re-seals reused only the duration,
// every mid-period rebuild would bump header.Time to "now" (Prepare does this
// for any late block, and an out-of-turn wait is always past the period
// boundary, hence always late) and restart the full countdown. Under a
// sub-period recommit with transactions arriving faster than the drawn delay,
// no out-of-turn signer would ever reach the end of its countdown and the
// chain would stall for as long as the load lasted. Anchoring the deadline in
// absolute time makes rebuilds resume the countdown instead of resetting it.
type wiggleEntry struct {
	deadline time.Time
	drawn    time.Duration
}

type wiggleCache = lru.Cache[wiggleKey, wiggleEntry]

func newWiggleCache() *wiggleCache {
	return lru.NewCache[wiggleKey, wiggleEntry](inmemoryWiggles)
}

// wiggle returns the out-of-turn sealing deadline for the block extending
// parent at the given number, drawing the random offset once and anchoring it
// at earliest (the block's timestamp as of the first Seal call). Every later
// call for the same block returns the same deadline, however much header.Time
// has been bumped by rebuilds in the meantime.
//
// Upstream Clique draws the offset inside Seal and waits relative to the call,
// so it is redrawn every time Seal runs. That is harmless while a block is
// sealed exactly once, which is the case when the recommit interval is at or
// above the block period — the configuration upstream shipped. Once recommit
// drops below the period, taskLoop interrupts and restarts Seal on every
// mid-period rebuild: each redraw is another chance at a small delay, biasing
// an out-of-turn signer toward publishing early and eroding the head start
// that lets the in-turn signer win the height.
//
// Keying the draw to the block and fixing its deadline in absolute time makes
// the delay what Clique intended — a stable, per-signer, per-block offset from
// the period boundary — while keeping the progress guarantee: a rebuild can
// neither shorten the wait (re-roll) nor extend it (countdown reset).
func (c *Clique) wiggle(parent common.Hash, number uint64, earliest time.Time, span time.Duration) (time.Time, time.Duration) {
	key := wiggleKey{parent: parent, number: number}
	if e, ok := c.wiggles.Get(key); ok {
		return e.deadline, e.drawn
	}
	// Defensive only: Seal always passes span = (len(signers)/2+1) * wiggleTime,
	// which is at least 500ms, and a sole signer is always in-turn and never
	// reaches the wiggle branch. Guarded anyway because rand.Int63n panics on a
	// non-positive argument.
	var drawn time.Duration
	if span > 0 {
		drawn = time.Duration(rand.Int63n(int64(span)))
	}
	e := wiggleEntry{deadline: earliest.Add(drawn), drawn: drawn}
	c.wiggles.Add(key, e)
	return e.deadline, e.drawn
}
