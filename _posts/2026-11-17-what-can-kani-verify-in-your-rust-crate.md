---
title: "What Can Kani Verify in Your Rust Crate? From the Rust Standard Library to Your Own Project"
layout: post
---

Here is a function that will pass every unit test you are likely to write for it:

```rust
pub fn first_char(s: &str) -> &str {
    if s.is_empty() { "" } else { &s[..1] }
}
```

`first_char("hello")` returns `"h"`. `first_char("")` returns `""`. `first_char("é")` crashes your program, because `é` takes two bytes in UTF-8 and `&s[..1]` cuts it in half.

You would catch this only if you thought of testing a string that starts with an accented letter. Kani does not need to think of it. Instead of running a few inputs that you pick, it checks every string up to a given size at once, and it finds `"é"` by itself. You do not even need to write the test: one command, `cargo kani autoharness`, tries every function in your crate. (For functions that take strings, such as `first_char`, you add one flag, `--bounded-arguments`, which lets Kani generate strings up to a size limit.)

So we asked a bigger question. What happens if we run that one command on the Rust standard library, the code that every Rust program depends on? That is about 41,000 functions, with no test code written by hand.

Kani generated 26,726 proof harnesses for them, and 15,535 of those verified: for every input Kani could generate, the code never panics, overflows, or triggers any of the kinds of undefined behavior that Kani checks for. (For a generic function, a harness covers one concrete version of it, such as `ptr::read::<i32>`.) The surprises were in the rest. More than 4,500 failures came from `unsafe` functions, and most of them are not bugs at all: they are promises that the standard library makes only in its comments, such as "this pointer must not be null", which no tool can read. Another 14,489 functions were never checked, and for each one Kani says why.

This post explains what those results mean for your own code: what Kani can verify automatically, how to tell a real bug from a false alarm, and how to try it on your own crate in five minutes.

## Proofs without writing proofs

[Kani](https://model-checking.github.io/kani/) is a model checker for Rust. A unit test runs a function on a few inputs that you choose. Kani considers *every* input of a given type at once, and reports either that a check holds for all of them or a concrete input that breaks it. The checks include panics, arithmetic overflow, out-of-bounds accesses, and many kinds of undefined behavior in `unsafe` code.

To verify a function, Kani normally needs a *proof harness*, a small function that creates arbitrary inputs and calls the code under test:

```rust
#[kani::proof]
fn check_estimate_size() {
    let x: u32 = kani::any(); // stands for every possible u32
    estimate_size(x);
}
```

Most harnesses follow this pattern. AutoHarness writes them for you. It inspects each function in a crate, generates a harness for each function whose arguments it knows how to construct, and verifies them all, without any change to the source code:

```
cargo kani autoharness -Z autoharness
```

If a function has a [function contract](https://model-checking.github.io/kani/reference/experimental/contracts.html), AutoHarness verifies the contract instead. At the end of the run, Kani prints one row per function with its result, and lists every function it skipped together with the reason. AutoHarness is still experimental, which is why it requires `-Z autoharness`. The [AutoHarness chapter of the Kani Book](https://model-checking.github.io/kani/reference/experimental/autoharness.html) describes every option.

Because the setup cost is a single command, AutoHarness changes the first question from "which functions are worth writing a harness for?" to "what does Kani find when it tries all of them?"

## Case study: the Rust standard library

The [Verify Rust Std Lib](https://github.com/model-checking/verify-rust-std) project is a community effort to verify the Rust standard library, with challenges, contributed proofs, and CI that runs Kani on every change. It is a demanding test for automatic harness generation: the library is large, it is generic almost everywhere, and much of it is `unsafe`.

### How the results were collected

The project's scripts run AutoHarness on the whole library with `kani autoharness -Z autoharness --std ./library`. The "library" here is everything the toolchain builds: `core`, `alloc`, `std`, and the crates they depend on, such as `compiler_builtins`, `hashbrown` and `libc`. A parser in the repository reads the verification log and records one entry per generated harness, and a [dashboard](https://wodex1nhaoIeng.github.io/autoharness-dashboard/) tracks the totals from run to run. Each harness receives one of four verdicts:

- **verified**: every check succeeded;
- **failed**: at least one check failed;
- **timed out**: the solver did not finish within the time limit;
- **error**: Kani or CBMC stopped before reaching a verdict, for example because it ran out of memory.

The numbers below come from the run of 2026-11-16, with Kani built from `main` at commit [`0aac16ef6`](https://github.com/model-checking/kani/commit/0aac16ef6) and the library of verify-rust-std as of [#638](https://github.com/model-checking/verify-rust-std/pull/638), which is synced to `nightly-2026-10-23`, on `x86_64-unknown-linux-gnu`.

### What the numbers say

Of about 41,000 functions, AutoHarness generated harnesses for 26,726 and skipped 14,489. Every generated harness produced a verdict:

| Verdict   | Harnesses | Share |
|-----------|----------:|------:|
| Verified  | 15,535    | 58.1% |
| Failed    | 10,114    | 37.8% |
| Timed out | 974       | 3.6%  |
| Error     | 103       | 0.4%  |

Most harnesses are fast: the median one finishes in 0.06 seconds and 90% finish in under 0.6 seconds. In other words, checking twenty-seven thousand functions costs machine time, not engineering time.

The verdicts change sharply with the kind of function. The project's analysis tool classifies each function as *safe*, *unsafe*, or a *safe abstraction*, meaning a safe function that contains `unsafe` code internally:

| Function kind    | Harnesses | Verified | Failed | Timed out |
|------------------|----------:|---------:|-------:|----------:|
| Safe             | 14,982    | 67.8%    | 28.7%  | 3.3%      |
| Safe abstraction | 1,328     | 71.2%    | 20.6%  | 4.7%      |
| Unsafe           | 5,573     | 16.5%    | 81.8%  | 1.6%      |

(4,843 harnesses, mostly instantiated generic functions, are not classified.)

Safe functions, and safe wrappers around `unsafe` code, verify more than two thirds of the time. Unsafe functions fail more than four times out of five. That does not mean that the standard library's `unsafe` code is broken. Take `ptr::read` and two of its neighbors in the same run:

| Function           | Verdict  | Failed checks |
|--------------------|----------|--------------:|
| `ptr::read::<i32>`  | Failed   | 2             |
| `ptr::write::<i32>` | Failed   | 2             |
| `ptr::read_volatile` | Verified | 0             |

The signature of `ptr::read` accepts any `*const T`, so AutoHarness passes it null, dangling, and valid pointers. `ptr::read` dereferences the null and dangling pointers, and Kani reports each case. Those failures are correct: the function really does exhibit undefined behavior for those inputs. Its documentation forbids them, but documentation is not something a tool can check. The [section on failures](#failure-a-question-not-a-verdict) shows how to turn such a requirement into a precondition that Kani verifies.

Other parts of the library show what the automation already covers:

- **Generic code.** 6,526 harnesses verify a concrete instantiation of a generic function, such as `ptr::read::<i32>`. AutoHarness chooses the type itself, and 4,824 of them (74%) verified.
- **Formatting.** 746 harnesses verify `Debug` or `Display` implementations, which handwritten harnesses rarely cover. 599 of them verified.
- **Small, total functions.** Functions such as `char::len_utf8` and `time::Duration::from_secs` verify outright. Their result holds for every input.

The standard library also shows where AutoHarness reaches its limits: functions whose argument types it cannot construct, inputs whose size has no natural bound, and functions whose state space is too large to explore within the time limit. The rest of this post explains how to recognize each case and what to do about it, using small examples that you can reproduce.

## How to read the results

An AutoHarness run answers two different questions for each function:

1. Can AutoHarness prepare this function for verification?
2. If verification runs, can Kani establish the properties being checked?

A skipped function is a "no" to the first question. Success, failure, and timeout are the three answers to the second. Counting generated harnesses answers the first question only, so keep the two apart when you read the results. Each of the four states tells you something different, and each suggests a different next step. The small examples in this section were run with Kani built from `main` at commit [`cfa7932`](https://github.com/model-checking/kani/commit/cfa793237), and their output is shortened to the relevant lines.

### Success: what is proved, and for which inputs

A success means that no check failed for any input that the harness generates. It does not mean that the function, or the crate, is correct in every sense. Three details determine what a success covers.

**Which properties.** AutoHarness checks what Kani checks by default: panics, including failed `assert!`s and `unwrap()` on `None`, arithmetic overflow, out-of-bounds accesses, and undefined behavior in `unsafe` code. It does not know what the function is meant to compute. A function that returns the wrong answer without panicking still verifies, unless you state the intended behavior as an assertion or a [contract](https://model-checking.github.io/kani/reference/experimental/contracts.html).

**Which instantiation.** For a generic function, AutoHarness picks one concrete type that satisfies the trait bounds and verifies only that instantiation. For

```rust
fn foo<T: Eq>(x: T, y: T) {
    if x == y {
        panic!("x and y are equal");
    }
}
```

AutoHarness verifies `foo::<i32>`. The summary table reports the instantiated name rather than `foo`, because the result says nothing about `foo::<String>`:

```text
| Crate    | Selected Function | Kind of Automatic Harness | Verification Result |
| my_crate | foo::<i32>        | #[kani::proof]            | Failure             |
```

**Which inputs.** For most argument types, including integers, `bool`, `char`, `Box`, `Rc`, `Arc`, `Vec`, and slices of numbers, the harness covers every possible value. For some types, it covers only values up to a size bound, or only values that pass a filter. The summary table marks those results `(bounded)` or `(ctor)`, as described below. Raw pointers passed as separate arguments are never generated to alias each other. The [soundness caveats](https://model-checking.github.io/kani/reference/experimental/autoharness.html#soundness-caveats) section of the Kani Book lists every such restriction.

The `(bounded)` marker deserves an example. Some types, such as `&str`, have no finite set of values, so a harness cannot cover them all. AutoHarness can generate them up to a size bound, but only when you ask for it, because a bug that needs a larger input would go undetected. The following function is meant to return the first character of a string:

```rust
pub fn first_char(s: &str) -> &str {
    if s.is_empty() { "" } else { &s[..1] }
}
```

By default, AutoHarness skips it and says what is missing:

```text
| Crate    | Skipped Function | Reason for Skipping                                  |
| my_crate | first_char       | Requires --bounded-arguments for argument(s) s: &str |
```

With `--bounded-arguments`, the harness covers every valid UTF-8 string of up to 4 bytes, and it fails inside the string slicing code of `core`:

```text
Failed Checks: This is a placeholder message; Kani doesn't support message formatted at runtime
 File: ".../library/core/src/str/traits.rs", line 459, in core::str::traits::<impl std::slice::SliceIndex<str> for std::ops::RangeTo<usize>>::index

| Crate    | Selected Function | Kind of Automatic Harness | Verification Result |
| my_crate | first_char        | #[kani::proof] (bounded)  | Failure             |
```

The failing check is the panic that `&s[..1]` raises when byte 1 is not a character boundary, which is the case for any string that starts with a multi-byte character such as `"é"`. A unit test written with ASCII input would not reach this case. (Kani does not yet support panic messages formatted at run time, hence the placeholder text.) Slicing at the end of the first character fixes the bug:

```rust
pub fn first_char(s: &str) -> &str {
    match s.char_indices().nth(1) {
        Some((end, _)) => &s[..end],
        None => s,
    }
}
```

```text
| Crate    | Selected Function | Kind of Automatic Harness | Verification Result |
| my_crate | first_char        | #[kani::proof] (bounded)  | Success             |
```

This success holds for strings of up to 4 bytes, and the `(bounded)` marker says so. Kani prints the bounds used in each run, and `--string-bound`, `--slice-bound` and `--bounded-arbitrary-bound` raise them, at the cost of longer verification times.

### Failure: a question, not a verdict

Every failure comes with a concrete input that breaks a check. The question is whether your program could ever receive that input. In practice, the answer puts each failure into one of three cases.

**1. A real bug.** `first_char` is one. Here is another, a `Display` implementation that divides by a field that can be zero:

```rust
pub struct Ratio {
    pub num: u32,
    pub den: u32,
}

impl fmt::Display for Ratio {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.num / self.den)
    }
}
```

Nobody asked Kani to look at this code, and the crate contains no other function. AutoHarness found the `Display` implementation by itself and reported `attempt to divide by zero`.

```text
Failed Checks: attempt to divide by zero
 File: "src/lib.rs", line 10, in <Ratio as std::fmt::Display>::fmt

| Crate    | Selected Function                 | Kind of Automatic Harness | Verification Result |
| my_crate | <Ratio as std::fmt::Display>::fmt | #[kani::proof]            | Failure             |
```

**2. A rule that only the documentation states.** This is the `ptr::read` case from the standard library: the function is fine, as long as the caller passes a valid pointer. The fix is to write the rule where Kani can read it, as a precondition. For a function like `ptr::read`, it is one line:

```rust
#[cfg_attr(kani, kani::requires(kani::mem::can_dereference(ptr)))]
pub unsafe fn read_first(ptr: *const u32) -> u32 {
    unsafe { *ptr }
}
```

Without the `requires` line, Kani reports a null dereference and an out-of-bounds dereference:

```text
Failed Checks: null pointer dereference occurred
 File: "src/lib.rs", line 2, in read_first
Failed Checks: dereference failure: pointer outside object bounds
 File: "src/lib.rs", line 2, in read_first
```

With it, Kani checks the function only for valid pointers, and verification succeeds. As a bonus, the rule is no longer just a comment: any caller that is verified against this contract must prove that it passes a valid pointer. The same idea works for functions that panic on purpose, such as `char::to_digit`, which panics unless its radix is between 2 and 36: a precondition such as `#[kani::requires((2..=36).contains(&radix))]` turns that failure into a success.

Memory predicates such as `kani::mem::can_dereference` require `-Z mem-predicates`. See the [`kani::mem` documentation](https://model-checking.github.io/kani/crates/doc/kani/mem/index.html).

**3. An input that can never happen.** AutoHarness builds a value of your type by picking each field at random, and that can produce values that your code never creates. Here is a month type whose number is always between 1 and 12:

```rust
pub struct Month {
    number: u8, // always in 1..=12
}

impl Month {
    pub fn new(number: u8) -> Option<Month> {
        if (1..=12).contains(&number) { Some(Month { number }) } else { None }
    }

    pub fn days(&self) -> u8 {
        const DAYS: [u8; 12] = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
        DAYS[(self.number - 1) as usize]
    }
}
```

AutoHarness tries `Month { number: 0 }`, and `Month::days` fails with an overflow and an out-of-bounds index. But no one outside this module can create that value, because `Month::new` rejects it. This is a false alarm, and there are two ways to tell Kani about the rule:

- write the rule as a [`kani::Invariant`](https://model-checking.github.io/kani/crates/doc/kani/trait.Invariant.html), a three-line `is_safe` method that returns `(1..=12).contains(&self.number)`;
- or write nothing, and run with `--constructor-args`, which makes AutoHarness create every `Month` through `Month::new`.

Either way, `Month::days` verifies. With `--constructor-args`, the result is marked `(ctor)`: it holds for the months that `Month::new` can produce, which is exactly what you want here, but it is a narrower claim, and the marker reminds you of that.

Without either fix:

```text
Failed Checks: attempt to subtract with overflow
 File: "src/lib.rs", line 12, in Month::days
Failed Checks: index out of bounds: the length is less than or equal to the given index
 File: "src/lib.rs", line 12, in Month::days
```

With the invariant:

```rust
#[cfg(kani)]
impl kani::Invariant for Month {
    fn is_safe(&self) -> bool {
        (1..=12).contains(&self.number)
    }
}
```

```text
| Crate    | Selected Function | Kind of Automatic Harness | Verification Result |
| my_crate | Month::days       | #[kani::proof]            | Success             |
| my_crate | Month::new        | #[kani::proof]            | Success             |
```

With `cargo kani autoharness -Z autoharness --constructor-args`:

```text
| Crate    | Selected Function | Kind of Automatic Harness | Verification Result |
| my_crate | Month::days       | #[kani::proof] (ctor)     | Success             |
| my_crate | Month::new        | #[kani::proof]            | Success             |
```

`--constructor-args` also assumes conditions that a type asserts about its fields in at least two of its methods. Because both mechanisms may rule out values that are in fact valid, they are opt-in, and the results they affect are always marked `(ctor)`.

**Watch out for filters that let nothing through.** Filtering inputs has one trap: if the filter rejects *every* input, the function is never really called, so it cannot fail, and a "success" would mean nothing. AutoHarness catches this. In the type below, a typo makes the constructor reject every value:

```rust
impl Percent {
    pub fn new(value: u8) -> Option<Percent> {
        if value <= 100 && value > 100 { Some(Percent { value }) } else { None }
    }

    pub fn complement(&self) -> u8 {
        100 - self.value
    }
}
```

Under `--constructor-args`, no `Percent` can ever be created, so AutoHarness reports `Percent::complement` as a failure instead of a hollow success:

```text
Vacuous harness: no generated input reaches `my_crate::Percent::complement`

| Crate    | Selected Function   | Kind of Automatic Harness | Verification Result |
| my_crate | Percent::new        | #[kani::proof]            | Success             |
| my_crate | Percent::complement | #[kani::proof] (ctor)     | Failure             |
```

`Percent::new` itself verifies, because it contains no check that can fail. It is the vacuity check on `Percent::complement` that exposes the typo.

### Timeout or error: no answer yet

A timeout means Kani ran out of time, not that it found a problem. In the standard library, 3.6% of harnesses timed out, mostly on functions with big loops or big inputs, such as `ptr::swap_nonoverlapping`. You can give Kani more time (`--harness-timeout`), limit how many times loops are unrolled (`--default-unwind`; if that limit is too low, Kani says so instead of silently stopping early), or write a harness by hand with smaller inputs for the functions you care about most. An error is just as inconclusive: Kani or CBMC stopped before reaching a verdict, for example because it ran out of memory. That happened to 103 harnesses in the standard library run. Rerunning such a harness on its own, or on a machine with more memory, may produce an answer.

### Skipped: not tried

A skipped function was never checked at all: AutoHarness did not know how to call it, and the skip table tells you why. About 14,500 standard library functions were skipped, and four reasons cover more than 90% of them:

| Reason for skipping                        | Share | What you can do |
|--------------------------------------------|------:|-----------------|
| Missing `Arbitrary` for an argument type   | 47%   | add `#[derive(kani::Arbitrary)]` to the type |
| Generic function with no suitable type     | 30%   | write a harness for the types you use |
| Const generic of a type other than `usize` | 11%   | write a harness by hand |
| Needs `--bounded-arguments`                | 10%   | rerun with that flag |

These shares come from the baseline analysis of 2026-10-27, which covers 14,491 skipped functions. The remaining few percent are functions without a Rust body, such as compiler intrinsics, and a few rarer cases. AutoHarness reports only the first reason it finds, so a function may have more than one. Grouping skips by reason is also how the team decides what to improve next: the recurring reasons are [tracked as issues](https://github.com/model-checking/kani/issues/4879), and several have already been fixed.

The complete breakdown of the baseline analysis:

| Reason for skipping            | Functions | Share |
|--------------------------------|----------:|------:|
| Missing `Arbitrary`            | 6,806     | 47.0% |
| Generic: no candidate type     | 3,696     | 25.5% |
| Non-`usize` const generic      | 1,581     | 10.9% |
| Requires bounded arguments     | 1,379     | 9.5%  |
| Generic: search limit reached  | 680       | 4.7%  |
| No function body               | 178       | 1.2%  |
| Const block on a const generic | 122       | 0.8%  |
| Compile-time only              | 49        | 0.3%  |

A skipped function is not a failed proof. It is a clue about what the verification workflow needs next.

## Try it on your own crate

This section runs AutoHarness on a small color-parsing crate. Its four functions cover the cases above: a function that verifies, a real bug that only bounded strings reveal, an overflow that a precondition resolves, and a formatting implementation.

Install Kani, then create the crate. (The output below was produced with Kani 0.68.0 built from `main` in November 2026. AutoHarness is under active development, so an older release may print different results.)

```
cargo install --locked kani-verifier
cargo kani setup
cargo new --lib tinycolor
```

Replace `src/lib.rs` with the following:

```rust
use std::fmt;

/// An sRGB color.
pub struct Rgb {
    pub r: u8,
    pub g: u8,
    pub b: u8,
}

impl Rgb {
    /// Parses the short CSS form `#rgb`, so that `#f0a` becomes `#ff00aa`.
    pub fn from_short_hex(s: &str) -> Option<Rgb> {
        let digits = s.strip_prefix('#')?;
        if digits.len() != 3 {
            return None;
        }
        let channel = |i: usize| u8::from_str_radix(&digits[i..i + 1], 16).ok().map(|v| v * 17);
        Some(Rgb { r: channel(0)?, g: channel(1)?, b: channel(2)? })
    }

    /// Mixes `self` with `other`, where `weight` is the percentage of `self`.
    pub fn mix(&self, other: &Rgb, weight: u8) -> Rgb {
        let w = weight as u16;
        let channel = |a: u8, b: u8| ((a as u16 * w + b as u16 * (100 - w)) / 100) as u8;
        Rgb { r: channel(self.r, other.r), g: channel(self.g, other.g), b: channel(self.b, other.b) }
    }

    /// Relative luminance in 0..=255 (ITU-R BT.709 weights).
    pub fn luminance(&self) -> u8 {
        ((self.r as u32 * 2126 + self.g as u32 * 7152 + self.b as u32 * 722) / 10_000) as u8
    }
}

impl fmt::Display for Rgb {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "#{:02x}{:02x}{:02x}", self.r, self.g, self.b)
    }
}
```

### Step 1: the default run

```
cargo kani autoharness -Z autoharness
```

```text
| Crate     | Skipped Function    | Reason for Skipping                                  |
| tinycolor | Rgb::from_short_hex | Requires --bounded-arguments for argument(s) s: &str |

Failed Checks: attempt to subtract with overflow
 File: "src/lib.rs", line 24, in Rgb::mix::{closure#0}

| Crate     | Selected Function               | Kind of Automatic Harness | Verification Result |
| tinycolor | <Rgb as std::fmt::Display>::fmt | #[kani::proof]            | Success             |
| tinycolor | Rgb::luminance                  | #[kani::proof]            | Success             |
| tinycolor | Rgb::mix                        | #[kani::proof]            | Failure             |
```

In one run, without writing anything:

- `Rgb::luminance` and the `Display` implementation verify for every possible color.
- `Rgb::mix` fails with an overflow, because nothing stops a caller from passing a `weight` above 100, and then `100 - w` goes below zero.
- `Rgb::from_short_hex` is skipped, because it takes a `&str`.

### Step 2: state the precondition

The intended domain of `weight` is `0..=100`. Stating it as a contract turns the failure into a proof for every valid weight. It also documents the rule in a form Kani checks: a caller verified with this contract, for example through `#[kani::stub_verified(Rgb::mix)]`, must prove that it passes a valid weight.

```rust
#[cfg_attr(kani, kani::requires(weight <= 100))]
pub fn mix(&self, other: &Rgb, weight: u8) -> Rgb {
```

Contracts are still unstable, so rerun with `-Z function-contracts`:

```
cargo kani autoharness -Z autoharness -Z function-contracts
```

AutoHarness now verifies the contract of `mix` instead of the function alone:

```text
| Crate     | Selected Function | Kind of Automatic Harness   | Verification Result |
| tinycolor | Rgb::mix          | #[kani::proof_for_contract] | Success             |
```

### Step 3: verify the parser on bounded strings

```
cargo kani autoharness -Z autoharness -Z function-contracts --bounded-arguments
```

```text
Failed Checks: This is a placeholder message; Kani doesn't support message formatted at runtime
 File: ".../library/core/src/str/traits.rs", line 337, in core::str::traits::<impl std::slice::SliceIndex<str> for std::range::Range<usize>>::index

| Crate     | Selected Function   | Kind of Automatic Harness | Verification Result |
| tinycolor | Rgb::from_short_hex | #[kani::proof] (bounded)  | Failure             |
```

Strings of up to 4 bytes are enough to hold `#`, followed by three bytes. Among them is `"#aé"`, which has three bytes after the `#` but only two characters. `digits[1..2]` then cuts `é` in half and panics, as `first_char` did. Iterating over characters fixes the bug, and also reuses `char::to_digit` from the standard library:

```rust
pub fn from_short_hex(s: &str) -> Option<Rgb> {
    let mut digits = s.strip_prefix('#')?.chars();
    let mut channel = || digits.next()?.to_digit(16).map(|v| v as u8 * 17);
    let rgb = Rgb { r: channel()?, g: channel()?, b: channel()? };
    if digits.next().is_some() { None } else { Some(rgb) }
}
```

Rerun the same command, and every function verifies:

```text
| Crate     | Selected Function               | Kind of Automatic Harness   | Verification Result |
| tinycolor | <Rgb as std::fmt::Display>::fmt | #[kani::proof]              | Success             |
| tinycolor | Rgb::from_short_hex             | #[kani::proof] (bounded)    | Success             |
| tinycolor | Rgb::luminance                  | #[kani::proof]              | Success             |
| tinycolor | Rgb::mix                        | #[kani::proof_for_contract] | Success             |

Complete - 4 successfully verified functions, 0 failures, 4 total.
```

In four short runs, without writing a harness, you found an undocumented precondition and a Unicode bug that ASCII test cases would miss. Just as important is what these results do not say: the parser is verified only for strings of up to 4 bytes, and nothing here checks that the colors are *correct*. For that, add assertions or postconditions about what each function should return.

## Where to go from here

Run `cargo kani autoharness -Z autoharness` on your own crate, and read the results in this order: the skip table, to see what was not attempted and why; the failures, to sort real bugs from missing preconditions and impossible inputs; and the `(bounded)` and `(ctor)` markers, to see what each success covers. The [AutoHarness chapter of the Kani Book](https://model-checking.github.io/kani/reference/experimental/autoharness.html) documents every option, and the [Verify Rust Std Lib](https://github.com/model-checking/verify-rust-std) project welcomes contributions that turn automatic results into verified contracts. If AutoHarness skips a function that you think it should handle, or reports a failure that you cannot explain, please [open an issue](https://github.com/model-checking/kani/issues).
