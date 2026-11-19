---
title: "What Can Kani Verify in Your Rust Crate? From the Rust Standard Library to Your Own Project"
layout: post
---
Authors: [Aryan Arun](https://github.com/acearyanarun), [Srivatsan Samraj](https://github.com/srivatsansamraj), [Yanjun Chen](https://github.com/CYJ904), [Tianshu Huang](https://github.com/Tianshu-Huang), [Jieyou Zhao](https://github.com/wodex1nhaoIeng)

Consider this small Rust function:

```rust
pub fn first_char(s: &str) -> &str {
    if s.is_empty() { "" } else { &s[..1] }
}
```

`first_char("hello")` returns `"h"`, and `first_char("")` returns `""`. Both look fine. But `first_char("é")` panics: `é` takes two bytes in UTF-8, and `&s[..1]` cuts it in half.

A unit test could catch this, but only if someone thought to include a string that starts with a multibyte character. Kani can check string inputs up to a chosen size and find the same problem. With `cargo kani autoharness -Z autoharness`, it attempts to generate proof harnesses for functions in your crate. For functions that take strings, such as `first_char`, the `--bounded-arguments` flag lets it generate strings up to a size limit.

We tried this approach on the Rust standard library, which contains roughly 41,000 functions. We wanted to see how far AutoHarness could get without writing a separate proof harness for each function.

Kani generated 26,726 proof harnesses, and 15,535 of those verified successfully. For those harnesses, Kani's checks found no panics, overflows, or supported forms of undefined behavior over the inputs the harness could generate. A harness for a generic function covers one concrete instantiation, such as `ptr::read::<i32>`.

The remaining results took more work to understand. More than 4,500 failures came from `unsafe` functions, and many involved requirements written in documentation rather than as machine-checkable preconditions, such as a pointer needing to be non-null. Another 14,489 functions were skipped, with a reason recorded for each one.

We'll look at what these different results mean, then walk through a small crate you can try yourself.

## Proofs without writing proofs

[Kani](https://model-checking.github.io/kani/) is a model checker for Rust. A unit test runs a function on inputs you choose. Kani analyzes the inputs represented by a proof harness and reports whether its checks hold or whether it found an input that breaks one. Those checks include panics, arithmetic overflow, out-of-bounds accesses, and many kinds of undefined behavior in `unsafe` code.

To verify a function, Kani normally needs a *proof harness*, a small function that creates arbitrary inputs and calls the code under test:

```rust
#[kani::proof]
fn check_estimate_size() {
    let x: u32 = kani::any(); // stands for every possible u32
    estimate_size(x);
}
```

Many harnesses follow this pattern. AutoHarness generates them automatically for functions whose arguments it knows how to construct, then runs verification without changing the source code:

```
cargo kani autoharness -Z autoharness
```

If a function has a [function contract](https://model-checking.github.io/kani/reference/experimental/contracts.html), AutoHarness verifies the contract instead. At the end, Kani reports the result for each selected function and lists skipped functions with their reasons. AutoHarness is still experimental, so it requires `-Z autoharness`. The [AutoHarness chapter of the Kani Book](https://model-checking.github.io/kani/reference/experimental/autoharness.html) covers the available options.

This gives us an initial picture of what Kani can check automatically and where we still need to write harnesses or improve the tooling.

## Case study: the Rust standard library

The [Verify Rust Std Lib](https://github.com/model-checking/verify-rust-std) project is a community effort to verify the Rust standard library through contributed proofs, verification challenges, and CI. The standard library is a difficult target for automatic harness generation. It is large, makes extensive use of generics, and contains a significant amount of `unsafe` code.

### How the results were collected

The project's scripts run AutoHarness on the whole library using `kani autoharness -Z autoharness --std ./library`, along with the unstable features needed for the library's contracts (`scripts/run-kani.sh --run autoharness`). This includes `core`, `alloc`, `std`, and dependencies such as `compiler_builtins`, `hashbrown` and `libc`.

A parser reads the verification log and records a result for each generated harness. The [dashboard](https://wodex1nhaoIeng.github.io/autoharness-dashboard/) tracks the totals across runs. Each harness receives one of four verdicts:

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

Most of the harnesses that finished did so quickly. The median verification time was 0.06 seconds, and 90% finished in under 0.6 seconds. Those times describe the completed harnesses; they do not tell us why the others failed or stopped.

The results also vary by function type. The project's analysis tool classifies functions as *safe*, *unsafe*, or *safe abstractions*. A safe abstraction is a safe function that uses `unsafe` code internally:

| Function kind    | Harnesses | Verified | Failed | Timed out | Error |
|------------------|----------:|---------:|-------:|----------:|------:|
| Safe             | 14,982    | 67.8%    | 28.7%  | 3.3%      | 0.2%  |
| Safe abstraction | 1,328     | 71.2%    | 20.6%  | 4.7%      | 3.4%  |
| Unsafe           | 5,573     | 16.5%    | 81.8%  | 1.6%      | 0.1%  |

(The tool could not classify the remaining 4,843 harnesses; about half of them are instantiations of generic functions.)

In this run, more than two thirds of the harnesses for safe functions and safe abstractions verified. More than four out of five harnesses for unsafe functions failed. That does not mean the underlying `unsafe` code is broken. Consider these three functions:

| Function           | Verdict  | Failed checks |
|--------------------|----------|--------------:|
| `ptr::read::<i32>`  | Failed   | 2             |
| `ptr::write::<i32>` | Failed   | 2             |
| `ptr::read_volatile` | Verified | 0             |

The signature of `ptr::read` accepts any `*const T`, so AutoHarness passes it null, out-of-bounds, and valid pointers. `ptr::read` dereferences the null and out-of-bounds pointers, and Kani reports each case. Those failures are correct: the function really does exhibit undefined behavior for those inputs. Its documentation forbids them, but documentation is not something a tool can check.

`ptr::read_volatile` has the same requirement, yet it verified. The difference is that the Verify Rust Std Lib project has already written that requirement down as a precondition, `#[safety::requires(ub_checks::can_dereference(src))]`, so AutoHarness checks it only for valid pointers. The [section on failures](#failure-a-question-not-a-verdict) shows how to do the same for your own functions.

The run also included:

- **Generic code.** 6,526 harnesses check a concrete instantiation of a generic function, such as `ptr::read::<i32>`. AutoHarness chooses the type itself, and 4,824 of them (74%) verified.
- **Formatting.** 1,130 harnesses check `Debug` or `Display` implementations, which handwritten harnesses rarely cover. 901 of them verified.
- **Small, total functions.** Functions such as `char::len_utf8` and `time::Duration::from_secs` verify outright. Their result holds for every input.

There are still functions that AutoHarness cannot handle automatically, including those with unsupported argument types or inputs that require bounds. Other harnesses are too expensive to verify within the time limit. The next section looks at these cases using smaller examples.

## How to read the results

An AutoHarness run answers two different questions for each function:

1. Can AutoHarness prepare this function for verification?
2. If verification runs, can Kani establish the properties being checked?

A skipped function never reaches verification. A generated harness does, but that does not mean it passes. It may verify, fail, time out, or end in an error. Keeping those stages separate makes the results much easier to interpret.

For the examples below, we used Kani built from `main` at commit [`cfa7932`](https://github.com/model-checking/kani/commit/cfa793237). We have shortened the output to the relevant lines.

### Success: what is proved, and for which inputs

A success means no check failed for the inputs generated by that harness. It does not mean the function, much less the entire crate, is correct in every sense. To understand the result, look at three things.

**Which properties.** AutoHarness checks the properties Kani checks by default, including panics from failed `assert!`s or `unwrap()` on `None`, arithmetic overflow, out-of-bounds accesses, and undefined behavior in `unsafe` code. Kani does not know what a function is supposed to return. A function could return the wrong answer and still verify unless its intended behavior is expressed as an assertion or a [contract](https://model-checking.github.io/kani/reference/experimental/contracts.html).

**Which instantiation.** For a generic function, AutoHarness chooses one concrete type that satisfies its trait bounds. It verifies that instantiation, not every possible version of the function. Consider:

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

**Which inputs.** For many supported argument types, including integers, `bool`, `char`, `Box`, `Rc`, `Arc`, `Vec`, and slices of numbers, the harness considers the possible values represented by its input model. Loops over a long `Vec` or slice are still subject to the loop-unwinding bound. Other types are limited to values up to a size bound or values that pass a filter. The summary marks these results `(bounded)` or `(ctor)`.

References and pointers passed as separate arguments never alias each other. The [soundness caveats](https://model-checking.github.io/kani/reference/experimental/autoharness.html#soundness-caveats) section of the Kani Book explains these restrictions.

For example, `&str` has no finite set of possible values. AutoHarness can generate strings up to a size bound, but you have to enable that behavior. A bug that needs a longer input could otherwise be missed. By default, AutoHarness skips our earlier `first_char` example and reports the reason:

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

The check fails because `&s[..1]` panics when byte 1 is not a character boundary, as with a string starting with `"é"`. Tests using only ASCII strings would miss this case. Kani prints the placeholder text because it does not yet support panic messages formatted at run time. Slicing at the end of the first character fixes the bug:

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

The success applies to strings up to 4 bytes long, as the `(bounded)` marker indicates. Kani prints the bounds used in each run. You can increase them with `--string-bound`, `--slice-bound` and `--bounded-arbitrary-bound`, though verification may take longer.

### Failure: a question, not a verdict

When Kani reports a failed check, the first question is whether the failing input is one the function is supposed to handle. The examples below show three different situations.

**1. A real bug.** `first_char` is one. Here is another, a `Display` implementation that divides by a field that can be zero:

```rust
use std::fmt;
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

We did not write a harness for `Ratio`, and the type has no methods of its own. AutoHarness still found its `Display` implementation and reported `attempt to divide by zero`:

```text
Failed Checks: attempt to divide by zero
 File: "src/lib.rs", line 10, in <Ratio as std::fmt::Display>::fmt

| Crate    | Selected Function                 | Kind of Automatic Harness | Verification Result |
| my_crate | <Ratio as std::fmt::Display>::fmt | #[kani::proof]            | Failure             |
```

**2. A rule that only the documentation states.** This is what happened with `ptr::read` in the standard library. The function requires a valid pointer, but that requirement has to be expressed as a precondition for Kani to use it. For a similar function, the precondition takes one line:

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

With the precondition, Kani checks the function only for valid pointers, and verification succeeds. The requirement is now part of the contract, so a caller verified against it must also prove that it passes a valid pointer.

The same approach works for functions that panic on purpose. For example, `char::to_digit` requires a radix between 2 and 36. A precondition such as `#[kani::requires((2..=36).contains(&radix))]` lets Kani verify the function within that range.

Contracts require `-Z function-contracts`, and memory predicates such as `kani::mem::can_dereference` also require `-Z mem-predicates`. See the [`kani::mem` documentation](https://model-checking.github.io/kani/crates/doc/kani/mem/index.html).

**3. An input that can never happen.** If a type has no `Arbitrary` implementation, AutoHarness may construct it by assigning values to its fields independently. That can produce values the program would never normally create. Consider a month type where the number should always be between 1 and 12:

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

AutoHarness tries `Month { number: 0 }`, and `Month::days` fails with an overflow and an out-of-bounds index. But `Month::new` rejects that value, and code outside the module cannot construct it directly. To express this restriction, we can:

- write the rule as a [`kani::Invariant`](https://model-checking.github.io/kani/crates/doc/kani/trait.Invariant.html), a three-line `is_safe` method that returns `(1..=12).contains(&self.number)`;
- or write nothing, and run with `--constructor-args`, which makes AutoHarness create every `Month` through `Month::new`.

Both approaches allow `Month::days` to verify. With `--constructor-args`, the result is marked `(ctor)` because the proof covers values produced by `Month::new`. It is a narrower claim than verifying every possible field value.

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

`--constructor-args` also assumes conditions that a type asserts about its fields in at least two of its methods. Because both mechanisms may rule out values that are in fact valid, they are opt-in, and the results they affect are marked `(ctor)`.

**What if a filter rejects every input?** A filter that rejects everything can make a function unreachable during verification. That would not be a useful proof. AutoHarness checks for this case. Here, a typo in the constructor rejects every value:

```rust
pub struct Percent {
    value: u8, // meant to be in 0..=100
}

impl Percent {
    pub fn new(value: u8) -> Option<Percent> {
        if value <= 100 && value > 100 { Some(Percent { value }) } else { None }
    }

    pub fn complement(&self) -> u8 {
        100 - self.value
    }
}
```

With `--constructor-args`, no `Percent` value can be created. AutoHarness reports `Percent::complement` as a failure rather than treating the unreachable call as a successful proof:

```text
Vacuous harness: no generated input reaches `my_crate::Percent::complement`

| Crate    | Selected Function   | Kind of Automatic Harness | Verification Result |
| my_crate | Percent::new        | #[kani::proof]            | Success             |
| my_crate | Percent::complement | #[kani::proof] (ctor)     | Failure             |
```

`Percent::new` still verifies because it has no check that can fail. The vacuity check on `Percent::complement` is what reveals the problem.

### Timeout or error: no answer yet

A timeout means Kani did not finish within the available time. It does not mean the function is wrong. AutoHarness uses a default limit of 60 seconds per harness, and a timed-out harness can appear as a `Failure` in the summary. Check the log before treating that result as a bug. Kani also prints a reminder about the timeout and loop-unwinding limits when a harness fails.

In the standard library run, 3.6% of harnesses timed out, including cases such as `ptr::swap_nonoverlapping`. You can increase the time limit with `--harness-timeout` or adjust loop unwinding with `--default-unwind`. If the unwind limit is too low, Kani reports that rather than silently stopping early. For a function you particularly care about, another option is to write a smaller, more focused harness.

An error also leaves the result unresolved. Kani or CBMC may stop before producing a verdict, for example after running out of memory. This happened to 103 harnesses in the standard library run. Rerunning one of those harnesses separately, perhaps with more memory, may help.

### Skipped: not tried

A skipped function did not reach verification because AutoHarness could not generate a suitable harness for it. About 14,500 standard library functions were skipped. The table below shows the reasons reported for those functions:

| Reason for skipping            | Functions | Share | What you can do |
|--------------------------------|----------:|------:|-----------------|
| Missing `Arbitrary`            | 6,806     | 47.0% | implement `kani::Arbitrary` for the argument type, or for the field that blocks automatic derivation |
| Generic: no candidate type     | 3,696     | 25.5% | write a harness for the types you use |
| Non-`usize` const generic      | 1,581     | 10.9% | write a harness by hand |
| Requires bounded arguments     | 1,379     | 9.5%  | rerun with `--bounded-arguments` |
| Generic: search limit reached  | 680       | 4.7%  | write a harness for the types you use |
| No function body               | 178       | 1.2%  | nothing to verify, as for compiler intrinsics |
| Const block on a const generic | 122       | 0.8%  | write a harness by hand |
| Compile-time only              | 49        | 0.3%  | nothing to verify at run time |

These counts come from the 2026-10-27 listing run (Kani `cd355b0bc`, verify-rust-std [#737](https://github.com/model-checking/verify-rust-std/pull/737), without `--bounded-arguments`). That run reported 14,491 skipped functions, compared with 14,489 in the 2026-11-16 run.

AutoHarness reports the first skip reason it encounters, so a function may have additional limitations. We used this breakdown to identify recurring problems and organize them into [GitHub issues](https://github.com/model-checking/kani/issues/4879). Several have already been fixed.

These functions were not verified, but the skip reasons show where AutoHarness still needs work.

## Try it on your own crate

To see how this works on a smaller project, we'll use a color-parsing crate with four functions. The examples include a successful proof, a string-handling bug, an overflow that needs a precondition, and a formatting implementation.

The output below comes from a November 2026 development build of Kani from `main`, which reports version 0.68.0. The published 0.68.0 release available through `cargo install` dates from September 2026 and does not include some features used here, such as the vacuity check and `--string-bound`. Your results may differ with that release. To reproduce the examples exactly, [build Kani from source](https://model-checking.github.io/kani/build-from-source.html).

Install Kani and create the crate:

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

The first run gives us three results without writing any proof harnesses:

- `Rgb::luminance` and the `Display` implementation verify for every possible color.
- `Rgb::mix` fails with an overflow, because nothing stops a caller from passing a `weight` above 100, and then `100 - w` goes below zero.
- `Rgb::from_short_hex` is skipped, because it takes a `&str`.

### Step 2: state the precondition

The intended range for `weight` is `0..=100`. We can express that as a contract so Kani verifies the function for valid weights. The rule also applies to callers verified against the contract, for example through `#[kani::stub_verified(Rgb::mix)]`: they must prove that they pass a valid weight.

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

The four-byte bound is enough to include `"#aé"`. It has three bytes after the `#`, but only two characters. The slice `digits[1..2]` cuts `é` in half and panics, just as it did in `first_char`.

We can fix this by iterating over characters instead of indexing by byte. The revised code also uses `char::to_digit` from the standard library:

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

These runs found a missing precondition and a Unicode bug without a handwritten harness. There are limits to the results, though. The parser was checked only for strings up to 4 bytes, and the proofs do not establish that the colors returned are *correct*. That would require assertions or postconditions describing the expected outputs.

## Where to go from here

To try AutoHarness on your own crate, start with `cargo kani autoharness -Z autoharness`. Read the skip table first to see which functions were not attempted. Then examine failed checks to distinguish bugs from missing preconditions or inputs that should not occur. Finally, look for `(bounded)` and `(ctor)` markers so you know what each successful result covers.

The [AutoHarness chapter of the Kani Book](https://model-checking.github.io/kani/reference/experimental/autoharness.html) documents the options. The [Verify Rust Std Lib](https://github.com/model-checking/verify-rust-std) project also welcomes contributions that turn automated results into verified contracts. If AutoHarness skips a function you think it should support, or reports a failure you cannot explain, [open an issue](https://github.com/model-checking/kani/issues).
