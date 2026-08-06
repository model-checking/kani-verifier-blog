---
layout: post
title: "The Lean proof was correct. The Rust still had a bug."
---

[bitrep](https://github.com/KyleClouthier/bitrep) is a Rust crate with one promise: a floating-point
reduction whose result, and whose whole accumulator *state*, is byte-identical regardless of
summation order, thread count, shard split, batch size, SIMD width, or CPU architecture. Add the
same numbers in any order on any machine and you get the same bits.

That promise rests on an algebra. Merging two accumulators has to commute and associate, the byte
codec has to round-trip, and the state has to be independent of insertion order. Those laws are
proved at the model level in Lean 4.

**The Lean proof was correct. The Rust still had a bug.**

That sentence is the whole post, so it is worth saying plainly up front. A proof about a model tells
you nothing about the code underneath it unless something connects the two. The model can be
flawless while the implementation meant to realise it is wrong, and re-checking the model will never
tell you, because the model is not where the mistake is.

**Kani is what connected them, and Kani is what caught it.** A harness ranging over arbitrary bytes,
instead of over honestly-built values, returned a counterexample in seconds: a pair of accumulator
states, reachable only by decoding, for which a merge law proved in Lean is false in the Rust. No
test suite built on the crate's own API could have reached those states, and that is not a criticism
of the test suite. It is a statement about which inputs a test suite can construct.

## The bug

`ExtremaF64` tracks a running minimum and maximum. Its state is a min, a max, a NaN flag, a `seen`
flag saying whether anything has been added yet, and a count. The merge short-circuits on empty
states, which is the obvious and correct thing to do:

```rust
fn merge(&mut self, other: &Self) {
    self.count = self.count.saturating_add(other.count);
    self.nan |= other.nan;
    if !other.seen {
        return;                        // other is empty: keep self unchanged
    }
    if !self.seen {                    // self is empty: adopt other's extrema
        self.min_bits = other.min_bits;
        self.max_bits = other.max_bits;
        self.seen = true;
        return;
    }
    // both non-empty: take the true min and max
```

Now consider two states that are both **empty**, and that differ only in the min/max fields the
merge never reads:

```
A:  seen = false,  min_bits = 0xFFFF_FFFF_FFFF_FFFF
B:  seen = false,  min_bits = 0xFFFF_FFFF_FFFF_FFFE
```

`A.merge(B)` takes the first branch and keeps A's bits. `B.merge(A)` takes the same branch and keeps
B's bits. Both results are still empty and logically identical, and **they serialise to different
bytes.** Merge commutativity, stated over the encoded state, is false.

<img src="{{site.baseurl | prepend: site.url}}/assets/images/bitrep-empty-state-merge.svg" alt="Two empty accumulator states differing only in min_bits, a field the merge never reads. Both merge orders short-circuit on the empty check and keep the receiver's bits, so the two results serialise to different byte strings while meaning the same thing." />

No accumulator built by adding numbers can be in that state, because `add` always writes canonical
zeros there. The only way to construct it is to decode it from bytes. So a test suite that builds
accumulators honestly, merges them in both orders, and compares, will never find this. Not because
the suite is weak, but because the state it needs is unreachable through the API it uses.

## The harness that finds it

The fix, in the harness, is to start from symbolic *bytes* instead of symbolic *numbers*:

```rust
/// ExtremaF64 merge commutes for ALL states (adversarial decodes included).
#[kani::proof]
fn extrema_merge_commutes() {
    let ba: [u8; crate::ExtremaF64::BYTES] = kani::any();
    let bb: [u8; crate::ExtremaF64::BYTES] = kani::any();
    let (Some(a0), Some(b0)) = (
        crate::ExtremaF64::from_bytes(&ba),
        crate::ExtremaF64::from_bytes(&bb),
    ) else {
        return;
    };
    let mut ab = a0.clone();
    crate::Mergeable::merge(&mut ab, &b0);
    let mut ba2 = b0;
    crate::Mergeable::merge(&mut ba2, &a0);
    assert_eq!(ab.to_bytes(), ba2.to_bytes());
}
```

The quantifier this establishes is the one that matters for a format other people will send you:
**for every byte string the decoder accepts**, merge commutes. Whether an honest encoder could have
produced that state is irrelevant, because an attacker is not an honest encoder.

Note what the `else { return; }` does. States the decoder *rejects* are excluded from the claim.
That is deliberate, and it is what pushes the obligation onto `from_bytes`: anything it lets through
must satisfy the law. The decoder is where the burden belongs.

## The fix, and how to reproduce the failure

The repair is three lines in the decoder:

```rust
if b[16] & 2 == 0 && (min_bits != 0 || max_bits != 0) {
    return None;  // empty state must carry canonical zero bits
}
```

An empty state now has exactly one legal encoding, so the two states above can no longer both exist.

You can watch this work. Comment out those three lines in `src/lattice.rs` and run the harness:

```
$ cargo kani --no-default-features --harness extrema_merge_commutes

VERIFICATION:- FAILED
Complete - 0 successfully verified harnesses, 1 failures, 1 total.
```

`assert_eq!` formats its message at runtime, which Kani cannot do, so the failure text is a
placeholder. `--concrete-playback=print` gives the actual inputs, and decoding the two 25-byte
states it produced:

```
state A:  seen = false   min_bits = 0xFFFF_FFFF_FFFF_FFFF   count = 5
state B:  seen = false   min_bits = 0xFFFF_FFFF_FFFF_FFFE   count = 9223372036854775805
```

Two empty accumulators, differing by one bit in a field neither merge path reads. That is the whole
bug, handed over as a concrete pair of byte strings.

## Why the Lean proof could not have caught it

This is the part I found most instructive, and it is why the crate carries proofs at three levels
with explicitly different jobs.

**Lean owns the algebra.** It proves that a permutation of the inputs cannot change the accumulated
state, that merge is commutative and associative. Those proofs were correct throughout. They are
about an abstract lattice, and an abstract lattice has no encoding, so it has no notion of two byte
strings denoting one element. The bug is *invisible* at that level, not missed.

**Kani owns the implementation's conformance to that algebra.** This is where 34 `u64` limbs, a
carry chain, a flags byte and a decoder actually live. A model-level proof can be perfect while the
Rust drifts away from it, and nothing at the model level will notice.

**A differential fuzzer owns the numerical semantics.** `value()` performs f64 arithmetic that Kani
models slowly, so its correct rounding is checked against a BigInt oracle, NIST StRD datasets, and
golden cross-architecture vectors instead. The fuzzer has found real bugs of its own, including two
decoder defects in the crate's quantile sketch, and the changelog records which tool found which.

On cadence, since the three layers cost very different amounts: the six fast Kani harnesses run on
**every push**, and the fuzz targets run **nightly** on a schedule, bounded, because a useful fuzz
run is measured in hours and a useful Kani run here is measured in seconds. All three layers landed
in the same commit, so this was not fuzz-first with proofs bolted on later; the boundaries were
drawn before any of them were written, which is what made it obvious which tool owed which property.

One honest wrinkle, in the same spirit as the harness count above: five fuzz targets exist and the
nightly matrix runs three of them. The two that are not scheduled are the two that historically
found bugs. That is the same gap between what exists and what runs, one layer down, and I noticed it
while writing this paragraph.

That division is written into the harness module's header so a reader cannot mistake one for the
other:

```rust
//! What is proven vs merely tested:
//! * proven here — order-invariance of the accumulator state, merge
//!   commutativity, exact cancellation, byte-codec round-tripping;
//! * tested (BigInt oracle, NIST StRD, golden vectors) — correct rounding of
//!   `value()`, which involves f64 arithmetic Kani models slowly.
```

## Where Kani stopped

There are eleven `#[kani::proof]` harnesses in
[`src/kani_proofs.rs`](https://github.com/KyleClouthier/bitrep/blob/main/src/kani_proofs.rs).
**CI runs six of them**, and I think the gap is worth reporting honestly.

The six that run on every push are the merge and codec harnesses. They operate on fixed-shape limb
arithmetic, and CBMC handles them in seconds to minutes.

The three add-path harnesses are different. `add_commutes`, `cancellation_is_exact` and
`add_placement_is_irrelevant` each take a symbolic `f64`, decompose it into exponent and mantissa,
and shift it across all 34 limbs. On CI runners **they did not close in roughly three hours.** They
are gated behind `cfg(kani_slow)` for local runs, with the reason recorded in the source.

So **a green CI badge on this repository warrants six properties, not eleven.** The other five look
identical in the source; the fact that a model checker never reached them lives in `ci.yml`. The
add-path properties are not abandoned, they are proved in Lean and exercised by the oracle tests and
the fuzzer, but "proved in Lean and fuzzed in Rust" is a weaker claim than "proved in Rust," and
collapsing the two would be the exact overclaim this tooling is meant to prevent.

## Are my passing harnesses checking anything?

Six harnesses pass on every push. That number is only worth something if a failure was reachable, so
I turned the question on my own crate.

`VERIFICATION:- SUCCESSFUL` is printed whether a harness proved something over every input or over
no inputs at all. If a precondition is unsatisfiable, nothing reaches the assertion, the property
holds vacuously, and the verdict line is character-for-character identical to a real proof.

bitrep has two `kani::assume` sites and **zero** `kani::cover` sites. Neither assume is vacuous
today: finite `f64` values plainly exist, and the count-overflow guard in `unmerge_inverts_merge` is
satisfied by any pair of small counts. I checked by hand. But nothing in CI would tell me if that
stopped being true, and "I checked by hand once" is not a property of the build.

To see the failure mode clearly I wrote a
[small MIT-licensed repository](https://github.com/KyleClouthier/kani-vacuity-demo): one
deliberately broken function, five harness styles.

```rust
pub fn scaled_round_trip(v: i32) -> i32 { (v * 2) / 2 }   // overflows for large v
```

```
style_a_concrete        assert on 42                 VERIFICATION:- SUCCESSFUL
style_b_symbolic        kani::any()                  VERIFICATION:- FAILED
style_c_unsatisfiable   assume(v > 100 && v < 50)    VERIFICATION:- SUCCESSFUL
style_d_overconstrained assume(v == 0)               VERIFICATION:- SUCCESSFUL
style_e_c_plus_cover    C plus kani::cover!          VERIFICATION:- SUCCESSFUL
```

**Four of five report success on code that is knowingly wrong.** In style C the overflow check is
never examined at all:

```
Checking harness verify::style_c_unsatisfiable_assume...
   - Status: UNREACHABLE   "attempt to multiply with overflow"
VERIFICATION:- SUCCESSFUL
```

Style E adds one line, `kani::cover!(true, ...)`, and the information surfaces:

```
 ** 0 of 6 failed (4 unreachable)
 ** 0 of 1 cover properties satisfied (1 unreachable)
VERIFICATION:- SUCCESSFUL
```

The cover reports UNREACHABLE in the detail while the verdict still reads SUCCESSFUL. So the signal
is there, below the line most people read.

Style D is worth a moment because it fails differently. Its `assume(v == 0)` is perfectly
satisfiable, so all six checks genuinely run and genuinely pass: `(0 * 2) / 2 == 0` is true. That
harness is not vacuous, it is merely useless, and **no reachability check would ever flag it.**
Covering your assumes catches the empty set. It does not catch a harness that examines one input and
calls it a proof.

None of this is a new observation. Vacuity detection goes back to Beer, Ben-David, Eisner and Rodeh
in 1997, and the Kani team shipped `kani::cover` and
[wrote about it](https://model-checking.github.io/kani-verifier-blog/2023/01/30/reachability-and-sanity-checking-with-kani-cover.html)
precisely because they know. The habit I would add is small: pair a `cover` with every `assume` and
treat an UNREACHABLE cover in CI as a failure, because otherwise the two outcomes are
indistinguishable where anybody actually looks.

## What I would tell someone starting

**Make your harness range over what the attacker controls, not over what your API produces.** The
merge bug lived entirely in states no honest encoder can build. Starting from `kani::any()` bytes
found it in seconds; starting from symbolic numbers never would have.

**Decide what each tool owns before writing any of them.** A model-level proof and an
implementation-level proof answer different questions, and the gap between them is exactly where
this bug lived.

**Measure the cost split and publish it.** Some of your harnesses will not close. That is
information about where the hard part is. What is not acceptable is letting a harness count imply
coverage it does not have.

**Make sure a green harness could have gone red.** If nothing reaches your assertion you have proved
a theorem about the empty set, and the output will not tell you unless you ask. I am adding covers to
bitrep's assumes for that reason: not because either is vacuous now, but because I would like the
build to be what notices if that changes.

Kani gave me a genuinely strong guarantee over the part of this crate it could reach: for every byte
string the decoder accepts, on every input, the merge laws hold and the codec round-trips. Being
precise about the edge of "could reach" is what makes the guarantee worth stating at all.

Harnesses are in
[`src/kani_proofs.rs`](https://github.com/KyleClouthier/bitrep/blob/main/src/kani_proofs.rs), the CI
job is in [`.github/workflows/ci.yml`](https://github.com/KyleClouthier/bitrep/blob/main/.github/workflows/ci.yml),
and the vacuity demo is [here](https://github.com/KyleClouthier/kani-vacuity-demo). Happy to answer
questions.
