---
layout: post
title: "Fixing a 2.5-Year-Old Floating-Point Bug with AI-Assisted Formal Verification"
---

What if you could take a tricky algorithm buried in a C++ codebase, prove it correct in Coq, and have CI enforce that the proof and implementation stay in sync — without being an expert in either Coq or the codebase?

That's what we did to fix a long-standing soundness issue in [CBMC](https://www.cprover.org/cbmc/), the bounded model checker that powers [Kani](https://github.com/model-checking/kani).
Using [Kiro CLI](https://kiro.dev) (an AI coding assistant powered by Claude), we implemented a new floating-point remainder algorithm, proved it correct in both Coq and HOL Light, and set up symbolic verification tests that bridge the gap between proof and implementation.
The AI served as a universal translator between these domains — reading C++ bit manipulation, writing Coq real analysis, generating SMT-LIB2 quantified formulas, and maintaining the correspondence between all three formalisms — while the human guided the design and caught the places where the AI's reasoning went wrong.

The most interesting part: the proof and the verification disagreed.
The Coq proof passed with zero admits, but CBMC's symbolic verification on `_Float16` found a counterexample.
The proof had made an assumption that didn't hold in the general case.
That interplay — proof informs implementation, verification challenges proof, proof is revised — is the real story here.

To our knowledge, this is the first use of AI to produce machine-checked proofs (in Coq and HOL Light) of an algorithm implemented in an existing C++ codebase, as distinct from AI-assisted proofs of pure mathematics.

## The bug

In August 2023, a [Kani issue](https://github.com/model-checking/kani/issues/2669) reported that `f32::rem_euclid` produced incorrect results:

```rust
#[kani::proof]
fn check_rem_euclid() {
    let x: f32 = kani::any();
    let y: f32 = kani::any();
    kani::assume(y > 0.0 && !y.is_nan() && !y.is_infinite());
    kani::assume(!x.is_nan() && !x.is_infinite());
    let r = x % y;  // Uses fmod under the hood
    // fmod(x, y) should satisfy |r| < |y|
    kani::assert(r.abs() < y.abs() || r == 0.0);
    // Kani: VERIFICATION FAILED
    // Counterexample: x = 1e4, y = 1e-4
}
```

The root cause was in CBMC — Kani's verification backend — where the floating-point `fmod` and `remainder` operations had been unsound for years.
A [CBMC pull request](https://github.com/diffblue/cbmc/pull/7885) was opened in September 2023.
It sat open for over two and a half years — not for lack of interest, but because the fix is genuinely non-trivial.

C's `fmod` and IEEE 754's `remainder` both compute "x modulo y" but differ in how they round the quotient:

```c
fmod(7.5, 2.1)      ≈  1.2   // quotient truncated: 7.5 - 3×2.1
remainder(7.5, 2.1)  ≈ -0.9   // quotient rounded:  7.5 - 4×2.1
```

(The `≈` is because 2.1 is not exactly representable in binary floating point; the IEEE results differ slightly from the exact-arithmetic values.)

Both were broken.
And the special cases were wrong too — per IEEE 754-2019 §5.3.1, `fmod(∞, y)` must return NaN, but CBMC returned `∞`; `fmod(x, 0)` must return NaN, but CBMC returned an unconstrained value.

## Why this is hard: CBMC encodes operations as Boolean circuits

CBMC is a *bounded model checker*: rather than executing a program, it encodes the program's semantics as a Boolean formula and asks a SAT solver whether any input can violate an assertion.
Each floating-point operation becomes a circuit of Boolean variables — just as a hardware ALU implements addition with logic gates, CBMC constructs an equivalent in software.
Adding two 32-bit floats requires roughly 5,000 Boolean variables; multiplying requires about 15,000.

For most operations, this encoding is well-understood.
But `fmod` has a fundamental problem: **the intermediate quotient can overflow the floating-point range**.

Consider `fmod(1e38f, 1e-38f)`.
The exact quotient is approximately 10^76 — far beyond the range of any 32-bit float (maximum ≈ 3.4×10^38).
CBMC's float division produces `+∞`, and everything downstream is garbage.
The correct answer is `0.0f`.
This happens whenever the exponents of `x` and `y` differ by more than about 38 — a perfectly ordinary situation.

Standard library implementations (like glibc's) handle this with a loop that iteratively subtracts scaled multiples of `y`:

```
Iteration 1: x₁ = x - (y × 2^k₁)     // reduce exponent gap by up to 23 bits
Iteration 2: x₂ = x₁ - (y × 2^k₂)    // reduce by up to 23 more
...
Iteration n: xₙ < |y|                  // done after about 12 iterations for float
```

But CBMC doesn't execute loops — it *unwinds* them into a flat formula.
For `double`, the worst case requires about 40 iterations, each containing a full floating-point subtraction (~50,000 Boolean variables).
That's 2 million variables for a single `fmod` call — and the resulting formula can require minutes to hours for the SAT solver to resolve.

The fix requires an algorithm that produces the correct result in a fixed number of steps, regardless of input values.

## Kiro's first attempt: extended precision

Kiro's first idea was to widen the floating-point format by a few extra fraction bits, compute the quotient in this wider format (where the extra precision prevents rounding errors from pushing the quotient across an integer boundary), then round back.

This approach is simple and produces a small Boolean circuit.
But it only works when the extra bits are enough to absorb the rounding error — and for large quotients, they aren't.
CBMC's symbolic verification on `_Float16` quickly found counterexamples at tie-breaking boundaries where even 3 extra bits weren't sufficient.

## Kiro's second attempt: FMA-based remainder

Next, Kiro proposed using *fused multiply-add* (FMA) — an operation that computes `a × b + c` with a single rounding.
CBMC didn't have FMA, so Kiro implemented it from scratch in both the propositional backend (`float_utilst`, used by the SAT solver) and the expression-level backend (`float_bvt`, used by the SMT2 bitvector encoding).
The SMT2 FPA backend doesn't need a custom implementation — it delegates to the underlying SMT solver's native `fp.fma`.

The idea: compute a tentative quotient `n = round(x/y)`, then use FMA to evaluate `x - n×y` precisely.
Since FMA rounds only once, and the correct remainder is always exactly representable (a fact we later proved), FMA returns the exact result.

At the human's suggestion, Kiro wrote a proof sketch arguing correctness, and generated SMT-LIB2 scripts to verify the algorithm on small floating-point formats.

**Z3 found two bugs in seconds.**

**Bug 1:** The algorithm used the sign of the tentative remainder to choose between `n+1` and `n-1`.
Z3 produced a counterexample: with `x = -3.5, y = 1.0`, the tentative `n = -4` gives remainder `0.5` (positive), suggesting `n-1 = -5` — but the correct answer is `n+1 = -3`.
Fix: try both directions, pick the smallest result.

**Bug 2:** When `|x/y|` exceeds the float range, the division overflows to infinity and everything breaks — the exact problem we started with.
The FMA-only approach doesn't solve the overflow.

## Kiro's third attempt: integer significand arithmetic

After the SMT solver exposed the overflow bug, Kiro proposed a fundamentally different approach for step 1.

Floating-point numbers are integers (significands) multiplied by powers of 2.
If `x = mx × 2^ex` and `y = my × 2^ey`, then:

```
fmod(x, y) = (mx × 2^(ex-ey) mod my) × 2^ey
```

This is an integer modulo — no floating-point division, no overflow, no iteration.

Tracing through `fmod(10.0, 3.0)` in single precision (both values are exactly representable, so there are no rounding complications):

```
x = 10.0 → significand mx = 10485760 (0xA00000), exponent ex = 3
y =  3.0 → significand my = 12582912 (0xC00000), exponent ey = 1

Align: mx × 2^(ex-ey) = 10485760 × 4 = 41943040
Integer division: 41943040 = 3 × 12582912 + 4194304
fmod significand: 4194304 → fmod = 1.0 = fmod(10.0, 3.0) ✓
```

The aligned integer can be wide — for `float`, the unpacked fraction is 24 bits (23 fraction bits plus the hidden bit), and the code uses a conservative bound of `2^8 = 256` for the maximum exponent shift, giving an integer width of `256 + 24 + 2 = 282` bits.
For `double` it's 2,103 bits.
Constructing the integer divider circuit is straightforward (it's combinational logic), though the resulting SAT formula can require minutes to hours for the solver to resolve at large bit widths.

The result satisfies `|r| < |my| < 2^(f+1)`, so it fits exactly in the format — no rounding needed.

After integer fmod, `|fmod/y| < 1`, so the FMA-based correction (computing IEEE `remainder` from `fmod`) works without overflow.

Here's the complete algorithm in pseudocode:

```
function remainder(x, y):
    // Step 0: Special cases
    if x is NaN or y is NaN or x is ±∞ or y is ±0: return NaN
    if x is ±0: return x
    if y is ±∞: return x

    // Step 1: Integer fmod
    (mx, ex) = unpack(x)          // significand and exponent
    (my, ey) = unpack(y)
    r_int = (mx << (ex-ey)) mod my  // integer remainder (aligned)
    fmod = pack(r_int, ey, sign(x)) // exact, no rounding needed

    // Step 2: FMA-based remainder correction
    n = round_to_nearest(fmod / y)  // n ∈ {-1, 0, 1}
    r0 = fma(-n, y, fmod)           // exact if n is correct
    r1 = fma(-(n+1), y, fmod)       // try n+1
    r2 = fma(-(n-1), y, fmod)       // try n-1
    return candidate with smallest |result|
```

CVC5 proved the combined algorithm correct for all inputs on small formats.

## The proof that passed — and the assumption that didn't hold

The human wasn't satisfied with CVC5's proof on small formats — it doesn't guarantee correctness for `float` or `double`.
At the human's suggestion, Kiro wrote a Coq proof using the [Flocq](https://flocq.gitlabpages.inria.fr/) library, which provides a formalization of IEEE 754 floating-point arithmetic in Coq, including rounding, representability, and error bounds.

The proof compiled with zero `Admitted` (Coq's escape hatch for skipping proofs — we used none).
The key theorems:

- **`remainder_format`**: The IEEE remainder `x - n×y` is exactly representable when `|x - n×y| ≤ |y|/2`.
- **`fma_remainder_exact`**: Therefore FMA returns the exact value — no rounding error.
- **`comparison_step`**: The wrong candidate (`n±1`) always has strictly larger `|result|`, so minimum-selection picks the correct one.

The proof was clean, the theorems were strong, and everything type-checked.

But the proof had made an assumption: that the tentative quotient `n` (computed via float division + rounding) is within 1 of the correct value.
This is true *after* the integer fmod step (because `|fmod/y| < 1`), but the original FMA-only algorithm didn't have that step.

Here's a concrete example of the assumption failing.
In `_Float16` (maximum value 65,504): with `x = 100.0` and `y = 0.001`, the exact quotient exceeds 65,504 (since `0.001` rounds in `_Float16`, the quotient is approximately 100,055).
`_Float16` division overflows to infinity, and `round_to_nearest(∞)` is not within 1 of the correct integer.

CBMC's symbolic verification on `_Float16` exposed exactly this class of inputs, even though the Coq proof "passed."
The proof proved the right thing about the wrong algorithm.

**This is the critical lesson: a proof is only as good as its assumptions, and verification is a good way to validate assumptions.**
After adding the integer fmod step and revising the proof to cover the full composition (`fmod_then_remainder`), both the proof and the verification agreed.

## The clever part of the proof: rounding preserves the comparison

The trickiest theorem deserves attention.
The wrong candidate `r_wrong = r_correct ± y` may not be representable (its mantissa can exceed `2^p`), so FMA rounds it.
We need `|round(r_wrong)| ≥ |r_correct|` — rounding doesn't flip the ordering.

The idea: find a representable value close enough to `r_wrong` that rounding can't possibly land as low as `|r_correct|`.

Kiro's proof avoids ulp (unit in the last place) analysis entirely.
Instead, it uses Flocq's `round_N_pt` — the property that rounding picks the nearest representable value — with carefully chosen witnesses.

For the **same-sign case** (`r` and `y` same sign), `|r+y| = |r| + |y|`.
Using `y` as the representable witness: since `y` is at distance `|r|` from `r+y`, rounding can't move `r+y` by more than `|r|`.
So `|round(r+y)| ≥ |r+y| - |r| = |y| > |r|`. ✓

For the **opposite-sign case**, `|r+y| = |y| - |r|`.
Using `-r` as the representable witness: `-r` is at distance `|2r+y| = |y| - 2|r|` from `r+y`.
So `|round(r+y)| ≥ (|y| - |r|) - (|y| - 2|r|) = |r|`. ✓

No ulp analysis, no case splits on exponent ranges — just the nearest-point property and the triangle inequality.

### Independent verification in HOL Light

The same core theorems were proved independently in HOL Light.
A careful review caught a real soundness issue: the original formalization defined the floating-point format with natural-number exponents, which meant theorems like `REMAINDER_FORMAT` were vacuously true for any value requiring a negative exponent — including `0.5 = 1 × 2^(-1)`.
The proofs type-checked and appeared correct, but they were proving properties about a mathematical object that couldn't represent most floats.
Switching to integer exponents fixed this.
This is precisely why independent verification in a different proof assistant adds value.

## Symbolic verification on `_Float16`

The `_Float16` format (5-bit exponent, 10-bit significand) is small enough for CBMC to symbolically encode all possible input values, but large enough to exercise every code path in the algorithm.

Three property checks, each completing in about 3 seconds:

```c
// |remainder(x,y)| <= |y|/2 for ALL finite _Float16 inputs
_Float16 r = __CPROVER_remainderf16(x, y);
assert(r == (_Float16)0.0 || abs_r <= abs_y / (_Float16)2.0);

// |fmod(x,y)| < |y| for ALL finite inputs
_Float16 r = __CPROVER_fmodf16(x, y);
assert(r == (_Float16)0.0 || abs_r < abs_y);

// fmod(inf, y) = NaN for ALL y
_Float16 r1 = __CPROVER_fmodf16(pos_inf, y);
assert(r1 != r1);  // NaN is the only float not equal to itself
```

Beyond catching the assumption gap in the proof, these checks found a special-case bug: `fmod(0, 0)` returned `0` instead of NaN because the code checked `x == 0` before `y == 0`.
The proofs, which focus on the algorithm for normal inputs, didn't cover special-case ordering.

| Approach | Variables | Clauses | Time | Correct? |
|----------|-----------|---------|------|----------|
| Extended precision (+3 fraction bits) | 12,937 | 52,835 | 0.06s | **No** |
| FMA-only (no integer fmod) | 14,879 | 61,797 | 0.25s | **No** |
| Integer fmod + FMA | 16,461 | 70,497 | 3.34s | **Yes** |

## Keeping proofs and implementation in sync

We have a three-way sync mechanism:

1. **CI workflow**: compiles Coq proofs (zero admits), runs HOL Light proofs (zero `mk_thm`), runs `_Float16` symbolic verification — triggered on any change to float implementation or proof files.
The full CI check completes in under 5 minutes.

2. **Cross-reference comments** mapping each proof theorem to its corresponding verification check.

3. **`_Float16` property checks** that catch implementation regressions independently of the proofs.

## What's next

The integer significand approach works well for `float` (282-bit divider) and `double` (2,103-bit divider), but `long double` (15-bit exponent) creates a 32,834-bit divider — the resulting SAT formula is extremely expensive to solve.

A natural next step is to extend this proof work to cover all operations of a fully symbolic floating-point unit.
[SymFPU](https://github.com/martin-cs/symfpu) is a C++ library that provides bit-precise floating-point semantics and serves as the floating-point backend for SMT solvers like CVC5 and Bitwuzla.
Proving SymFPU's algorithms correct — using the same AI-assisted pattern of Coq proofs, independent HOL Light verification, and symbolic verification on small formats — would establish a verified foundation for floating-point reasoning across the entire SMT ecosystem.

## The bigger picture: proving algorithms in any codebase

The most important takeaway isn't about floating-point arithmetic.
It's that **AI makes it practical to formally verify algorithms in existing codebases**, regardless of the implementation language.

Before this work, proving CBMC's remainder algorithm correct would have required someone who simultaneously understood IEEE 754 bit-level semantics, CBMC's C++ solver internals, Coq's Flocq library, and HOL Light's type system.
That combination of expertise is extraordinarily rare.
The AI serves as a universal translator between these domains — reading C++ bit manipulation, writing Coq real analysis, generating SMT-LIB2 quantified formulas, and maintaining the correspondence between all three formalisms.

But the AI isn't infallible.
Its proof sketch had bugs that SMT solvers caught.
Its proof made an assumption that symbolic verification disproved.
Its implementation had a special-case ordering bug.
The value isn't that the AI gets everything right — it's that the AI gets you to a *testable, provable* state fast enough that the bugs can be found and fixed.

The pattern generalizes:

1. **AI writes both implementation and proof** in the same session, ensuring they describe the same algorithm.
2. **Proofs are mechanized** in a standard proof assistant — the AI handles the translation between implementation language and proof language.
3. **Symbolic verification on small types** validates the proof's assumptions against the actual implementation.
4. **CI enforces the link** — proof compilation and property checks run on every change.

We believe this pattern would apply to cryptographic libraries with complex arithmetic, signal processing code with fixed-point invariants, numeric solvers with convergence guarantees — any codebase with algorithms that *should* be proved correct but *aren't* because the implementation language isn't Lean or Coq.

## Conclusion

A 2.5-year-old soundness issue in CBMC's floating-point solver — affecting Kani users since August 2023 — has been fixed with a formally verified algorithm.

- **25 commits**, ~2500 lines of C++ across 20 files
- **~530 lines** of Coq proofs, 10 theorems, zero admits
- **~280 lines** of HOL Light proofs, 9 theorems, zero `mk_thm`
- **3 symbolic `_Float16` property checks**, ~3 seconds each
- **2 bugs found by SMT solvers** in the AI's proof sketch
- **1 wrong assumption** in the proof, caught by symbolic verification
- **1 special-case bug** caught by `_Float16` verification

The [CBMC pull request](https://github.com/diffblue/cbmc/pull/7885) is open for review.
The proofs, tests, and CI workflow are all included.

The barrier to formal verification of production code just got a lot lower.
