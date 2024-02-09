---
title: Function Contracts for Kani
layout: post
---

In this blogpost we discuss function contracts which are now available as an unstable feature, enabled with the `-Zfunction-contracts` flag. If you would like to learn more about the development and implementation details of this feature please refer to [the RFC](https://model-checking.github.io/kani/rfc/rfcs/0009-function-contracts.html). If you try out this new feature and want to leave feedback join the discussion in [the feature tracking issue](https://github.com/model-checking/kani/issues/2652).

## Introduction

Today we want to introduce you to a new feature in Kani that lets us verify larger programs: function contracts [^eiffel-1][^eiffel-2]. Contracts let us safely break down the verification of a complex piece of code individually by function and efficiently compose the results, driving down the cost of verifying code with long call chains and repeated calls to the same function. This technique is called *modular verification* as the verification task is broken down into modules (in this case by function), verified independently and then recombined.

[^eiffel-1]: Meyer, Bertrand: Design by Contract, in *Advances in Object-Oriented Software Engineering*, eds. D. Mandrioli and B. Meyer, Prentice Hall, 1991, pp. 1–50
[^eiffel-2]: Meyer, Bertrand: Applying "Design by Contract", in Computer (IEEE), 25, 10, October 1992, pp. 40–51 ([online article](http://se.ethz.ch/~meyer/publications/computer/contract.pdf))

The best example for how function contracts improve verification time are recursive functions. With a contract a recursive function can be verified in a single step, a technique called *inductive verification*. In this post we will explore how function contracts can be used to modularize the verification of a harness in the [Firecracker](https://firecracker-microvm.github.io/) Virtual Machine Monitor by modularly verifying an implementation of Euclid’s greatest common divisor algorithm inductively and then use that result to verify the harness.

Aside: we've actually blogged twice previously about the exciting verification work we've been doing on the Firecracker project. You can find those posts [here]({% link _posts/2023-08-31-using-kani-to-validate-security-boundaries-in-aws-firecracker.md %}) and [here]({% link _posts/2022-07-13-using-the-kani-rust-verifier-on-a-firecracker-example.md %}).

## The Example: Firecracker’s `TokenBucket`

We will explore employing a function contract when verifying the methods of `TokenBucket` in the `vmm` module of the Firecracker Virtual Machine Manager. To keep the example concise we will use the relatively simple `TokenBucket::new` function and its verification harness. The code is slightly simplified and we also use a recursive implementation of `gcd`. Firecracker actually uses a `gcd` with a loop which would need loop contracts to verify inductively. These are not supported yet by Kani, but conceptually they function the same way as function contracts. You can find the original version of all harnesses and verified code [here](https://github.com/firecracker-microvm/firecracker/blob/a774e26d63981fc031b974741a39519b08a61d3b/src/vmm/src/rate_limiter/mod.rs).

Let's first look at the harness that tests `TokenBucket::new`. It is straightforward, setting up a series of non-deterministic inputs, calling the function under verification and then asserting a validity condition.

```rust
#[kani::proof]
fn verify_token_bucket_new() {
    let size = kani::any_where(|s| *s != 0);
    let one_time_burst = kani::any();
    let complete_refill_time_ms = kani::any_where(|t|
        *t != 0 && *t < u64::MAX / NANOSEC_IN_ONE_MILLISEC
    );

    let bucket = TokenBucket::new(size, one_time_burst, complete_refill_time_ms).unwrap()
    assert!(bucket.is_valid());
}
```

Since the most important call here is to `TokenBucket::new` let’s take a closer look at its implementation.

```rust
pub fn new(size: u64, one_time_burst: u64, complete_refill_time_ms: u64) -> Option<Self> {
    if size == 0 || complete_refill_time_ms == 0 {
        return None;
    }
    let complete_refill_time_ns =
        complete_refill_time_ms.checked_mul(NANOSEC_IN_ONE_MILLISEC)?;
    let common_factor = gcd(size, complete_refill_time_ns);
    let processed_capacity: u64 = size / common_factor;
    let processed_refill_time: u64 = complete_refill_time_ns / common_factor;

    Some(TokenBucket {
        size,
        one_time_burst,
        initial_one_time_burst: one_time_burst,
        refill_time: complete_refill_time_ms,
        budget: size,
        last_update: Instant::now(),
        processed_capacity,
        processed_refill_time,
    })
}
```

Most of what happens here is just a series of divisions, with the exception of this call: `gcd(size, complete_refill_time_ns)` so let us look at that function next:

```rust
fn gcd(mut max: u64, mut min: u64) -> u64 {
    if min > max {
        std::mem::swap(&mut max, &mut min);
    }

    let rest = max % min;
    if rest == 0 { min } else { gcd(min, rest) }
}
```

This is by far the costliest part of the code of `TokenBucket::new`. The rest of the function was a fixed set of divisions, but here we have a division and a recursive call back to `gcd`. It is not immediately obvious how busy this computation is, but in the [worst case](https://en.wikipedia.org/wiki/Euclidean_algorithm#Worst-case) the number of steps (recursions) approaches 1.5 times the number of bits needed to represent the input numbers. Meaning that for two large 64-bit numbers it can take almost 96 iterations for a single call to `gcd`. Recall that our smallest input to `TokenBucket::new` is a non-deterministic value in the range $0< x < 18446744073709$ (up to 45 non-zero bits). If a harness that uses `gcd` does not heavily constrain the input, Kani would have to unroll the recursion at least 68 times and then execute it symbolically; an expensive operation.

Since `gcd` is the most expensive part of verifying this harness it is an ideal target for using a contract to make it more efficient. In fact by replacing it with a contract we not only make this harness more efficient but also any harness that uses `gcd` directly or indirectly (e.g., by calling `TokenBucket::new`). In Firecracker, for instance, there are three more harnesses that all call `gcd` and thus benefit from modular verification.

## Introducing a Function Contract with Postconditions

Function contracts are conceptually rather simple actually. They comprise a set of conditions which characterize the behavior of the function, similar to the conditions you would use in a test case. There are different types of conditions which are also called the *clauses* of the contract. The first type of clause we will introduce here is the `ensures` clause.

```rust
#[kani::ensures(max % result == 0 && min % result == 0 && result != 0)]
fn gcd(mut max: u64, mut min: u64) -> u64 {
    if min > max {
        std::mem::swap(&mut max, &mut min);
    }

    let rest = max % min;
    if rest == 0 { min } else { gcd(min, rest) }
}
```

The `ensures` clause describes the relationship of the return of the function (e.g. `result`) with the arguments that the function was called with. It is often also called a *postcondition*, because it is a *condition* that must hold after (*post*) the execution of the function. With Kani, the contents of the `ensures` clause can be any Rust expression that returns `bool`. However the expression may not perform any *side effects*, that is: allocate, deallocate or modify heap memory or perform I/O. A single function may have multiple `ensures` clauses which functions as though they had been joined with `&&`. Our example could thus also have been written as

```rust
#[kani::ensures(max % result == 0)]
#[kani::ensures(min % result == 0)]
#[kani::ensures(result != 0)]
fn gcd(mut max: u64, mut min: u64) -> u64 { ... }
```

You may wonder at this point what this is actually useful for. It turns out that for a verifier the *abstraction* of the function as described by the conditions in our `ensures` clause, is much easier to reason about than running through the many recursive calls in the actual implementation of `gcd`. You may also notice that the abstraction only approximates `gcd`. `max % result == 0` and `min % result == 0` describe *a* common divisor of `max` and `min` but not necessarily the *greatest*. However in this case this is acceptable to us when it comes to verifying the callers of `gcd`. Later we will add an additional check to ensure we generate the largest divisor.

Our goal will be to eventually use the efficient abstraction everywhere where `gcd` is called but first we must ensure that `gcd` respects these conditions. We need to *verify the contract*.

Doing so is the same as verifying that the postcondition(s) hold for any possible input to the function. If we were to manually create a harness that does this verification it would look like this

```rust
#[kani::proof]
fn gcd_stub_check() {
    // First we create any possible input using a
    // non-deterministic value
    let max = kani::any();
    let min = kani::any();

    // Sadly necessary for performance right now.
    kani::assume(max <= 255 && min <= 255);

    // We create any possible result
    let result = gcd(max, min);

    assert!(
        // And here is our postcondition
        max % result == 0 && min % result == 0 && result != 0
    );
}
```

**Caveat:** In this harness we've had to constrain the size of `min` and `max`. This is not because of contracts but because there are currently performance problems with verifying unconstrained `u64` in CBMC. Doing this makes the harness unsound, which we explain in more detail in [this section](#soundness-and-comparison-with-stubbing).

If we run this harness however we will discover a verification failure, because of a division by `0` in `let rest = max % min;` which brings us to the introduction of the second type of clause: `requires`.

## Preconditions

Sometimes functions, such as our `gcd` are not defined for all of their possible input (e.g. they panic on some). Function contracts let us express this using a condition that that the function arguments must satisfy at the beginning (*pre*) of a function’s execution: a *precondition*. This condition limits the inputs for which a contract will be checked during verification, and it will also be used to ensure that if we use the contract conditions for modular verification, we don’t do it with any values that the function would not be defined for. We can add a precondition buy using the `requires` clause in `gcd` like so

```rust
#[kani::requires(max != 0 && min != 0)]
#[kani::ensures(max % result == 0 && min % result == 0 && result != 0)]
fn gcd(mut max: u64, mut min: u64) -> u64 { ... }
```

As with postconditions, the precondition allows any side-effect free rust expressions of type `bool`, may mention the function arguments and multiple `requires` clauses act as though they were joined with `&&`.

To understand how this makes our contract verification succeed, let's integrate it into the manual harness we had written before.

```rust
#[kani::proof]
fn gcd_stub_check() {
    // First we create any possible input using a
    // non-deterministic value
    let max = kani::any();
    let min = kani::any();

    // Sadly necessary for performance right now.
    kani::assume(max <= 255 && min <= 255);

    // Limit the domain of inputs with precondition
    kani::assume(max != 0 && min != 0);

    // We create any possible result
    let result = gcd(max, min);

    assert!(
        // And here is our postcondition
        max % result == 0 && min % result == 0 && result != 0
    );
}
```

Running this in Kani succeeds, giving us confidence that now our contract properly approximates the effects of `gcd`.

You may be wondering now why we’ve even written the `requires` and `ensures` clause, given that we verified it using a harness we wrote ourselves. Well in actuality Kani will do most of it for you. We will see [later](#a-bit-of-cleanup) exactly how little is needed to verify the contract, for now you may assume that Kani does it for you automatically.

## Using Contracts

We have proved that our function upholds the contract we specified so now we can use the abstraction at the call sites.

If we cast our mind back to the implementation of `TokenBucket::new` we can replace the function as follows:

```rust
pub fn new(size: u64, one_time_burst: u64, complete_refill_time_ms: u64) -> Option<Self> {
    if size == 0 || complete_refill_time_ms == 0 {
        return None;
    }
    let complete_refill_time_ns =
        complete_refill_time_ms.checked_mul(NANOSEC_IN_ONE_MILLISEC)?;

    // Make sure the precondtions are respected
    assert!(size != 0 && complete_refill_time_ns != 0);
    // Create a non-deterministic value for the result
    let common_factor = kani::any();
    // Assume that the postconditions hold (as we know they would)
    kani::assume(
        size % common_factor == 0
        && complete_refill_time_ns % common_factor == 0
        && common_factor != 0
    );

    let processed_capacity: u64 = size / common_factor;
    let processed_refill_time: u64 = complete_refill_time_ns / common_factor;

    Some(TokenBucket {
        size,
        one_time_burst,
        initial_one_time_burst: one_time_burst,
        refill_time: complete_refill_time_ms,
        budget: size,
        last_update: Instant::now(),
        processed_capacity,
        processed_refill_time,
    })
}
```

We have now replaced the potential 68 unrollings and multiplications of `gcd` with a single check and one assumption, all of which the verifier can reason about efficiently.

Of course we wouldn’t replace the calls to `gcd` by hand. In fact we are not going to make any changes to the code under verification. Instead we will instruct Kani to perform this replacement for us using a new attribute for the harness: `stub_verified`.

```rust
#[kani::proof]
#[kani::stub_verified(gcd)]
fn verify_token_bucket_new() {
    let size = kani::any_where(|s| *s != 0);
    let one_time_burst = kani::any();
    let complete_refill_time_ms = kani::any_where(|t|
        *t != 0 && *t < u64::MAX / NANOSEC_IN_ONE_MILLISEC
    );

    let bucket = TokenBucket::new(size, one_time_burst, complete_refill_time_ms).unwrap()
    assert!(bucket.is_valid());
}
```

This attribute works similarly to `kani::stub` which we’ve explored in a [previous post](https://model-checking.github.io/kani-verifier-blog/2023/02/28/kani-internship-projects-2022-stubbing.html). In short, the attribute replaces each call to `gcd` that is reachable from the harness with new code. In fact, under the hood, `stub_verified` uses `stub` but instead of replacing `gcd` by some arbitrary function, it is replaced with the abstraction from the contract, the same way we did before manually.

## Inductive Verification

The discerning reader might already notice that, if we can replace every call to `gcd` with the contract, then would we be able to do this also *within* `gcd`? The answer is **yes** we can, and it will allow us to completely skip unrolling `gcd`, even when verifying the implementation against its contract. This technique is called *inductive verification* and it substantially improves the performance of verifying recursive functions. Side note: there are also loop contracts which enable inductive verification for loops. They are not yet supported in Kani.

You may be skeptical as to how this can work. As mentioned before, replacing the call to `gcd` is only safe because we previously verified the function against its contract so how would it be safe to already use the replacement *while* we’re still verifying the contract? Let us first look at what a manual harness for inductive verification of `gcd` would look like and step through it to convince ourselves that this is valid.

```rust
#[kani::proof]
fn gcd_expanded_inductive_check() -> i32 {
    // Unconstrainted, non-deterministic inputs
    let max = kani::any();
    let min = kani::any();

    // Sadly necessary for performance right now.
    kani::assume(max <= 255 && min <= 255);

    let result = {
        // Preconditions
        kani::assume(max != 0 && min != 0);

        // Inlined first execution of `gcd`
        if min > max {
            std::mem::swap(&mut max, &mut min);
        }

        let rest = max % min;
        if rest == 0 { min } else {
            // Inlined recursion
            let max = min;
            let min = rest;
            // Make sure preconditions are respected for recursion
            assert!(max != 0 && min != 0);
            let result = kani::any();
            kani::assume(max % result == 0 && min % result == 0 && result != 0);
            result
        }
    };
    // Make sure postconditions hold
    assert!(max % result == 0 && min % result == 0 && result != 0);
}
```

First it is helpful to think about the recursion as a sequence of individual steps that build on top of one another, like a pyramid. Each step performs the same computation, but with different inputs, because the previous step calls into it with `min` and `rest`, which differ from `max` and `min`. Now consider the first step. It is called with non-deterministic inputs that are only constrained by the precondition. Then a computation is performed to calculate `min` and `rest` that is used for the recursive call and at the end the postconditions are enforced with `assert!(max % result == 0 && ...)`. What does that mean? It means if this step passes verification we can be sure that the postconditions hold for the inputs we verified with, e.g. any combination of `max` and `min` that satisfies `max != 0 && min != 0`. Now let's consider again the recursive call. We call with `min` and `rest` which are not the same as `max` and `min`. However remember that actually what our first step verification proves not just that the postconditions hold for *a* `max` and `min`, but in fact for *any* `max` and `min`, so long as the precondition is satisfied. Therefore we can conclude that it will also hold for `gcd(min, rest)`, if `min` and `rest` satisfy the preconditions, e.g. `min != 0 && rest != 0`. And that is precisely what is enforced where the abstraction is employed with `assert!(max != 0 && min != 0)`.

As a small technicality: induction is usually split into the so called "base case" and the "induction step". In our example a single run of the function actually combines both, which is the `if rest == 0` split. When `rest == 0` then we have reached the base case, otherwise we are in the induction step. Both the base case and the induction step must uphold the ponstconditions. The way that our proof is set up here already ensures that because the postcondition `assert!` gets enforced regardless of whether we took the base case or the induction step.[^return]

[^return]: The astute reader might note that this would not be the case if the body of the function we are verifying contained a `return` statement. Rest assured that the code you see here is just an illustration and the actual code generated for contract verification is not so easily fooled. If you want to see actual examples of how this is set up there is one in the implementation documentation of the [contracts macros](https://github.com/model-checking/kani/blob/main/library/kani_macros/src/sysroot/contracts.rs) or you can dump the generated code with the rustc flag `-Zunpretty=expanded`.

To put it another way, when we recurse, we are allowed to assume that the verification passed, because the step that we are currently verifying is being checked for any possible input, including the one we are recursing with. If a problem were to occur anywhere in the recursive calls, we would see the same problem as a verification failure of the first step.

Notice that using this trick, we reduced the up to 68 unrollings to just one, a substantial win. What is even better that doing this requires no input from you. Kani does this automatically. Any function with a contract is always verified inductively. Side note: this works even if the recursive call is not direct but buried somewhere in the call chain.

## A Bit of Cleanup

Before we close with the example, a few more details about the contract verification process. We mentioned earlier that Kani does most of the contract verification work for you. It injects the pre- and postconditions and sets up the inductive verification. However a small amount of manual but important labor is required by the user. Currently, Kani is not able to generate the non-deterministic inputs and so it requires the user to write a simple harness. In this case it would look like this:

```rust
#[kani::proof_for_contract(gcd)]
fn gcd_stub_check() {
    // Create non-determinstic values
    let max = kani::any();
    let min = kani::any();

    gcd(max, min)
}
```

This may be surprising to you since, in our example, we use a straightforward `kani::any()`. Indeed for finite types like `u64` that implement [`Arbitrary`][Arbitrary] Kani *could* generate this harness automatically. However for any type involving references or pointers (like `Vec`) Kani is unable to generate the harness. Because it would be confusing if sometimes the harness is generated automatically and sometimes not, we decided that for the time being a manual harness is always required. We are working on adding auto generation in the future.

[Arbitrary]: https://model-checking.github.io/kani/tutorial-nondeterministic-variables.html

A few words about writing contract harnesses: the harness should generate completely unconstrained values, otherwise the verification will be unsound. Usually this means calling `kani::any()`. Sometimes it is not possible to create completely unconstrained values, as is the case with recursive types and array-backed types. In these cases you must use careful judgement and ensure that the value you create is large enough to exercise all possible behaviors of the function. You can think of this as covering all branches.

Finally we mentioned we would be adding a check to ensure that our `gcd` actually produces the greatest divisor. For this we will need a separate harness and in this case we sadly cannot use any contract substitution. The reason is that, if we substitute, we get values that satisfy the postcondition, but nothing more. Since the postcondition does not ensure the result is the largest divisor possible, it won’t be.

```rust
#[kani::proof]
fn gcd_greatest_check() {
    // Create non-determinstic values
    let max = kani::any();
    let min = kani::any();

    let result = gcd(max, min);

    let greatest = kani::any_where(|a|
        max % *a == 0 && min % *a == 0
    );
    assert!(!(greatest > result));
}
```

Currently our function contracts can’t express that the result is the largest divisor, which necessitates this additional harness. In future Kani’s function contracts will be extended with *quantifiers*, which will allow the postcondition to express this property. For instance such a postcondition may look like this: `forall(|i| : max % i == 0 && min % i == 0 => i <= result)` which states that if any integer `i` exists that is also a divisor of `min` and `max`, then it must either be the result or smaller than it. Clearly such a condition can only be satisfied by a `result` that is the largest common divisor.

## Concluding the Example

This concludes our walkthrough of function contracts and inductive verification for the Firecracker example. We have seen how functions can be abstracted using the `requires` and `ensures` clause. We have seen how Kani would verify the contract holds efficiently, using inductive verification. We then saw how after verification we can use the cheap contract in other proofs that call `gcd`.

You can use function contracts yourself with Kani since version 0.33.0. To enable the feature use `-Zfunction-contracts`. For an overview of the API, including all supported types of clauses, see our [rustdocs](https://model-checking.github.io/kani/crates/doc/kani/contracts/index.html). If you decide to try out this new feature we would very much like to hear your feedback, so join the discussion in the [feature tracking issue](https://github.com/model-checking/kani/issues/2652).

There are more features in the pipeline for contracts. In the near future we are focusing on better support for mutable pointers. For more information on implementation details and features to come take a look at the [RFC](https://model-checking.github.io/kani/rfc/rfcs/0009-function-contracts.html).

What follows hereafter are a few more sections with additional information, such as the `modifies` clause used to reason about mutable memory, history expressions and a comparison with the stubbing feature we explored in an [earlier blog post](https://model-checking.github.io/kani-verifier-blog/2023/02/28/kani-internship-projects-2022-stubbing.html).

---

## A Neat Trick: Contracts for Non-local Functions

Attributes for attaching function contracts only work on crate-local items but you may wish to stub an out of crate function. There is currently no builtin way to do so but you can achieve the same effect using a technique known as the "double stub". The idea is to first stub an external function to a local function that immediately calls the external function. Then the desired contract is attached to this local function which is then then stubbed as a `stub_verified` using the contract.

```rust
use external_crate::gcd;

#[kani::ensures(result < max && result < min && result != 0)]
fn local_gcd(max: i32, min: i32) -> i32 {
    // immediate call with same arguments to the external function
    gcd(max, min)
}

fn function_under_verification(...) {
    ... gcd(...) ...
}

#[kani::proof]
#[kani::stub(gcd, local_gcd)]
#[kani::stub_verified(local_gcd)]
fn harness() {
    ... function_under_verification(...) ...
}
```

The order of `stub` and `stub_verified` does not matter. With this technique we can attach a contract to the external `gcd` without having to change the code of `function_under_verification`. Unlike other uses of stubbing this does not pose a threat to soundness because the potentially unsound `stub` effectively replaces `gcd` with itself.

## Soundness and Comparison with Stubbing

Function contracts and stubbing are closely related as both allow the replacement of a costly computation with a cheap one via harness attributes. The crucial difference is that contracts preserve soundness. We will get into more detail later, but put simply: function contracts being sound means you can trust a successful verification.

Conceptually stub `#[kani::stub(target, source)]` replaces all calls to `target` with `source` with weak constraints on what `source` is. `source` needs to be a function definition with a signature such that each call after the replacement typechecks. The details of what that means are unimportant, what matters is that no behavioral equivalence is checked beyond type compatibility.

To illustrate this, lets consider an [example from XKCD](https://xkcd.com/221/) which stubs a `random` function by one that just returns `4`. This type of use of stubbing is completely legal and would not lead to a type error or verification failure.

```rust
// extern
crate rand {
    pub fn random<T>() -> T
    where
        Standard: Distribution<T>
    { /* low level system calls */ }
}

fn get_random_number() -> u32 {
    4  // chosen by fair dice roll
       // guaranteed to be random
}

#[kani::proof]
#[kani::stub(rand::random, get_random_number)]
fn my_program() {
    let v = vec![1;5];
    let i : u32 = rand::random();

    println!("{}", v[i as usize]);
}
```

It is rather obvious that `get_random_number` is not the same as `rand::random`. In the harness included in the example we can see how this leads to problems. After the stubbing is applied the random number is always going to be 4, which means the verification of the harness will succeed. However at runtime, where `rand::random` is no longer replaced a number greater than 4 can be produced and cause a panic. This type of situation where a runtime panic is not caught by verification is referred to as a *violation of soundness* or *unsoundness*.

When *soundness* is preserved that means that any runtime problem (such as a panic) cause a verification failure. Dually if soundness is violated then verification succeeds, but a runtime error is still possible. As you may imagine unsoundness significantly weakens the usefulness of a verifier. After all why bother verifying if we can still get issues at runtime? As a result verifiers like Kani take great care to preserve soundness. Stubbing is one of the features that ***can*** introduce unsoundness. As a result it is important to ensure that every stub over-approixmates the function it replaces, at least for how it is used in the code under verification. For instance it is completely sound to replace `rand::random` with a non-deterministic value with the following implementation.

```rust
fn get_random_number() -> u32 {
    kani::any() // actually all possible values
                // guaranteed to be random
}
```

The verifier cannot execute the actual `rand::random`, because that relies on a syscall that returns a source of randomness from the machine, and so we need to replace it with something for the purposes of verification. Now if you imagine the verifier modeling all possible outputs from a random number generator simultaneously, well that is the same as using a non-deterministic value. As a result this use of stubbing is useful, safe and necessary.

You may wonder how we can determine whether a given situation is sound. We do this by inspecting the relationship between a function and its replacement. The replacement, by design, always approximates the behavior of the code it replaces and the question is how it does this. Conceptualize the original function as simply a black box that produces a set of possible outputs. If its replacement produces a subset of the outputs, then that is called an *under-approximation*, which causes unsoundness. We see this in our example where `get_random_number` produced fewer (e.g. only the integer `4`) instead of all possible outputs (all `u32` integers). Conversely if the replacement produces a superset of outputs this is called an *over-approximation* and crucially always sound!

Side note: the model of the black box function also extends to functions that take arguments, though in this case we have to consider separately the output sets for every combination of argument values.

Function contracts are designed such that they are always over-approximations and thus sound. This is guaranteed by the following: any value the implementation produces must pass the postcondition, but not every value that passes the postcondition must be produced by the implementation. During replacement with the contract all values that pass the postcondition are created, thus a superset of the actual outputs.

In our contract design there however a remaining source of unsoundness, which is the manual harnesses for verifying contracts. This was mentioned before but as a small recap: if a manual harness restricts the input such that certain behaviors of the function and contract under verification are not covered, unsoundness arises.

This happens in our example too where we sadly cannot verify `gcd` for an unconstrained `u64` input. The unsoundness arises when we stub using the contract. We may supply the stub with argument values that the function was never verified against and thus we have no assurance that the behavior of the function and the contract is going to be the same. A sound way to deal with this issue would be to use a precondition instead of `kani::assume`.