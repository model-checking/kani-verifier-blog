# Function Contracts for Kani

I this blogpost we discuss a new feature we’re developing for Kani: Function Contracts. It’s now available as an unstable feature with the `-Zfunction-contracts` flag. If you would like to learn more about the development and implementation details of this feature and leave feedback please refer to [the RFC](https://model-checking.github.io/kani/rfc/rfcs/0009-function-contracts.html).

## Introduction

Verification is a costly art. If you are an active user of Kani you know that the runtime of a proof does not scale linearly with the amount of code under verification and you probably have a number of functions and ideas for harnesses you’d like Kani to verify, but it just takes prohibitively long.

We [previously](https://model-checking.github.io/kani-verifier-blog/2023/02/28/kani-internship-projects-2022-stubbing.html) blogged about stubbing, a technique where a function that performs a costly computation, for instance trough recursion or a long running loop, could be replaced with a function that is cheaper to execute in the verifier. This replacement approximates the behavior of the function it replaces and/or uses techniques only available in a verifier, like non-deterministic values (`kani::any`). By successively replacing costly functions with stubs Kani can check ever larger proofs but it also comes with a downside.

As we discussed in the [section on risks](https://model-checking.github.io/kani-verifier-blog/2023/02/28/kani-internship-projects-2022-stubbing.html#risks-of-stubbing) stubbing is a powerful tool with few guard rails. In principle you can stub a function with any other function, so long as the type signature matches. Of course any user of stubs is going to be careful to align the behavior of the function being stubbed and the stub. However the whole point of stubbing is that the stub doesn’t behave exactly as the function it replaces, because it needs to be faster. If the approximation is incorrect, it leads to *unsoundness*, meaning that verification can succeed in spite of a bug being present.

In today's blogpost we want to introduce you to a new concept that lets us verify larger programs without sacrificing soundness: function contracts. The idea is very simple: like a stub the contract approximates the behavior of a function in an efficient way, allowing us to scale and verify larger programs. However with a contract the verifier automatically checks that the approximation is sound so we can be confident in the results of our verification.

## Dangers of Stubbing

Let us illustrate this with an example. Consider Euclid’s formula for calculating the greatest common divisor of two numbers, here called `max` and `min`. For verification this would be considered an expensive computation due to the recursive call. This recursion is very busy, in the [worst case](https://en.wikipedia.org/wiki/Euclidean_algorithm#Worst-case) the number of steps (recursions) approaches 1.5 times the number of bits needed to
represent the number. Meaning that for two large 32 bit numbers it can take almost 48 iterations for a single call to `gcd`. If a harness that uses `gcd` does not heavily constrain the input, Kani would have to unroll the recursion 48 times and then execute it symbolically. An expensive operation.

```rust
fn gcd(mut max: i32, mut min: i32) -> i32 {
    if min > max {
				std::mem::swap(&mut max, &mut min);
    }

    let rest = max % min;
    if rest == 0 { min } else { gcd(min, rest) }
}

```

To verify efficiently we would employ a stub for this function that uses assumptions and non-deterministic values to avoid a loop. Our first attempt at stubbing may be very simply that the return value of `gcd` is smaller than its inputs.

```rust
fn gcd_stub(max: i32, min: i32) -> i32 {
    let result = kani::any();
    kani::assume(result < max && result < min);
    result
}

```

Now you may immediately notice that this stub is not correct if `max == min`, in which case `gcd` would return `min`, whereas `gcd_stub` would return a non-deterministic value smaller than `min`. If this is used in a harness it can miss a classic off-by-one error.

```rust
#[kani::proof]
#[kani::stub(gcd, gcd_stub)]
fn main() {
    let x = kani::any();
    kani::assume(x <= 100);
    let y = kani::any();

    let v : Vec<i32> = (0..100).collect();

    v[gcd(x, y)]
}

```

This harness will succeed *despite* the fact that for `x == 100` we are
accessing out of bounds of the vector. To guard against this problem we can
check that the assumptions we make in the stub hold for the actual result of
running `gcd`. This means we ensure that the stub is an overapproximation. This
harness mirrors our stub but flips the assumption to an assertion. Checking the
harness will fail and alert us that we would have to change our stub to at least
`result <= max` and `result <= min` to be *sound*.

```rust
#[kani::proof]
fn gcd_stub_check() -> i32 {
    let max = kani::any();
    let min = kani::any();
    let result = gcd(max, min);
    kani::assert(result < max && result < min && result != 0);
}

```

## Checking Contracts

What we just did is manually created a function contract. We used the condition `result <= max && result <= min && result != 0` both as an approximation of `gcd` and
also to check it against the actual implementation. This is precisely the idea
behind a function contract. To create a condition that describes the function
behavior and use it both for checking and as a stub. So now with Kani's new
function contract feature we can write *just* the contract condition and Kani
will generate the check and the stub for us automatically.

```rust
#[kani::ensures(result < max && result < min && result != 0)]
fn gcd(mut max: i32, mut min: i32) -> i32 {
    if min > max {
		std::mem::swap(&mut max, &mut min);
    }

    let rest = max % min;
    if rest == 0 { min } else { gcd(min, rest) }
}

```

In this example we are using an `ensures` clause. This clause states a property
which must hold after the execution of the function, also called a
*postcondition*. Kani is lenient, allowing arbitrary Rust expressions as part of
the `ensures` clause, including function calls. Take note however that the
expressions in the `ensures` clause may not allocate, deallocate or modify heap
memory or perform I/O. Multiple `ensures` clauses are allowed and they work as
though they were joined with `&&`. Our example could thus also have been written
as

```rust
#[kani::ensures(result < max)]
#[kani::ensures(result < min)]
#[kani::ensures(result != 0)]
fn gcd(mut max: i32, mut min: i32) -> i32
{ ... }

```

Unfortunately while Kani can generate the check for us it cannot automatically
generate the non-deterministic inputs yet. It would be easy for simple cases
like this (shown below), but the general case is difficult and sometimes impossible, especially in the presence of pointers. For the time being we ask
the user to provide the harness.

The harness only needs to set up the non-deterministic inputs. The actual
conditions for checking the contract are inserted by Kani in the right places
automatically. Harnesses for contracts use the `proof_for_contract` attribute
which mentions the function that should have its contract checked. Otherwise
they act like any other `kani::proof` and admit additional annotations such as
`kani::unwind`, `kani::solver` and even `kani::stub`.

```rust
#[kani::proof_for_contract(gcd)]
fn gcd_check_harness() {
    gcd(kani::any(), kani::any());
}

```

## Using Contracts

Any function that has at least one contract API clause attached is considered
to "have a contract" by Kani. `ensures` is one type of clause in the function
contract API. There is also the `requires` clause for specifying preconditions
and `modifies`, a refinement of `mut`. We will dive into those in more detail
later.

Functions that "have a contract" (at least one clause specified) can be stubbed
with that contract in any harness except its own `proof_for_contract`. The
annotations to do so is `kani::stub_verified(...)` and mentions the function to
stub. So returning to the example from before our harness would look as follows

```rust
#[kani::proof]
#[kani::stub_verified(gcd)]
fn main() {
    let x = kani::any();
    kani::assume(x <= 100);
    let y = kani::any();

    let v : Vec<i32> = (0..100).collect();

    v[gcd(x, y)]
}

```

Note that as opposed to `stub` `stub_verified` only takes one argument. As the
name suggests `stub_verified` ensures that the contract passes its checking
harness and thus is a sound replacement for the original function body.

## Inductive Verification

A great feature of contracts is that for recursive functions the stubbing of the
contract can also be used during the checking also, eliminating the recursive
call. This is known as *inductive verification* and it can reduce multiple
rounds of verification to just one step. Our example actually already takes
advantage of this. The `gcd` function is verified in a single step, using the
verified stub on the recursive call. If we constructed this proof manually,
inlining the check and induction for `gcd` in its harness it would look
something like this. Note that it no longer contains any recursion or loops.

```rust
#[kani::proof]
fn gcd_expanded_inductive_check() -> i32 {
    let max = kani::any();
    let min = kani::any();
    let result = {
        // Inlined first execution of `gcd`
        if min > max {
            std::mem::swap(&mut max, &mut min);
        }

        let rest = max % min;
        if rest == 0 { min } else {
            // Inlined recursion
            let max = min;
            let min = rest;
            let result = kani::any();
            kani::assume(result < max && result < min && result != 0);
            result
        }
    };
    // Checking of the postcondition
    kani::assert(result < max && result < min && result != 0);
}

```

**TODO:** Closing paragraph

## Havocking and `modifies`

Verified stubs work by replacing the return value of the function with
`kani::any()` and `kani::assume`ing the postcondition. However functions may
also modify mutable inputs such as `&mut` references instead or in addition to
returning a value. By default Kani will forbid any assignment or modification of
mutable reference arguments. Each mutable reference you want to assign must be mentioned in a `modifies` clause.

**TODO:** Finish section

## Closing

**TODO:** Finish Section

## Soundness

Stubs can deviate from the behavior of the function it replaces in two ways. A stub can produce values that the original function wouldn’t. This is called *overapproximating* because the set of  output values from the stub is larger than that of the original function. Down the line those extra values can cause verification failure, because the code assumes that they cant occur. This is actually not a problem for soundness since the verification still fails, it is just annoying.

A more serious problem is *underapproximation*, which is when the stub doesn’t produce certain values the original function would. Adapting a humorous [example from XKCD](https://xkcd.com/221/) here if we were to stub a `random` function by one that just returns `4` and subsequently index into a vector of length `5` then it is clear that, while the verification succeeds, there is a high likelihood of a panic at runtime.

```rust
fn getRandomNumber() -> u32 {
		4  // chosen by fair dice roll
       // guaranteed to be random
}

#[kani::proof]
#[kani::stub(rand::random, getRandomNumber)]
fn my_program() {
		let v = vec![1;5];
		let i : u32 = rand::random();

		println!("{}", v[i as usize]);
}
```

I summary: *unsoundness* means that a bug is possible at runtime but not caught by the verification and it arises when a stub *underapproximates* the function it replaces.

## Tips and Tricks

### Stubs for Non-local Functions

Attributes for attaching contracts only work on crate-local items but you may
wish to stub an out of crate function. There is currently no builtin way to do
so but you can achieve the same effect using a technique known as the "double
stub". The idea is to first stub an external function to a local function that
immediately calls the external function. Then the desired contract is attached
to this local function which is then then stubbed as a `stub_verified` using the
contract.

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

The order of `stub` and `stub_verified` does not matter. With this technique we
can attach a contract to the external `gcd` without having to change the code of
`function_under_verification`. Unlike other uses of stubbing this does not pose a
threat to soundness because the potentially unsound `stub` effectively replaces
`gcd` with itself.

## Missing

- Absent features
    - havocking for references
    - Interior mutability
- Planned features
- Motivation for design
- Why we picked e.g. rust expressions as design for e.g. the assigns clause.
- Tips and tricks
    - using a bound on the check harness (is unsound but can be helpful)