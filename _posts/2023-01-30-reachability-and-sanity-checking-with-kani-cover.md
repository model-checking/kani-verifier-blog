---
layout: post
title: "Checking Code Reachability and Sanity Checking Proof Harnesses with `kani::cover`"
---

Kani is a verification tool that can help you prove properties about your Rust code.
To learn more about Kani, check out [the Kani tutorial](https://model-checking.github.io/kani/kani-tutorial.html) and our [previous blog posts](https://model-checking.github.io/kani-verifier-blog/).

In today's blog post, we will talk about two applications of the new `kani::cover` macro that was introduced in [Kani 0.18](https://github.com/model-checking/kani/releases/tag/kani-0.18.0):

1. Determining whether certain lines of code are reachable, and generating tests that cover them.
2. Sanity checking proof harnesses to ensure that what they're verifying matches our expectations.

Let's start by explaining what `kani::cover` is.

## What is `kani::cover`?

In a nutshell, `kani::cover` is a macro that instructs Kani to check whether a certain condition at a certain point in the code can be satisfied in at least one execution.
For each `kani::cover` call, Kani analyzes the code and arrives at one of two possible outcomes:

1. It finds a possible execution of the program that satisfies the condition
2. It proves that no such execution is possible

Let's go through an example.
Suppose we'd like to find out if there's a 16-bit integer greater than 8 whose cube, computed with wrapping multiplication, can yield the value 8.
We can write a harness with `kani::cover` to find out the answer:

```rust
#[kani::proof]
fn cube_value() {
    let x: u16 = kani::any();
    let x_cubed = x.wrapping_mul(x).wrapping_mul(x);
    if x > 8 {
        kani::cover!(x_cubed == 8);
    }
}
```

If we run Kani on this example, it tells us that the cover property is satisfiable:

```bash
$ kani test.rs
Checking harness cube_value...
# -- snip --
RESULTS:
Check 1: cube_value.cover.1
         - Status: SATISFIED
         - Description: "cover condition: x_cubed == 8"
         - Location: test.rs:6:9 in function cube_value


SUMMARY:
 ** 1 of 1 cover properties satisfied
```

meaning that there is indeed a 16-bit integer that satisfies this condition.
We can use Kani's [concrete playback feature](https://model-checking.github.io/kani-verifier-blog/2022/09/22/internship-projects-2022-concrete-playback.html) to find a particular value, which will give us one of the following values: 16386, 32770, or 49154.

On the other hand, if we ask the same question replacing 8 with 4 or 27, Kani will tell us that no 16-bit integer satisfies this condition:

```rust
#[kani::proof]
fn cube_value() {
    let x: u16 = kani::any();
    let x_cubed = x.wrapping_mul(x).wrapping_mul(x);
    if x > 27 {
        kani::cover!(x_cubed == 27);
    }
}
```

```
RESULTS:
Check 1: cube_value.cover.1
         - Status: UNSATISFIABLE
         - Description: "cover condition: x_cubed == 27"
         - Location: test.rs:6:9 in function cube_value


SUMMARY:
 ** 0 of 1 cover properties satisfied
```

Thus, Kani along with `kani::cover` can help us answer such questions.

The examples given in [previous blog posts](https://model-checking.github.io/kani-verifier-blog/) primarily relied on Rust's `assert` macro to express properties for Kani.
Is there a relationship between `assert` and `kani::cover`?
The next section addresses this question.

## How does `kani::cover` relate to `assert`?

Let's look at how Kani interprets `kani::cover` and `assert`:

* As explained above, for `kani::cover!(condition)`, Kani checks if there's an execution that satisfies `condition` --- in which case, the cover property is satisfiable, or concludes that no such execution exists --- in which case the cover property is unsatisfiable.
* On the other hand, for `assert!(condition)`, Kani checks if there's an execution that *violates* `condition` --- in which case, the assertion fails, or concludes that no such input value exists --- in which case the assertion holds.

These descriptions sound very similar, don't they?
Indeed, they are just inverses of each other!
In fact, Kani more or less models `kani::cover!(condition)` as `assert!(!condition)` under the hood (with some caveats).
If it finds an execution that violates the assertion (i.e. causes `!condition` to be false), then this execution satisfies the condition, and hence the cover property.
If on the other hand, it proves that no such execution can cause the assertion to be violated, then it has proven that the cover property is unsatisfiable!

Let's go through a couple of applications of `kani::cover` to see how it can be used in practice.

## Application 1: Using `kani::cover` to check code reachability

While developing and reviewing code, we sometimes spot certain branches in the code that we're not certain if they're reachable.
The following code snippet gives one such example where it's not clear whether `construct_ip` can return a localhost IPv6 address:

```rust
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};

fn process_ip(host_id: u8) {
    let ip: IpAddr = construct_ip(host_id);
    match ip {
        IpAddr::V4(v4_addr) => {
            if v4_addr == Ipv4Addr::LOCALHOST {
                // ...
            } else {
                // ...
            }
        }
        IpAddr::V6(v6_addr) => {
            if v6_addr == Ipv6Addr::LOCALHOST {
                // Do we expect to ever receive a localhost V6 address?
            } else {
                // ...
            }
        }
    }
}
```

If we have [code coverage](https://en.wikipedia.org/wiki/Code_coverage) set up, we can check if there are tests that hit that line of code.
But if there aren't, or if we don't run code coverage, how do we determine if this condition is possible?
Kani along with `kani::cover` can help answer this question.

The way we go about this is to write a harness that invokes the code in question and inject a `kani::cover` call at the line of code we want to reach, e.g.:

```rust
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};

fn process_ip(host_id: u8) {
    let ip: IpAddr = construct_ip(host_id);
    match ip {
        IpAddr::V4(v4_addr) => {
            if v4_addr == Ipv4Addr::LOCALHOST {
                // ...
            } else {
                // ...
            }
        }
        IpAddr::V6(v6_addr) => {
            if v6_addr == Ipv6Addr::LOCALHOST {
                // Do we expect to ever receive a localhost V6 address?
               kani::cover!(); // <------ Check if this line is reachable
            } else {
                // ...
            }
        }
    }
}

#[kani::proof]
fn kani_cover_harness() {
    let host_id: u8 = kani::any();
    process_ip(host_id);   
}
```

Notice that we've used `kani::cover!()` without an argument, which is a shorthand for `kani::cover!(true)`.

If we run Kani on this harness, we can get one of two possible outcomes:

1. Kani reports the cover property to be unreachable, which indicates that `construct_ip` can never return a localhost V6 address for any `host_id`.
Since our harness covers the whole input space of `construct_ip`, we can conclude that the code under this branch is dead.
In this case, one could place an `unreachable!()` call at that line to enable the compiler to optimize this branch out, or replace the entire if condition with an assertion, e.g.

```rust
        IpAddr::V6(v6_addr) => {
            assert_ne!(v6_addr, Ipv6Addr::LOCALHOST);
            // handle non-localhost IPs
            // ...
        }
```

2. Kani reports the cover property to be satisfiable.
In this case, one can use Kani's [concrete playback](https://model-checking.github.io/kani-verifier-blog/2022/09/22/internship-projects-2022-concrete-playback.html) feature to extract a unit test that covers this line, thereby increasing code coverage.

## Application 2: Using `kani::cover` to sanity check proof harnesses

A green "Verification Successful" outcome from Kani is always pleasant to see, as it indicates that all properties in a harness were proven.
However, it sometimes leaves a person with doubts on whether the proof harness they wrote is *vacuous*, e.g. does it cover the entire input space of the function under verification?
For example, for an array input, does the proof harness include the case of an empty array?
Or for an input that is a pair of integers, does the harness permit them to have the same value?

The `kani::cover` macro can help answer these questions.
Let's go through an example to clarify what we mean by that.

Suppose we're given a function to verify that generates arrays of a given size such that *every slice* of the array satisfies the following property: the last element of the slice is greater than or equal to the sum of all the previous elements in the slice.
For instance, the following array satisfies this property: `[5, 5, 20, 32]` because:

* For the `[5, 5, 20, 32]` slice, `5 + 5 + 20 <= 32`. 
* For the `[5, 5, 20]` and `[5, 20, 32]` slices , `5 + 5 <= 20` and `5 + 20 <= 32`.
* For the `[5, 5]`, `[5, 20]`, and `[20, 32]` slices, `5 <= 5`, `5 <= 20`, and `20 <= 32.`
* The property also holds trivially for all slices of length 0 and 1.

Suppose we want to verify this function with Kani.
Assuming its signature is as follows:

```rust
fn generate_array_with_sum_property<const N: usize>(seed: i32) -> [i32; N]
```

we can write a harness for N = 5 that looks as follows:

```rust
#[kani::proof]
#[kani::unwind(5)]
fn check_generate_array_with_sum_property() {
    // 1. Call the function to generate an array passing it any seed value
    let arr: [i32; 5] = generate_array_with_sum_property(kani::any());
    // 2. Create any slice of the array
    let slice = any_slice(&arr);
    // 3. Verify that the slice satisfies the sum property
    assert!(sum_property_holds_for_slice(slice));
}
```

where `sum_property_holds_for_slice` can be implemented as follows:

```rust
fn sum_property_holds_for_slice(s: &[i32]) -> bool {
    // slices of length 0 and 1 trivially satisfy the property
    if s.is_empty() || s.len() == 1 {
        return true;
    }
    // compute the sum of all elements except for the last
    let mut sum = 0;
    for i in 0..s.len() - 1 {
        sum += s[i];
    }
    // return whether the sum is smaller than or equal to the last element
    sum <= *s.last().unwrap()
}
```

The question now is: how do we implement the `any_slice` function, such that it can return any possible slice of the provided array?
Here's one possible implementation:

```rust
fn any_slice(arr: &[i32]) -> &[i32] {
    let start: usize = kani::any();
    let end: usize = kani::any();
    kani::assume(end < arr.len());
    kani::assume(start <= end);
    &arr[start..end]
}
```

The implementation assigns both the start and end of the slice to `kani::any()`.
It then applies two constraints to `start` and `end` using `kani::assume`:

1. The first assumption restricts `end` to be less than the length of the array so that the ranges are within the array bounds.
2. The second assumption restricts `start` to be less than or equal to `end` to rule out invalid ranges.

Finally, it returns the slice of the array between `start` and `end`.

We're now ready to run Kani.
Suppose we do, and we get the reassuring "Verification Successful" message.
This might leave us wondering: does `any_slice` really cover all possible slices of the given array?
This is where `kani::cover` can help.

We can use `kani::cover` to check whether `any_slice` can generate some of the cases we expect it to.
If it can't, that typically means that the proof harness may not be covering all the possible space of inputs that you intend it to cover.
An example of what `kani::cover` can be used for is to check whether `any_slice` *can* return an empty slice.
The updated harness is as follows:

```rust
    let arr: [i32; 5] = generate_array_with_sum_property(kani::any());
    let slice = any_slice(&arr);
    kani::cover!(slice.is_empty());  // <---- Check if slice can be empty
    assert!(sum_property_holds_for_slice(slice));
```

If we run Kani, we get the following:

```
SUMMARY:
 ** 0 of 75 failed

 ** 1 of 1 cover properties satisfied

VERIFICATION:- SUCCESSFUL
```

which tells us that Kani found an input value that resulted in `any_slice` returning an empty slice.
Indeed, we can easily see that `start == 0` and `end == 0` satisfy both assumptions and result in an empty slice.

Another interesting corner case is whether `any_slice` can return a slice that spans the entire array.
We can easily check this case using `kani::cover` as follows:

```rust
    let arr: [i32; 5] = generate_array_with_sum_property(kani::any());
    let slice = any_slice(&arr);
    kani::cover!(slice.is_empty());
    kani::cover!(slice.len() == arr.len()); // <------ Check if slice can span entire array
    assert!(sum_property_holds_for_slice(slice));
```

If we run the updated harness with Kani, we get the following result:

```
 ** 1 of 2 cover properties satisfied
```

Oh, oh! Kani found the new cover property to be unsatisfiable! We can find the specific unsatisfiable cover property by looking at the results section, which will have:

```
Check 2: check_generate_array_with_sum_property.cover.2
         - Status: UNSATISFIABLE
         - Description: "cover condition: slice.len() == arr.len()"
         - Location: test.rs:18:5 in function check_generate_array_with_sum_property
```

This result indicates that `any_slice` cannot return a slice with the full length of the array.
Thus, our proof harness may miss bugs in `generate_array_with_sum_property`!
Indeed, if `generate_array_with_sum_property` were to return an array that doesn't satisfy the property, e.g. `[5, 8, 20, 57, 70]`, (due to the `[20, 57, 70]` slice), verification still succeeds!

```rust
#[kani::proof]
#[kani::unwind(5)]
fn check_generate_array_with_sum_property() {
    let arr: [i32; 5] = generate_array_with_sum_property(kani::any());
    let arr = [5, 8, 20, 57, 70];
    let slice = any_slice(&arr);
    kani::cover!(slice.is_empty());
    kani::cover!(slice.len() == arr.len());
    assert!(sum_property_holds_for_slice(slice));
}
```

```

SUMMARY:
 ** 0 of 75 failed (1 unreachable)

 ** 1 of 2 cover properties satisfied

VERIFICATION:- SUCCESSFUL
```

How did this happen?
The bug is in `any_slice`, specifically due to those two lines:

```rust
    kani::assume(end < arr.len());
    &arr[start..end]
```

The assumption is intended to guarantee that the range falls within the array.
However, the function uses the "half-open" [range](https://doc.rust-lang.org/std/ops/struct.Range.html), which excludes the `end`, thus, the returned slice can never include the last element of the array!
This is an example of *overconstraining*, where the harness rules out inputs of interest (in this case slices that span the entire array), causing the proof to be incomplete.

There are two ways to fix `any_slice`.
We can either relax the assumption to use "less than or equal" instead of the strict "less than", or we can use the [inclusive range](https://doc.rust-lang.org/std/ops/struct.RangeInclusive.html).
Let's do the latter.
The updated function is as follows:

```rust
fn any_slice(arr: &[i32]) -> &[i32] {
    let start: usize = kani::any();
    let end: usize = kani::any();
    kani::assume(end < arr.len());
    kani::assume(start <= end);
    &arr[start..=end]  // <-------- Notice the new equal sign before `end`
}
```

If we rerun Kani, we get the following result:

```
 ** 0 of 83 failed (1 unreachable)

 ** 1 of 2 cover properties satisfied

VERIFICATION:- SUCCESSFUL
```

What?! Why is a cover property still unsatisfiable, and which one is it?
The detailed results section indicates that this time, the `slice.is_empty()` condition is the one that is unsatisfiable:

```
RESULTS:
Check 1: check_generate_array_with_sum_property.cover.1
         - Status: UNSATISFIABLE
         - Description: "cover condition: slice.is_empty()"
         - Location: blog_example.rs:17:5 in function check_generate_array_with_sum_property

Check 2: check_generate_array_with_sum_property.cover.2
         - Status: SATISFIED
         - Description: "cover condition: slice.len() == arr.len()"
         - Location: blog_example.rs:18:5 in function check_generate_array_with_sum_property
```

Indeed, since we switched to using the inclusive range (`start..=end`), it is no longer possible to return an empty slice, this time because of the second assumption, `kani::assume(start <= end)` since an empty slice using the inclusive range is only possible if `start > end`.
So this time, the first cover property we wrote saved us!
We can fix this by relaxing the assumption.
The updated `any_slice` becomes:

```rust
fn any_slice(arr: &[i32]) -> &[i32] {
    let start: usize = kani::any();
    let end: usize = kani::any();
    kani::assume(end < arr.len());
    kani::assume(start <= end + 1);
    &arr[start..=end]
}
```

Alternatively, we can revert to using the half-open range, and relax the first assumption as follows:

```rust
fn any_slice(arr: &[i32]) -> &[i32] {
    let start: usize = kani::any();
    let end: usize = kani::any();
    kani::assume(end <= arr.len()); // <-------- Use less than or equal
    kani::assume(start <= end);
    &arr[start..end]
}
```

With either of the last two `any_slice` implementations, if we rerun Kani, both cover properties are satisfied:

```
 ** 2 of 2 cover properties satisfied
```

and verification is successful.
Also, if we use an array the doesn't satisfy the property (e.g. `[5, 8, 20, 57, 70]`), verification will fail as expected:

```
 Failed Checks: assertion failed: sum_property_holds_for_slice(slice)
 File: "/home/ubuntu/examples/cover/blog_example.rs", line 20, in check_generate_array_with_sum_property
```

We can easily add more cover properties that check for other cases of interest, e.g. all possible slice lengths between 0 and 5.

## Summary

In this post, we discussed two applications of the `kani::cover` macro. We'd like to hear your feedback on it, and whether there are related features you would like to see implemented to allow you to make good use of `kani::cover`.

## References:

1. Cover Statement RFC: https://model-checking.github.io/kani/rfc/rfcs/0003-cover-statement.html
2. Documentation for `kani::cover`: https://model-checking.github.io/kani/crates/doc/kani/macro.cover.html
