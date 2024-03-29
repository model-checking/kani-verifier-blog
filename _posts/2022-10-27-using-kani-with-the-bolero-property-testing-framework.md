---
layout: post
title: "From Fuzzing to Proof: Using Kani with the Bolero Property-Testing Framework"
---

Today we're going to talk about how you can use fuzzing and verification in a unified framework, which is enabled by the integration of the [Kani Rust Verifier](https://model-checking.github.io/kani/) in [Bolero](https://camshaft.github.io/bolero/).
Bolero is a property-testing framework that makes it easy for users to test a piece of Rust code with multiple fuzzing engines, and Kani is a verification tool that allows users to prove certain properties about their Rust code.
By integrating Kani in Bolero, we enable users to apply multiple testing methods, namely fuzzing and proofs, to the same harness.

## Why Bolero?

Suppose we want to test a function `update_account_balance` that takes the current balance and the amount we want to deposit or withdraw, and returns the new balance:

```rust
fn update_account_balance(current_balance: i32, amount: i32) -> i32 {
    // compute the new balance ...
}
```

A [property-based test](https://medium.com/criteo-engineering/introduction-to-property-based-testing-f5236229d237) harness would look as follows:

```rust
#[test]
fn test_update_account_balance() {
    let current_balance = /* some value */;
    let amount = /* some value */;
    let new_balance = update_account_balance(current_balance, amount);
    assert!(balance_update_is_correct(current_balance, amount, new_balance));
}
```
where `balance_update_is_correct` checks that the transaction was carried out correctly, and may include other properties as well, for example that no overflow occurred, there was enough balance for a withdrawal, etc.

The question then is: how do we generate values for `current_balance` and `amount` for this property-based test harness?
The answer depends on the testing technique we want to use.
For example, if we were to use *random testing*, we would inject random values for `current_balance` and `amount`.
If we do so using the [rand](https://rust-random.github.io/rand/rand/index.html) crate, the harness would be as follows:

```rust
fn test_update_account_balance_random() {
    let current_balance = rand::random();
    let amount = rand::random();
    let result = update_account_balance(current_balance, amount);
    assert!(balance_update_is_correct(current_balance, amount, result));
}
```

We can then either repeatedly call the program to test it with different values, or call this function inside a loop.

This form of random testing typically has limited effectiveness.
We can improve the effectiveness of our randomized testing with grey-box fuzzers, which use metrics such as [code coverage](https://en.wikipedia.org/wiki/Code_coverage) to trigger unique behavior.
There are a number of fuzzing engines for Rust, such as [libFuzzer](https://github.com/rust-fuzz/libfuzzer) and [AFL](https://github.com/rust-fuzz/afl.rs), that use different heuristics/metrics for exploring the input space.

To use libFuzzer, we would write a harness that looks as follows:

```rust
libfuzzer_sys::fuzz_target!(|(current_balance: i32, amount: i32)| {
    let result = update_account_balance(current_balance, amount);
    assert!(balance_update_is_correct(current_balance, amount, result));
}
```

When we run the fuzzer (e.g. using `cargo fuzz`), it will repeatedly call the body of the macro with values generated by libFuzzer.

If we were to use the [AFL](https://github.com/rust-fuzz/afl.rs) fuzzer instead, the harness would be in terms of AFL's `fuzz!` macro:

```rust
afl::fuzz!(|(current_balance: i32, amount: i32)| {
    let result = update_account_balance(current_balance, amount);
    assert!(balance_update_is_correct(current_balance, amount, result));
}
```

What if we want to apply *all* the testing techniques described above to leverage their unique strengths?
In this case, we end up having to write multiple harnesses in our code to test the same function.
In addition, in order to run those harnesses, we would need a number of different commands, e.g. `cargo test` for running the random test, `cargo fuzz` to run the `libfuzzer` test, and `cargo afl` to run the AFL test!
This quickly goes out of hand and becomes difficult to manage.
This is where Bolero comes to the rescue!

The key idea of Bolero is to allow using multiple test engines on the *same* test harness.
For example, to test function `update_account_balance`, one can write a Bolero harness that looks like the following:

```rust
#[test]
fn test_update_account_balance_bolero() {
    bolero::check!().with_type::<(i32, i32)>().cloned().for_each(|(current_balance, amount)| {
        let result = update_account_balance(current_balance, amount);
        assert!(balance_update_is_correct(current_balance, amount, result));
    });
}
```

Let's break this up a bit to understand what it's doing.
First, the harness calls the [`check`](https://docs.rs/bolero/0.8.0/bolero/macro.check.html) macro, which is Bolero's main API for creating a test target.
The test target can be configured to generate values of specific types via the `with_type` method.
In our case, we configure it to generate a pair of `i32`'s.
Next, `cloned` clones the generated values, and the `for_each` method calls the supplied closure for each generated value.
In the case above, the closure passes the values on to `update_account_balance` and `balance_update_is_correct`.

So, what is the benefit of writing a Bolero harness?
Bolero allows us to apply all the previous testing techniques on this same harness!
To understand how, let's look at Bolero's main CLI command:

```bash
$ cargo bolero test --help
cargo-bolero-test 0.8.0
Run an engine for a target

USAGE:
    cargo-bolero test [FLAGS] [OPTIONS] <test>
<snip>
    -e, --engine <engine>   Run the test with a specific engine [default: libfuzzer]
```

We can find the list of engines that Bolero supports in its [documentation](https://camshaft.github.io/bolero/features/unified-interface.html): `libfuzzer`, `afl`, and `honggfuzz`.
With this command, selecting a particular testing technique just becomes a matter of specifying the engine to Bolero's `cargo bolero test` command!
For example, we can run AFL on the harness above using:

```
cargo bolero test test_update_account_balance_bolero --engine afl
```

Bolero then takes care of all the details of calling that engine's APIs under the hood to generate values, and executing that engine's fuzzer!
Neat!
In addition, Bolero allows us to apply random testing on a harness.
We can do so by executing the Bolero harness with `cargo test`.

## Adding Proofs to the Mix with Kani!

Suppose we would like to verify the same function `update_account_balance` with Kani.
In this case, we would write a proof harness similar to the ones we wrote above, but we would assign `current_balance` and `amount` to [`kani::any`](https://model-checking.github.io/kani/tutorial-nondeterministic-variables.html):

```rust
#[cfg(kani)]
#[kani::proof]
fn test_update_account_balance_kani() {
    let current_balance = kani::any();
    let amount = kani::any();
    let result = update_account_balance(current_balance, amount);
    assert!(balance_update_is_correct(current_balance, amount, result));
}
```

We can then run `cargo kani` to check the harness[^footnote-kani].
But wouldn't it be nice if we can instead re-use the Bolero harness that we wrote above?
This is where Kani's integration in Bolero comes to play!

Running Kani on a Bolero harness is as simple as invoking `cargo bolero test` with `--engine kani`!

To see how this can be used, let's look at an example of applying fuzzing and Kani through Bolero!

## Example

Suppose we'd like to test the following function, `nth_rev`, which, given a slice and an index, returns the `nth` element from the *end* of that slice if the given index is in range, and otherwise `None`:

```rust
fn nth_rev(arr: &[i32], index: usize) -> Option<i32> {
    if index < arr.len() {
        let rev_index = arr.len() - index /* - 1 */;
        return Some(arr[rev_index]);
    }
    None
}
```

The function contains a classical off-by-one bug, as it misses subtracting one from the "reverse" index.
Let's write a Bolero harness to test it:

```rust
const N: usize = 5;

#[test]
#[cfg_attr(kani, kani::proof)]
fn check_rev() {
    bolero::check!()
        .with_type::<([i32; N], usize)>()
        .cloned()
        .for_each(|(arr, index)| {
            let x = nth_rev(&arr, index);
            if index < arr.len() {
                assert!(x.is_some());
            }
        });
}
```

Notice this line:

```rust
#[cfg_attr(kani, kani::proof)]
```

whose purpose is to treat this function as a proof harness when run with Kani, but treat it as an ordinary test otherwise.

The Bolero harness generates arrays of length `N` (set to 5 in this example), and an index, calls `nth_rev`, and checks that it returns `Some` if the index it received was less than the array length.

Let's first test this with fuzzing using Bolero's default engine (`libfuzzer`)[^footnote-dev-dep]:

```bash
$ cargo bolero test check_rev
# snip ...
test failed; shrinking input...

======================== Test Failure ========================

Input: 
(
    [
        0,
        0,
        0,
        0,
        0,
    ],
    0,
)

Error: 
panicked at 'index out of bounds: the len is 5 but the index is 5', src/main.rs:6:21
```

The fuzzing engine found an input that causes the expected out-of-bounds error: an array of 5 zeros and an index of zero. 

Let's see if Kani finds the same issue:

```bash
$ cargo bolero test check_rev --engine kani
# snip ...
SUMMARY:
 ** 1 of 337 failed (1 unreachable)
Failed Checks: index out of bounds: the length is less than or equal to the given index
 File: "/home/ubuntu/examples/demos/rev-bolero/src/main.rs", line 6, in nth_rev
```

It did! Now, let's fix the bug by updating the buggy line to:

```rust
        let rev_index = arr.len() - index - 1;
```

and re-run the fuzzer:

```
$ cargo bolero test check_rev
# snip ...
#3773   REDUCE cov: 135 ft: 138 corp: 18/282b lim: 52 exec/s: 0 rss: 43Mb L: 8/32 MS: 3 ChangeByte-ChangeBinInt-EraseBytes-
#262144 pulse  cov: 135 ft: 138 corp: 18/282b lim: 2620 exec/s: 131072 rss: 68Mb
#524288 pulse  cov: 135 ft: 138 corp: 18/282b lim: 4096 exec/s: 131072 rss: 93Mb
#1048576        pulse  cov: 135 ft: 138 corp: 18/282b lim: 4096 exec/s: 116508 rss: 142Mb
```

The fuzzer will run for a while without finding any failures. We can now run Kani to *prove* the assertion in our harness:

```
$ cargo bolero test check_rev --engine kani
# snip ...
SUMMARY:
 ** 0 of 338 failed (1 unreachable)

VERIFICATION:- SUCCESSFUL
Verification Time: 0.90419155s
```

and voila! Kani managed to prove that none of the checks can fail for any values of the inputs.

## If we have proof capability, do we still need fuzzing?

One question that might arise is: is there any point in using fuzzing alongside Kani?
In other words, if we can prove a harness for all inputs with Kani, would we still want to use fuzzing?
The answer is yes, because fuzzing and Kani provide complementary benefits.

Kani verifies a Rust program by symbolically analyzing its code.
This allows Kani to make mathematical statements about the expected semantics of the Rust code being verified.
Kani allows you to prove that, **for all possible inputs**, the code under verification follows its specification, **assuming everything else functions correctly** (e.g. the underlying hardware, the OS, etc.).

Fuzzing concretely executes the program under test.
This gives you end-to-end confidence that **for the set of inputs generated by the fuzzer**, the code under verification follows its specification, **under real-world conditions**.
Fuzzing and Kani fit together to give more assurance than either provides on its own.

## How is Kani integrated in Bolero?

For those that are curious, let's briefly discuss how the `kani` engine is implemented.
At a high-level, Bolero redirects value generation to `kani::any()`, and calls `cargo kani` under the hood when `cargo bolero test` is invoked with the `kani` engine.
Also, the `for_each` function only iterates once in the `kani` mode, since `kani::any()` covers all possible values of an input.

Some of the generation capabilities of Bolero require a little more than just calling `kani::any()`.
For instance, Bolero supports generating values in a restricted range `[min, max)`, e.g.

```rust
bolero::check!().with_generator(5..37).for_each( // snip... );
```

To support those in the Kani mode, Bolero leverages assumptions ([`kani::assume`](https://model-checking.github.io/kani/tutorial-first-steps.html#assertions-assumptions-and-harnesses)) under the hood:

```rust
let value = kani::any();
kani::assume((min..max).contains(&value));
value
```

To get started, check out the Bolero and Kani tutorials at the following links:
 * [Bolero tutorial](https://camshaft.github.io/bolero/tutorials/fibonacci.html)
 * [Kani tutorial](https://model-checking.github.io/kani/kani-tutorial.html)

## Footnotes

[^footnote-kani]: Note that this harness cannot be compiled or executed with `rustc` as it involves some Kani attributes/functions that are only interpreted by `cargo kani`

[^footnote-dev-dep]: Before running Bolero, make sure to include it as a dev dependency in the `Cargo.toml`:

    ```toml
    [dev-dependencies]
    bolero = "0.8.0"
    ```
