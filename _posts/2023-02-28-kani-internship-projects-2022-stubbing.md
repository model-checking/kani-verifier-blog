---
layout: post
title:  "Kani Internship Projects 2022: Function Stubbing"
---

Kani is a verification tool that can help you systematically test properties about your Rust code.
To learn more about Kani, check out [the Kani tutorial](https://model-checking.github.io/kani/kani-tutorial.html) and our [previous blog posts](https://model-checking.github.io/kani-verifier-blog/).

Today we're continuing a series of posts on the internship projects carried out
in our team during 2022. The Kani team is proud to be part of the AWS Automated
Reasoning Group, which every year hosts a number of interns to work on
automated-reasoning projects for tools like Kani. More details on AWS Automated
Reasoning areas of work and available locations can be found [here](https://2023arinternships.splashthat.com/).
If you're a Masters or PhD student interested in Automated Reasoning, please
consider applying to the following openings:
 * [2023 Applied Science Internship (Master's student)](https://www.amazon.jobs/en/jobs/2173429/2023-applied-science-internship-automated-reasoning-united-states)
 * [2023 Applied Science Internship (PhD student)](https://www.amazon.jobs/en/jobs/2173372/2023-applied-science-internship-automated-reasoning-united-states)

In this post, we will talk about the internship project titled *Improving Kani's Usability with Function and Method Stubbing*.

> This internship project was executed by [Aaron
Bembenek](https://people.seas.harvard.edu/~bembenek/). Aaron joined the Kani
team as an Applied Scientist Intern while finishing his graduate studies at the
[Harvard John A. Paulson School of Engineering and Applied
Sciences](https://seas.harvard.edu/). We are very grateful to Aaron for his hard
work on this project, and wish him the best in his PhD defense!

## Function Stubbing in Kani

**Function stubbing** refers to users writing stub (mock) functions that they substitute for the real implementation during verification.
Although definitions for *mocking* (commonly used in testing) and *stubbing* may slightly differ, we often use both terms interchangeably.

In general, we have identified three reasons where users may consider stubbing out a function:
 1. **Unsupported features:** The code under verification contains features that Kani does not support, such as inline assembly.
 2. **Bad performance:** The code under verification contains features that Kani supports, but it leads to bad verification performance (for example, deserialization code).
 3. **Compositional reasoning:** The code under verification contains code that has been verified separately.
                                Stubbing the code that has already been verified with a less complex version that soundly models its behavior can result in reduced verification workloads[^footnote-contracts].

Note that stubbing tries to solve a usability problem for Kani users by enabling them to verify code that otherwise would be impossible or impractical to verify.

To enable stubbing in the analysis, one must add the attribute `#[kani::stub(<function_name>, <stub_name>)]` to the harness function.
In addition, Kani must be called with options `--enable-unstable --enable-stubbing --harness <harness_name>`.
Note that `--harness` is needed because the stubbing feature is limited to a single harness at the moment.

### An example: stubbing `rand::random`

Let's see a simple example where we use the [`rand::random`](https://docs.rs/rand/latest/rand/fn.random.html) function
to generate an encryption key.

```rust
#[cfg(kani)]
#[kani::proof]
fn encrypt_then_decrypt_is_identity() {
    let data: u32 = kani::any();
    let encryption_key: u32 = rand::random();
    let encrypted_data = data ^ encryption_key;
    let decrypted_data = encrypted_data ^ encryption_key;
    assert_eq!(data, decrypted_data);
}

```

At present, Kani fails to verify this example because its [FFI](https://doc.rust-lang.org/nomicon/ffi.html) support requires improvements (see [issue #1781](https://github.com/model-checking/kani/issues/1781) for more details).
In other words, the code under verification contains unsupported features.

However, the stubbing feature allows us to work around this limitation[^footnote-limitation] as follows:

```rust
#[cfg(kani)]
fn stub_random<T: kani::Arbitrary>() -> T {
    kani::any()
}

#[cfg(kani)]
#[kani::proof]
#[kani::stub(rand::random, stub_random)]
fn encrypt_then_decrypt_is_identity() {
    let data: u32 = kani::any();
    let encryption_key: u32 = rand::random();
    let encrypted_data = data ^ encryption_key;
    let decrypted_data = encrypted_data ^ encryption_key;
    assert_eq!(data, decrypted_data);
}
```

Here, the `#[kani::stub(rand::random, stub_random)]` attribute indicates to Kani that it should replace `rand::random` with the stub `stub_random`.
This is a sound replacement: the value returned by `kani::any` captures all possible `u32` values returned by `rand::random`.

Now, let's run it through Kani:

```bash
cargo kani --enable-unstable --enable-stubbing --harness encrypt_then_decrypt_is_identity
```

The verification result is composed of a single check: the assertion corresponding to `assert_eq!(data, decrypted_data)`.

```
RESULTS:
Check 1: encrypt_then_decrypt_is_identity.assertion.1
         - Status: SUCCESS
         - Description: "assertion failed: data == decrypted_data"
         - Location: src/main.rs:18:5 in function encrypt_then_decrypt_is_identity


SUMMARY:
 ** 0 of 1 failed

VERIFICATION:- SUCCESSFUL
```

Kani verifies the assertion successfully, avoiding any issues that appear if we attempt to verify the code without stubbing.

### Another example: stubbing `factorial`

Let's see another example where we compute [binomial coefficients](https://en.wikipedia.org/wiki/Binomial_coefficient).
This computation is often expressed as `n choose k` (implemented by `choose` in below),
and it represents the number of ways to choose `k` elements from a set of `n` elements.
In this example, we're interested in verifying the property `(n choose k) == (n choose (n - k))`.

Note that `choose` makes use of a recursive `factorial` function that uses the method `checked_mul` to prevent overflow errors.

```rust
fn factorial(n: u64) -> Option<u64> {
    if n == 0 {
        return Some(1);
    }
    n.checked_mul(factorial(n - 1).unwrap())
}

fn choose(n: u64, k: u64) -> u64 {
    let fact_n = factorial(n).unwrap();
    let fact_k = factorial(k).unwrap();
    let fact_n_minus_k = factorial(n - k).unwrap();
    fact_n / (fact_k * fact_n_minus_k)
}

#[cfg(kani)]
#[kani::proof]
#[kani::unwind(22)]
fn verify_choose() {
    let n = kani::any();
    let k = kani::any();
    kani::assume(n < 21);
    kani::assume(k < 21);
    kani::assume(n > k);
    assert_eq!(choose(n, k), choose(n, n - k));
}
```

This example takes more than 15 minutes to verify on an [AWS EC2 `m5a.4xlarge` instance](https://aws.amazon.com/ec2/instance-types/).
The code under verification shows bad performance due to the recursive definition of the `factorial` function.

But we can avoid the recursion by pre-computing the values[^footnote-values] that fit into a `u64` value and replacing `factorial` with another function that gets those values.

```rust
const FACT: [u64; 21] = [
    1,
    1,
    2,
    6,
    24,
    120,
    720,
    5040,
    40320,
    362880,
    3628800,
    39916800,
    479001600,
    6227020800,
    87178291200,
    1307674368000,
    20922789888000,
    355687428096000,
    6402373705728000,
    121645100408832000,
    2432902008176640000,
];

fn factorial(n: u64) -> Option<u64> {
    if n == 0 {
        return Some(1);
    }
    n.checked_mul(factorial(n - 1).unwrap())
}

fn choose(n: u64, k: u64) -> u64 {
    let fact_n = factorial(n).unwrap();
    let fact_k = factorial(k).unwrap();
    let fact_n_minus_k = factorial(n - k).unwrap();
    fact_n / (fact_k * fact_n_minus_k)
}

#[cfg(kani)]
fn stub_factorial(n_64: u64) -> Option<u64> {
    let n = n_64 as usize;
    if n < FACT.len() {
        Some(FACT[n])
    } else {
        None
    }
}

#[cfg(kani)]
#[kani::proof]
#[kani::unwind(22)]
fn verify_choose() {
    let n = kani::any();
    let k = kani::any();
    kani::assume(n > 0 && n < 21);
    kani::assume(k > 0 && k < 21);
    kani::assume(n >= k);
    assert_eq!(choose(n, k), choose(n, n - k));
}
```

Let's run this harness with Kani!

```bash
cargo kani --enable-unstable --enable-stubbing --harness verify_choose
```

```
SUMMARY:
 ** 0 of 10 failed

VERIFICATION:- SUCCESSFUL
Verification Time: 13.64521s
```

Now Kani verifies the example successfully, and in less 15 seconds!
This time, Kani completes the verification faster because our stub avoids recursion altogether.

## Risks of Stubbing

Stubbing is a feature that comes with great power and, as such, it should be used with caution.
It's the developer's responsibility to **ensure that a stub replacing another function soundly models its behavior**.
This is normally not the case in testing, where developers writing *mock-ups* tend to setup a concrete version of an object (an *under-approximation* of the model).

For example, let's suppose you're attempting to stub a call to [`serde_json::from_slice`](https://docs.rs/serde_json/latest/serde_json/de/fn.from_slice.html) in your harness.
This isn't a strange situation since deserialization often leads to bad performance.

```rust
#[derive(Deserialize)]
#[cfg_attr(kani, derive(kani::Arbitrary))]
pub struct MyStruct {
    // -- snip -- 
}

#[cfg(kani)]
fn stub_deserialize<S, T>(_data: &[u8]) -> serde_json::Result<T>
where
    T: kani::Arbitrary,
{
    Ok(kani::any())
}

#[cfg(kani)]
#[kani::proof]
#[kani::stub(serde_json::from_slice, stub_deserialize)]
fn verify_with_deserialization() {
    let data = symbolic_slice();
    let my_struct = serde_json::from_slice::<MyStruct>(&data);
    // -- snip -- 
}
```

Here, we're using `kani::any()` to generate a symbolic `MyStruct`.
This is easy to do since we're deriving `kani::Arbitrary` for `MyStruct`.

In principle, this may look like an **over-approximation** because we generate a symbolic value for `MyStruct`.
But actually, we're missing something:
[`serde_json::Result<T>`](https://docs.rs/serde_json/latest/serde_json/type.Result.html) can also return a `serde_json::Error` if the deserialization fails.
However, our `stub_deserialize` function assumes that this case will never happen!
Therefore, the stub we wrote cannot be considered a **sound model** of `serde_json::from_slice`, and it's dangerous to use it in our harnesses.

We hope this convinces you about the risks of stubbing.
Always keep in mind that stubs are essentially additional assumptions in your harnesses.
Because of that, we recommend our users to only use stubbing when necessary.
Note that you can also write harnesses for your stubs if you need more assurance.

## Considered Designs

The experimentation for this feature mainly focused on the program transformation required for stubbing functions, methods and types.
While the feature had been scoped down to function stubbing, we wanted to keep an eye open for any alternative that allowed us do type stubbing[^footnote-type-stubbing].
For functions and methods, the transformation boils down to replacing all calls to the original function/method with calls to the replacement function/method.

That said, the transformation can also be applied at different stages of the compilation step.
As you may know, the Rust language uses multiple [Intermediate Representations](https://rustc-dev-guide.rust-lang.org/overview.html#intermediate-representations) (IRs) to represent and perform analyses on Rust programs.
In total, we considered five approaches:
 - Conditional compilation[^footnote-conditional]
 - Source-to-source transformation
 - AST-to-AST transformation
 - HIR-to-HIR transformation
 - MIR-to-MIR transformation

In summary, we tried to answer the following question for each approach:

> Does the approach allow stubbing of local/external functions/methods/types?

| | Conditional compilation | Source-to-source transformation | AST-to-AST transformation | HIR-to-HIR transformation | MIR-to-MIR transformation |
| --- | --- | --- | --- | --- | --- |
| Local functions | Yes | Yes | Yes | Yes | Yes |
| Local methods | Yes | Yes | Yes | Yes | Yes |
| Local types | Yes | Yes | Yes | Yes | No |
| External functions | No | Yes | Maybe | Maybe | Yes |
| External methods | No | Yes | Maybe | Maybe | Yes |
| External types | No | Yes | Maybe | Maybe | No |

The main disadvantage of the conditional compilation approach is that it cannot be applied to external code.

In a source-to-source transformation, we'd rewrite the source code before it gets to the compiler.
This approach is the most flexible, allowing us to basically stub any code (functions, methods, types).
However, it requires all source code to be available, and in general it's difficult to work with (e.g., unexpanded macros).

AST-to-AST and HIR-to-HIR transformations are close to the source code, so they're quite flexible too.
The main downside is that they'd require modifications to the Rust compiler (to plug in new AST/HIR passes).
Moreover, they'd introduce new issues while compiling dependencies[^footnote-alternatives].

Therefore, **the approach we followed was the MIR-to-MIR transformation**.
While it doesn't allow stubbing types, the MIR-to-MIR approach presents many advantages:
 * It operates over a relatively simple IR.
 * The Rust compiler already has good support for plugging in MIR-to-MIR transformations.
 * It's possible to integrate this transformation with [concrete playback](https://model-checking.github.io/kani-verifier-blog/2022/09/22/internship-projects-2022-concrete-playback.html).
 * Our team is already familiar with the MIR interface.

## Summary

In this post, we've showed the stubbing feature in action and briefly discussed the designs we considered.
If you enjoyed this post, the [RFC for Function Stubbing](https://model-checking.github.io/kani/rfc/rfcs/0002-function-stubbing.html) includes other topics that you may find interesting:
 * The rules to determine [stub compatibility and validation](https://model-checking.github.io/kani/rfc/rfcs/0002-function-stubbing.html#stub-compatibility-and-validation).
 * A [comparison to function contracts](https://model-checking.github.io/kani/rfc/rfcs/0002-function-stubbing.html#comparison-to-function-contracts).
 * The list of [future possibilities for stubbing](https://model-checking.github.io/kani/rfc/rfcs/0002-function-stubbing.html#future-possibilities).

Please go ahead and try the stubbing feature yourself!

The documentation for stubbing is available [here](https://model-checking.github.io/kani/reference/stubbing.html).
Please let us know if you [find any issues](https://github.com/model-checking/kani/issues/new?assignees=&labels=bug&template=bug_report.md) while
using the feature.

Overall, we had a lot of fun working with [Aaron](https://people.seas.harvard.edu/~bembenek/) on this project, and we're sure
it'll improve Kani's usability in the future!

## References
 1. [RFC for Function Stubbing](https://model-checking.github.io/kani/rfc/rfcs/0002-function-stubbing.html)
 2. [Documentation for Stubbing](https://model-checking.github.io/kani/reference/stubbing.html)

### Footnotes

[^footnote-contracts]: In this case, function contracts are a good alternative to stubbing. You can find a comparison to function contracts in [this section of the RFC for function stubbing](https://model-checking.github.io/kani/rfc/rfcs/0002-function-stubbing.html#comparison-to-function-contracts). Unfortunately, functions contracts aren't available in Kani at the moment.

[^footnote-limitation]: Another option is to supply an alternative implementation for verification using `#[cfg(kani)]`. In fact, this is considered the baseline approach for stubbing. Note, however, that this approach isn't valid for external code.

[^footnote-values]: We only need to pre-compute 21 values because the factorial computation overflows for any value beyond 21.

[^footnote-type-stubbing]: Type stubbing would be a powerful technique to have in Kani. It could allow us to provide verification-friendly stubs for frequently used types (e.g., `Vec`), among many other things.

[^footnote-conditional]: Conditional compilation refers to making use of `#[cfg(kani)]` and `#[cfg(not(kani))]` to guard the code that's used for verification and standard compilation, respectively. Note that we could've used it in [our first example](#an-example-stubbing-randrandom), by specifying `#[cfg(not(kani))]` for the `rand::random` call and `#[cfg(kani)]` for the `kani::any` call.

[^footnote-alternatives]: The advantages and disadvantages of these approaches are better explained in [this section of the RFC for function stubbing](https://model-checking.github.io/kani/rfc/rfcs/0002-function-stubbing.html#rationale-and-alternatives-stubbing-mechanism).
