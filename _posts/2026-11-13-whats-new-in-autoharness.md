---
title: "What's New in AutoHarness"
layout: post
---

AutoHarness generates a proof harness for a function only when it can construct every argument of that function. Until recently, this requirement excluded generic functions, raw pointers, `Box`, `&str`, closures and a wide range of other types, and many functions were skipped.

Since August 2026, a series of changes on Kani's `main` branch has removed many of these restrictions. This post describes the capabilities that AutoHarness has gained over this period. It does not repeat the reference documentation: the [AutoHarness chapter of the Kani Book](https://model-checking.github.io/kani/reference/experimental/autoharness.html) describes every option and limitation, and the [project page]({{ "/projects/autoharness/" | relative_url }}) describes the motivation and goals of the feature. The output shown in this post was produced with Kani built from `main` at commit [`cfa7932`](https://github.com/model-checking/kani/commit/cfa793237), and has been shortened to the relevant lines.

## Background

Many proof harnesses follow the same pattern: they create an arbitrary value for each argument and then call the function under verification.

```rust
#[kani::proof]
fn check_estimate_size() {
    let x: u32 = kani::any();
    estimate_size(x);
}
```

AutoHarness generates such harnesses automatically, without modifying the source code:

```
cargo kani autoharness -Z autoharness
```

If a function has a [function contract](https://model-checking.github.io/kani/reference/experimental/contracts.html), AutoHarness verifies the contract instead. At the end of a run, Kani reports the verification result of each selected function, and lists each skipped function together with the reason it was skipped.

## Generic functions

Generic functions were previously skipped. AutoHarness now selects one concrete instantiation that satisfies the function's trait bounds and verifies that instantiation ([#4679](https://github.com/model-checking/kani/pull/4679)). For example, for the function

```rust
fn foo<T: Eq>(x: T, y: T) {
    if x == y {
        panic!("x and y are equal");
    }
}
```

AutoHarness verifies `foo::<i32>` and reports the instantiated name in the summary table:

```text
| Crate    | Selected Function | Kind of Automatic Harness | Verification Result |
| my_crate | foo::<i32>        | #[kani::proof]            | Failure             |
```

AutoHarness first tries a fixed set of primitive types for all type parameters. If none of them is suitable, it searches combinations of types for individual parameters, including types that implement the traits named in the bounds ([#4706](https://github.com/model-checking/kani/pull/4706)). As a final attempt, it substitutes `()` ([#4880](https://github.com/model-checking/kani/pull/4880)). Type parameters bounded by `Fn`, `FnMut` or `FnOnce` are instantiated with a function that returns an arbitrary value on each call ([#4726](https://github.com/model-checking/kani/pull/4726)).

Only the selected instantiation is verified. A successful result for `foo::<i32>` does not imply that `foo::<String>` is also correct, which is why the summary table reports the instantiated name rather than `foo`.

## Raw pointers

AutoHarness now generates raw pointer arguments ([#4678](https://github.com/model-checking/kani/pull/4678)), which makes it applicable to functions that take raw pointers. Each generated pointer is either null, out of bounds of its allocation, or valid and pointing to an arbitrary value. Consider the following function:

```rust
pub unsafe fn read_first(ptr: *const u32) -> u32 {
    unsafe { *ptr }
}
```

The generated harness fails with two violations, one for each invalid pointer state:

```text
Failed Checks: null pointer dereference occurred
 File: "src/lib.rs", line 2, in read_first
Failed Checks: dereference failure: pointer outside object bounds
 File: "src/lib.rs", line 2, in read_first
```

This result is correct: the signature of the function excludes neither a null pointer nor an out-of-bounds one. In practice, such a requirement is usually stated only in the `# Safety` section of the documentation. Expressing it as a precondition with one of Kani's [memory predicates](https://model-checking.github.io/kani/crates/doc/kani/mem/index.html) (which require `-Z mem-predicates`) makes it checkable:

```rust
#[cfg_attr(kani, kani::requires(kani::mem::can_dereference(ptr)))]
pub unsafe fn read_first(ptr: *const u32) -> u32 {
    unsafe { *ptr }
}
```

With this precondition, AutoHarness verifies the contract of `read_first` instead, and verification succeeds.

## Additional argument types

The following argument types are now supported without any additional options:

- `Box<T>`, `Rc<T>` and `Arc<T>`, constructed around an arbitrary value ([#4698](https://github.com/model-checking/kani/pull/4698));
- `&[T]`, `&mut [T]` and `Vec<T>` with integer or floating-point elements, without a length bound ([#4721](https://github.com/model-checking/kani/pull/4721));
- integer pattern types, which recent nightly toolchains use in place of the former layout-range attributes ([#4780](https://github.com/model-checking/kani/pull/4780)).

The Kani library also provides new `Arbitrary` implementations for the `char` and ASCII escape iterators ([#4784](https://github.com/model-checking/kani/pull/4784), [#4782](https://github.com/model-checking/kani/pull/4782)). Functions that take these types as arguments are now eligible for automatic harnesses.

## Formatting trait implementations

AutoHarness now verifies the `fmt` methods of `Debug`, `Display` and the other formatting traits ([#4701](https://github.com/model-checking/kani/pull/4701), [#4802](https://github.com/model-checking/kani/pull/4802)). The generated harness formats an arbitrary value of the implementing type into a sink that discards the output, so that panics and undefined behavior in the `fmt` implementation are reported as failures. For example, the `Display` implementation below divides one field by another:

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

`Ratio` has no `Arbitrary` implementation, so AutoHarness synthesizes one from its fields. The crate contains no other functions, yet AutoHarness still selects the `Display` implementation and reports the division by zero:

```text
Failed Checks: attempt to divide by zero
 File: "src/lib.rs", line 10, in <Ratio as std::fmt::Display>::fmt

| Crate    | Selected Function                 | Kind of Automatic Harness | Verification Result |
| my_crate | <Ratio as std::fmt::Display>::fmt | #[kani::proof]            | Failure             |
```

Formatting implementations are rarely covered by handwritten harnesses, so this support extends verification to code that is otherwise seldom checked.

## Bounded arguments

Some types, such as `&str` or slices of structs, cannot be generated symbolically without a size limit. For these types, AutoHarness provides bounded generators that are enabled with a separate option ([#4691](https://github.com/model-checking/kani/pull/4691), [#4693](https://github.com/model-checking/kani/pull/4693)):

```
cargo kani autoharness -Z autoharness --bounded-arguments
```

The bounded generators are disabled by default, because a bug that requires a larger input would not be detected. Without the option, the table of skipped functions identifies the functions that the option would make eligible, with the reason `Requires --bounded-arguments`.

When the option is enabled, AutoHarness can generate slices of up to 16 elements, strings of up to 4 bytes, values of any type that implements [`BoundedArbitrary`](https://model-checking.github.io/kani/reference/bounded_arbitrary.html), which now includes `BTreeMap` and `BTreeSet` ([#4626](https://github.com/model-checking/kani/pull/4626)), and several standard library types: `&CStr` ([#4804](https://github.com/model-checking/kani/pull/4804)), `&ByteStr` ([#4806](https://github.com/model-checking/kani/pull/4806)), `&Wtf8` ([#4809](https://github.com/model-checking/kani/pull/4809), [#4862](https://github.com/model-checking/kani/pull/4862)), `&Formatter` ([#4824](https://github.com/model-checking/kani/pull/4824)) and the `char` pattern searchers ([#5064](https://github.com/model-checking/kani/pull/5064)). The bounds can be configured with `--slice-bound`, `--string-bound` and `--bounded-arbitrary-bound` ([#4793](https://github.com/model-checking/kani/pull/4793)). Results that depend on bounded values are marked `(bounded)` in the summary table, and Kani reports the bounds used in the run.

The following function is intended to return the first character of a string:

```rust
pub fn first_char(s: &str) -> &str {
    if s.is_empty() { "" } else { &s[..1] }
}
```

Without `--bounded-arguments`, AutoHarness skips it and states what is missing:

```text
| Crate    | Skipped Function | Reason for Skipping                                  |
| my_crate | first_char       | Requires --bounded-arguments for argument(s) s: &str |
```

With the option, the harness fails inside the string slicing code of `core`:

```text
Failed Checks: This is a placeholder message; Kani doesn't support message formatted at runtime
 File: ".../library/core/src/str/traits.rs", line 459, in core::str::traits::<impl std::slice::SliceIndex<str> for std::ops::RangeTo<usize>>::index

| Crate    | Selected Function | Kind of Automatic Harness | Verification Result |
| my_crate | first_char        | #[kani::proof] (bounded)  | Failure             |
```

The failing check is the panic that `&s[..1]` raises when byte 1 is not a character boundary, which is the case for any string that starts with a multi-byte character such as `"é"`. Because the bounded string generator covers all valid UTF-8 up to the bound, it reaches this case, which unit tests written with ASCII input would not. (The panic message itself is formatted at run time, which Kani does not yet support, hence the placeholder text.) Slicing at the end of the first character instead fixes the bug:

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

As the `(bounded)` marker indicates, this result holds only for strings of up to 4 bytes. A larger bound can be set with `--string-bound`.

## Fewer spurious failures

### Where spurious failures come from

When a type has no `Arbitrary` implementation, AutoHarness synthesizes its values field by field, choosing an arbitrary value for each field. Real code, however, usually creates values only through a few functions that enforce certain rules, so field-by-field construction can produce values that never occur in practice. A failure caused by such a value is spurious: it does not indicate a real problem. Take, as an illustration, a month type that keeps its number in `1..=12`:

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

AutoHarness synthesizes `Month` by choosing an arbitrary `u8` for `number`, and `Month::days` fails:

```text
Failed Checks: attempt to subtract with overflow
 File: "src/lib.rs", line 12, in Month::days
Failed Checks: index out of bounds: the length is less than or equal to the given index
 File: "src/lib.rs", line 12, in Month::days
```

Both failures are spurious: they require `number` to be `0` or greater than `12`, and the only way to create a `Month` outside the module is `Month::new`, which rejects such values.

### Improvements enabled by default

Two changes prevent some spurious failures without requiring any option. First, if a type implements [`kani::Invariant`](https://model-checking.github.io/kani/crates/doc/kani/trait.Invariant.html), generated values of that type are assumed to satisfy its invariant ([#4677](https://github.com/model-checking/kani/pull/4677)). Second, when AutoHarness constructs a value field by field, it respects the valid range that the compiler records for each field; for example, a field whose type only admits `1..=12` is never assigned `0` ([#4716](https://github.com/model-checking/kani/pull/4716)).

For `Month`, the rule is enforced only by the code of `Month::new`, so the type of `number` does not help. The rule can, however, be stated as an invariant:

```rust
#[cfg(kani)]
impl kani::Invariant for Month {
    fn is_safe(&self) -> bool {
        (1..=12).contains(&self.number)
    }
}
```

With this implementation, AutoHarness only generates months that satisfy the invariant, and both functions verify without any additional option:

```text
| Crate    | Selected Function | Kind of Automatic Harness | Verification Result |
| my_crate | Month::days       | #[kani::proof]            | Success             |
| my_crate | Month::new        | #[kani::proof]            | Success             |
```

### Constructor-based generation and vacuity checks

Writing an invariant requires additional code for each type. The `--constructor-args` option offers an alternative that requires none: it constructs values through the type's own constructors instead of field by field ([#4717](https://github.com/model-checking/kani/pull/4717)). For `Month`, it calls `Month::new` with an arbitrary argument and assumes that the result is `Some`, so that only valid months are generated:

```
cargo kani autoharness -Z autoharness --constructor-args
```

```text
| Crate    | Selected Function | Kind of Automatic Harness | Verification Result |
| my_crate | Month::days       | #[kani::proof] (ctor)     | Success             |
| my_crate | Month::new        | #[kani::proof]            | Success             |
```

The same option also identifies conditions that a type asserts about its fields in at least two of its methods, and assumes these conditions for generated values ([#4718](https://github.com/model-checking/kani/pull/4718), [#4722](https://github.com/model-checking/kani/pull/4722), [#5087](https://github.com/model-checking/kani/pull/5087)). Because both mechanisms may exclude values that are in fact valid, they are opt-in, and the affected results are marked `(ctor)`.

Filtering inputs in this way introduces a risk of its own: if every input is filtered out, no input reaches the function under verification, and the harness cannot fail. AutoHarness now detects this situation and reports such a harness as a failure rather than a success ([#4978](https://github.com/model-checking/kani/pull/4978)). The constructor of the type below contains a mistake that makes its condition unsatisfiable:

```rust
pub struct Percent {
    value: u8, // always in 0..=100
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

Under `--constructor-args`, every value of `Percent` is built through `Percent::new`, which never returns `Some`. No input therefore reaches `Percent::complement`, and without the new check its harness would succeed trivially. AutoHarness instead reports:

```text
Vacuous harness: no generated input reaches `my_crate::Percent::complement`

| Crate    | Selected Function   | Kind of Automatic Harness | Verification Result |
| my_crate | Percent::new        | #[kani::proof]            | Success             |
| my_crate | Percent::complement | #[kani::proof] (ctor)     | Failure             |
```

Note that `Percent::new` itself verifies successfully, because it contains no check that can fail. The vacuity check on `Percent::complement` is what reveals the mistake.

## Limitations

AutoHarness remains an experimental feature, and its results are subject to the following limitations. A successful result covers only one instantiation of a generic function. Distinct pointer arguments never alias each other. Results marked `(bounded)` or `(ctor)` hold only for the values that the corresponding generators produce. The [soundness caveats](https://model-checking.github.io/kani/reference/experimental/autoharness.html#soundness-caveats) section of the Kani Book provides the complete list.
