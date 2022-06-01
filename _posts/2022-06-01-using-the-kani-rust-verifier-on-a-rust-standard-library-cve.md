---
layout: post
title:  "Using the Kani Rust Verifier on a Rust Standard Library CVE"
---

In this post we'll apply the [Kani Rust Verifier](https://github.com/model-checking/kani) (or Kani for short), our open-source formal verification tool that can prove properties about Rust code, to an example from the [Rust Standard Library](https://doc.rust-lang.org/std/).
We will look at a [CVE (Common Vulnerability and Exposure) from 2018](https://cve.mitre.org/cgi-bin/cvename.cgi?name=%20CVE-2018-1000657).
First we will show how Kani can find the issue and secondly we discuss ways to be assured that the fix appropriately addresses the problem.

At its heart this CVE is a memory safety issue in the implementation for `VecDeque`: a double-ended queue implemented as a dynamically resizable ring buffer.
Using the `VecDeque` API in a specific way used to be able to cause out-of-bounds memory accesses.
The [original issue](https://github.com/rust-lang/rust/issues/44800) gives a good write-up and there is another great explanation  by [Yechan Bae](https://gts3.org/2019/cve-2018-1000657.html) who gives a proof-of-concept to reproduce the issue.
To keep this post self-contained, we'll also explain the issue before diving into using Kani.
If you're familiar with CVE-2018-1000657 then feel free to skip ahead!

  - [Reproducing CVE-2018-1000657](#reproducing-cve-2018-1000657)
  - [Background: `VecDeque`](#background-vecdeque)
  - [Working through the CVE step-by-step](#working-through-the-cve-step-by-step)
  - [Fixing the CVE](#fixing-the-cve)
  - [Using Kani](#using-kani)
    - [Caveats](#caveats)
    - [Finding the issue](#finding-the-issue)
    - [Bounded results](#bounded-results)
    - [Going further](#going-further)
  - [Summary](#summary)

## Reproducing CVE-2018-1000657

Thanks to `rustup`, reproducing the issue is straightforward.
We can rollback to an old version of the Rust toolchain, compile a small example and run it using [valgrind](https://valgrind.org/), a binary instrumentation framework that can detect memory issues.

```bash
$ rustup install nightly-2017-09-23
$ rustup override set nightly-2017-09-23
$ cat issue44800.rs && rustc issue44800.rs && valgrind ./issue44800
// file: issue44800.rs
// Example from https://github.com/rust-lang/rust/issues/44800 with a smaller queue size
#![feature(global_allocator, alloc_system, allocator_api)]
extern crate alloc_system;

use std::collections::VecDeque;
use alloc_system::System;

#[global_allocator]
static ALLOCATOR: System = System;

fn main() {
    let mut q = VecDeque::with_capacity(7);
    q.push_front(0);
    q.reserve(6);
    q.push_back(0);
}
# --snip--
==234600== Invalid write of size 4
# --snip--
```

The program creates a new `VecDeque` and then calls `3` API functions: `push_front` and `reserve` and `push_back`.
The error is unexpected: none of these operations should cause an out-of-bounds access detected by valgrind, which warns of an "invalid write".
[You may be wondering about the use of the `System` allocator---this is *not* necessary to trigger the memory issue but *is* needed to enable `valgrind` to detect the issue.]
What's going on inside these calls?
Let's dive into the implementation of `VecDeque`.

## Background: `VecDeque`

Let's start with the "shape" of a `VecDeque<T,A>`.
The type parameter `T` is the type of element that can be queued.
In this post, we will ignore zero-sized types (ZSTs) which are special-cased in the implementation.
`A` is the allocator responsible for heap allocations and can be swapped out if needed, such as on embedded systems.
By default this uses the global allocator.
Internally, a queue is a buffer `buf` (a dynamically resizable vector) with a `tail` and `head`, which are used to index into `buf`.

```rust
// https://doc.rust-lang.org/stable/src/alloc/collections/vec_deque/mod.rs.html#94
struct VecDeque<T, A: Allocator = Global> {
    tail: usize,
    head: usize,
    buf: RawVec<T, A>,
}

// https://doc.rust-lang.org/src/alloc/raw_vec.rs.html#52
struct RawVec<T, A: Allocator = Global> {
    ptr: Unique<T>,
    cap: usize,
    alloc: A,
}
```

Here's an example of a `VecDeque` with capacity `8` and currently filled with `4` elements `[a, b, c, d]`.
We denote unused slots by "`.`".
Valid elements are in slots between the `tail` and `head` (denoted by "`T`" and "`H`") and can wrap around the end of the buffer.

```
    H       T
[ a . . . . d c b ]
  0 1 2 3 4 5 6 7
```

There's one more important thing you need to know about `VecDeque`, which is that it has two notions of *capacity*.
A decision to make when designing a ring buffer is how to distinguish between the empty and full states (when `head == tail`).

```
Is this queue empty?
    H
    T
[ . . . . . . . . ]
  0 1 2 3 4 5 6 7

Or full?
    H
    T
[ o o o o o o o o ]
  0 1 2 3 4 5 6 7
```

To resolve this ambiguity between empty and full states, the implementation of `VecDeque` reserves one empty slot so that the queue is:

  - empty when `head == tail`
  - full when `(head + 1) % cap == tail` (i.e., the head is adjacent to the tail, modulo wraparound)

```
This queue is empty
    H
    T
[ . . . . . . . . ]
  0 1 2 3 4 5 6 7

This queue is full (one slot reserved)
      H T
[ o o . o o o o o ]
  0 1 2 3 4 5 6 7
```

Importantly this means the usable capacity of a `VecDeque` available to clients is one-less than the capacity of its internal buffer.
In this post, we will call these the *usable capacity* and *buffer capacity* of a queue.
For a queue `q` they correspond to `q.capacity()` and `q.cap()`, respectively.
[Only the former is a public method; `q.cap()` is private.]

## Working through the CVE step-by-step

Now we understand the shape of a `VecDeque`, let's work through our example:

```rust
let mut q = VecDeque::with_capacity(7);
q.push_front(0);
q.reserve(6); //< issue here
q.push_back(0);
```

The method `with_capacity` creates a new queue with an initial *usable capacity* of `7`.
This results in an allocation of `buf` with a *buffer capacity* of `8`.[^footnote-with_capacity]
The queue is empty with `head == tail == 0` so the heap looks like:

```
  H
  T
[ . . . . . . . . ]
  0 1 2 3 4 5 6 7
```

Next is a [`push_front`](https://doc.rust-lang.org/src/alloc/collections/vec_deque/mod.rs.html#1520) operation.
This shifts the `tail` "to the left" by decrementing it by one (and wrapping around to the end of the buffer, if necessary) and then writing the element into the slot that `tail` now indexes.[^footnote-tail]
After this operation, the heap looks like:

```
  H             T
[ . . . . . . . o ]
  0 1 2 3 4 5 6 7
```

Now we come to the crux of the issue.
The method `reserve(6)` should ensure that at least `6` more elements can be inserted.
This should be a no-op since there is already sufficient space (the *usable capacity* is `7` with `1` slot in use).
However, as we shall see, the result of this method is a queue with `head` indexing one element past the end of `buf`.
Any subsequent read or write to the buffer at this `head` index is an out-of-bounds memory access.
For example, we can force a write to this index with a call to `push_back()`.

```
                T H (indexes out-of-bounds of buffer)
[ . . . . . . . o ]
  0 1 2 3 4 5 6 7
```

Let's look at the implementation of `reserve`, which we've annotated with the values that will be computed for our example:

```rust
pub fn reserve(&mut self, additional: usize) {
    let old_cap = self.cap();      // == 8 (buffer capacity)
    let used_cap = self.len() + 1; // == 2 (used slots including reserved slot)
    let new_cap = used_cap         // == 8 (required buffer capacity)
        .checked_add(additional)
        .and_then(|needed_cap| needed_cap.checked_next_power_of_two())
        .expect("capacity overflow");

    if new_cap > self.capacity() { // == 8 > 7 (taken)
        self.buf.reserve_exact(used_cap, new_cap - used_cap);
        unsafe {
            self.handle_capacity_increase(old_cap);
        }
    }
}
```

The problematic line is `new_cap > self.capacity()`.

  - `new_cap` is the required *buffer capacity* to ensure that `6` more elements can be inserted.
  Since no resize is necessary this is `8`.
  - However `self.capacity()` is the *usable capacity* of the queue, which is `7`.

Because of this mismatch the branch is taken.
We will not dive into the code for `self.buf.reserve_exact()`, but importantly, it is a no-op.
The buffer does not grow and remains at capacity `8`.

Finally, let's look at `handle_capacity_increase` which updates `head` or `tail` to account for a larger buffer.
In particular, the method ensures that elements are contiguous (modulo wraparound).
We've annotated the code with the values that will be computed for this example: case B is taken (since `self.head == 0` and `old_capacity - self.tail == 8 - 7 == 1`).
The call to `copy_nonoverlapping` does not move any elements and the `head` index is incremented by `8`, which is not in-bounds of `buf`.

```rust
/// Frobs the head and tail sections around to handle the fact that we
/// just reallocated. Unsafe because it trusts old_capacity.
unsafe fn handle_capacity_increase(&mut self, old_capacity: usize) {
    let new_capacity = self.cap();                   // == 8 (buffer capacity)

    if self.tail <= self.head {                      // == 7 <= 0 (not taken))
        // A
        // Nop
    } else if self.head < old_capacity - self.tail { // == 0 < (8 - 7) (taken)
        // B
        unsafe {
            self.copy_nonoverlapping(old_capacity, 0, self.head);
        }
        self.head += old_capacity;                   // self.head set to 0 + 8 == 8 (out-of-bounds)
        debug_assert!(self.head > self.tail);
    } else {
        // C
        let new_tail = new_capacity - (old_capacity - self.tail);
        unsafe {
            self.copy_nonoverlapping(new_tail, self.tail, old_capacity - self.tail);
        }
        self.tail = new_tail;
        debug_assert!(self.head < self.tail);
    }
    debug_assert!(self.head < self.cap());
    debug_assert!(self.tail < self.cap());
    debug_assert!(self.cap().count_ones() == 1);
}
```

It is interesting to note that there is a `debug_assert` that checks that the new `head` is less-than the buffer capacity.
This would catch the issue.
However, debug asserts are only enabled in debug builds.

### Representation invariants

In fact, these last three `debug_asserts` (that `head` and `tail` index in-bounds and that the buffer capacity is a power of two) are properties that we would like to *always hold* for any `VecDeque` instance.
These kinds of property are known as *representation invariants*.
Ideally we would like to know that all API methods *maintain* these properties meaning that if the method is called on an instance that satisfies the invariant then the instance still satisfies the invariant *after* the method returns.
[One subtlety is that a representation invariant may be temporarily broken within a method as long as it is fixed by the return of the call.]
We will return to this idea when we use Kani!

<details markdown=block><summary markdown=span>Aside on `handle_capacity_increase`</summary>

Here's how the method works normally.
There's a useful [comment in the implementation](https://doc.rust-lang.org/src/alloc/collections/vec_deque/mod.rs.html#455) that gives cases for handling a buffer capacity increase from `8` to `16`:

  - Case A: no change to `head` or `tail` is required (and no copying of elements) because the elements are still contiguous in the larger buffer

    ```
    Before:
     T             H
    [o o o o o o o . ]

    After:
     T             H
    [o o o o o o o . . . . . . . . . ]
                     ^^^^^^^^^^^^^^^ new slots
    ```

  - Case B: the `head` is updated if the "prefix" of the buffer is the shorter sequence

    ```
    Before:
         H T
    [o o . o o o o o ]
     ^^^ will be copied
    
    After:
           T             H
    [. . . o o o o o o o . . . . . . ]
                     ^^^ copied
                     ^^^^^^^^^^^^^^^ new slots
    ```

  - Case C: the `tail` is updated if the "suffix" of the buffer is the shorter sequence

    ```
    Before:
               H T
    [o o o o o . o o ]
                 ^^^ will be copied

    After:
               H                 T
    [o o o o o . . . . . . . . . o o ]
                                 ^^^ copied
                     ^^^^^^^^^^^^^^^ new slots
    ```

</details>

## Fixing the CVE

Now that we've identified the issue, fixing it is straightforward.
Note that this doesn't mean that finding the issue is straightforward!
The underlying problem is that `reserve` uses both the buffer capacity and the usable capacity to test whether a resize is necessary.
This should be changed to use one or the other.
In this case, the [fix](https://github.com/sfackler/rust/commit/9733463d2b141a166bfa2f55ec316066ab0f71b6) is to use the buffer capacity, uniformly.
For our running example, this means the branch is not-taken, as expected.

```rust
pub fn reserve(&mut self, additional: usize) {
    let old_cap = self.cap();      // == 8 (buffer capacity)
    let used_cap = self.len() + 1; // == 2 (used slots including reserved slot)
    let new_cap = used_cap         // == 8 (required buffer capacity)
        .checked_add(additional)
        .and_then(|needed_cap| needed_cap.checked_next_power_of_two())
        .expect("capacity overflow");

    if new_cap > old_cap {         // == 8 > 8 (not-taken) [FIXED LINE]
        self.buf.reserve_exact(used_cap, new_cap - used_cap);
        unsafe {
            self.handle_capacity_increase(old_cap);
        }
    }
}
```

With this change our running example no longer has a memory safety issue.
This is good!
But even better, would be a way we could know that the memory safety issue is removed for all possible uses of `reserve`.
This is trickier because `VecDeque` is parametric (there are many types that we can instantiate for `T`) and, moreover, we have to consider all possible buffer capacities.
Enumerating through all the possibilities isn't feasible.

## Using Kani

Let's see how Kani can help.

### Caveats

It's important to note that it's much easier to find an issue when you know it is there.
In particular, it allows us to analyze a minimal example with Kani.

Another caveat is that we simplified the reproducibility of the issue.
The CVE was found in an old version (v1.20) of the Rust Standard Library (and subsequently fixed in newer versions).
Although compiling old versions of the library with newer compilers is possible, in practice the library and compiler are developed in-tandem.
Kani itself relies on a recent version of the Rust compiler (to parse Rust programs into the Mid-level Intermediate Representation).
So to get around this, we extracted two versions of the `VecDeque` implementation into a standalone crate.
The versions are identical except that we apply a single-line patch to simulate the original problem in one.
In this way, we can link proof harnesses against a version of `VecDeque` with and without the CVE.
All the code for this post is available in [Kani's test directory](https://github.com/model-checking/kani/tree/main/tests/cargo-kani/vecdeque-cve) with instructions on reproducing the results.

### Finding the issue

Let's begin by seeing how Kani reports the error for our minimized example.
This harness is linked against the version of `VecDeque` with the CVE.

```rust
#[kani::proof]
pub fn minimal_example_with_cve_should_fail() {
    let mut q = VecDeque::with_capacity(7);
    q.push_front(0);
    q.reserve(6);
    q.push_back(0);
}
```

In a few seconds, Kani reports an error:

```bash
$ cargo kani --harness minimal_example_with_cve_should_fail --output-format terse
# --snip--
Failed Checks: assertion failed: self.head < self.cap()
 File: "vecdeque-cve/src/cve.rs", line 190, in cve::VecDeque::<T, A>::handle_capacity_increase

VERIFICATION:- FAILED
```

This is the `debug_assert` that we pointed out in `handle_capacity_increase`.
In Kani these asserts are also checked.
If we'd like to continue the analysis past a debug assert we can disable them to see Kani report a similar error reported by `valgrind`:


```bash
$ RUSTFLAGS='--cfg disable_debug_asserts' cargo kani --harness minimal_example_with_cve_should_fail --output-format terse
# --snip--
Failed Checks: dereference failure: pointer outside object bounds
 File: "vecdeque-cve/src/cve.rs", line 103, in cve::VecDeque::<T, A>::buffer_write

VERIFICATION:- FAILED
```

Now let's use Kani with the fixed version of `VecDeque`.
This time, Kani reports no issues, which gives us some confidence that the fix has properly addressed the problem.

```bash
$ cargo kani --harness minimal_example_with_cve_fixed --output-format terse
# --snip--
VERIFICATION:- SUCCESSFUL
```

### Bounded results

In [our announcement post]({% post_url 2022-05-04-announcing-the-kani-rust-verifier-project %}#enter-kani) we introduced Kani [`any<T>()`](https://model-checking.github.io/kani/tutorial-nondeterministic-variables.html).
This is a feature that informally generates "any `T` value".
This is not the same as a randomly chosen concrete value (as in fuzzing) but rather a *symbolic* value that represents any possible value of the appropriate type.
The key idea is that we can use `any` in a Kani harness to verify the behavior of our code with respect to all possible values of an input (rather than having to exhaustively enumerate them).

A natural way we might try to use this feature is to make some of our input parameters symbolic.
In this way, we want to have confidence that the fix properly addresses the problem for any sized queue (but still fixed for `T == u32`).

```rust
#[kani::proof]
pub fn symbolic_example_with_cve_fixed {
    let usable_capacity = kani::any();
    let mut q = VecDeque::with_capacity(usable_capacity);
    q.push_front(0);
    let additional = kani::any();
    q.reserve(additional);
    q.push_back(0);
}
```

Unfortunately, using this harness currently results in Kani timing out (no answer after 10 minutes).
Under the hood, Kani uses techniques based on logic and automated reasoning solvers, known as SAT solvers.
Although SAT solvers are increasingly powerful the "satisfiability" problem that these solvers address is fundamentally hard (an [NP-complete problem](https://en.wikipedia.org/wiki/NP-completeness)) so timeouts are sometimes an unavoidable reality.
If you'd like to understand more about this problem then check out this [Amazon Science blog post](https://www.amazon.science/blog/a-gentle-introduction-to-automated-reasoning), which is a gentle introduction to automated reasoning.

### Going further

Now let's return to the question we had earlier about how we could know that the memory safety issue is removed for *all* possible uses of `reserve`.
That is for a `VecDeque` instance with any type `T` and any buffer capacity.

One way forward would be to use a more powerful tool such as [Creusot](https://github.com/xldenis/creusot) or [Prusti](https://www.pm.inf.ethz.ch/research/prusti.html), which are both *deductive verifiers* which allow us to use special annotations to help the solver.

However, in this case, we can use two neat ideas to get the same result with Kani.
The first idea is to exploit the fact that `VecDeque` is parametric (or generic) with respect to the type `T`.
Importantly, this means the implementation cannot make assumptions about what you can do with a value of type `T`.
This is a general observation for collections like sets, vectors or queues because they *should not* be inspecting the values of the items they are storing.
[This idea is known as [*parametricity*](https://en.wikipedia.org/wiki/Parametricity).]

Because of this, we can use a second idea to *abstract* the `VecDeque` in the following way.
We will throw away the contents of the vector!
All we will keep is the length of the underlying vector.
Anytime we enqueue an item we will apply the appropriate updates to the metadata (such as the `head` and `tail`) but we will effectively "throwaway" the value.
Anytime we pop an item we will return a symbolic value.
This is, of course, not a sensible implementation that you would want to use in a program (who wants a queue that you enqueue `5` and returns `42`?) but it *is* useful for verification purposes.
The idea is that our abstract version of a `VecDeque` *over-approximates* a real `VecDeque`.
This means that if we can prove a result with our abstract queue then the result also holds for the real implementation.
Here's what our verification-only `AbstractVecDeque` looks like:

```rust
//
// Based on src/alloc/collections/vec_deque/mod.rs
//
// Generic type T is implicit (but we assume it is not a ZST)
// We don't model alloc type A
struct AbstractVecDeque {
    tail: usize,
    head: usize,
    buf: AbstractRawVec,
}

//
// Based on src/alloc/raw_vec.rs
//
// Generic type T is implicit (but we assume it is not a ZST)
struct AbstractRawVec {
    /* ptr: Unique<T> removed */
    cap: usize,
    /* alloc: A removed */
}
```

Notice that we only keep the `head`, `tail` and `cap` (buffer capacity).
Everything else is removed.
Importantly, *for the purposes of the memory safety issue* these are the only details that matter.

In our discussion of the CVE, we introduced the idea of a [*representation invariant*](#representation-invariants): a property that we expect to hold for any queue instance.
A representation invariant tells us when a queue is *well-formed*.
This is the case if the buffer capacity is a (nonzero) power of two and if the `head` and `tail ` index within the buffer.
[Recall that these properties are precisely the ones checked using `debug_assert` in `handle_capacity_increase`.]
In Kani, we have a trait `Invariant` that allows us to express when a type `T` is well-formed.
Implementing this trait enables Kani to generate a well-formed symbolic value of type `T` using `kani::any::<T>()`.
The trait is `unsafe` because it is our responsibility to ensure we've covered all the cases.

```rust
unsafe impl kani::Invariant for AbstractVecDeque {
    fn is_valid(&self) -> bool {
        self.tail < self.cap() && self.head < self.cap() && is_nonzero_pow2(self.cap())
    }
}
```

Next we import (by-hand) the implementation for `reserve` plus any methods that are called, which includes `reserve_exact` for `AbstractRawVec` and `handle_capacity_increase`.
We abstract any parts of the implementation that deal with the contents of the buffer.
For example, when we resize the underlying vector, we don't call any allocator methods but instead *only* increment the `buf.cap`.
Similarly in `handle_capacity_increase` there are calls to [`copy_nonoverlapping()`](https://doc.rust-lang.org/stable/src/alloc/collections/vec_deque/mod.rs.html#275) to copy parts of the buffer to ensure elements remain contiguous modulo wraparound.
In our abstract implementation this copy operation is a no-op.

Now we can use Kani to ask whether it is the case that if we have a well-formed abstract queue and we call `reserve` then the queue remains well-formed.
In essence, we are asking whether `reserve` maintains our *representation invariant*.

```rust
#[kani::proof]
pub fn abstract_reserve_maintains_invariant_with_cve() {
    let mut q: AbstractVecDeque = kani::any();
    assert!(q.is_valid());
    let used_cap = q.len() + 1;
    let additional: usize = kani::any();
    q.reserve_with_cve(additional);
    assert!(q.is_valid());
}
```

Given this harness, Kani returns a problem that `reserve` can panic.
The problem is that a large enough `additional` amount can cause a `usize` wraparound and the `reserve` implementation panics if this is the case.
One way to deal with this is to make this condition explicit.
We can add a constraint that `additional` must not cause wraparound.

```rust
#[kani::proof]
pub fn abstract_reserve_maintains_invariant_with_cve() {
    let mut q: AbstractVecDeque = kani::any();
    assert!(q.is_valid());
    let used_cap = q.len() + 1;
    let additional: usize = kani::any();
    kani::assume(no_capacity_overflow(used_cap, additional));
    q.reserve_with_cve(additional);
    assert!(q.is_valid());
}

fn no_capacity_overflow(used_cap: usize, additional: usize) -> bool {
    used_cap
        .checked_add(additional)
        .and_then(|needed_cap| needed_cap.checked_next_power_of_two())
        .is_some()
}
```

Now Kani verifies this harness successfully.
The result we've proven is that our `AbstractVecDeque` maintains an invariant property that `reserve` preserves well-formedness (under the precondition that the requested `additional` amount does not give rise to `usize` overflow).
Why does this matter?
Firstly, using our abstract implementation means that this property holds for any sized queue.
We are no longer restricted to bounded results.
Secondly, using parametricity, we can generalize the result to hold for a `VecDeque` of any `T`.
This gives us strong evidence that the fix works as we expect.

## Summary

In this post we examined a CVE in `VecDeque` from the Rust Standard Library.
We used Kani to both find the issue and give us confidence that the fix is correct.
Then, using ideas from the verification community we showed a way using abstraction that we could get stronger guarantees.

To test drive Kani yourself, check out our [“getting started” guide](https://model-checking.github.io/kani/getting-started.html).
We have a one-step install process and examples, including all the code in this post with instructions on reproducing the results yourself, so you can try proving your code today.

Look out for a follow up post where we'll use Kani on an example from the [Firecracker virtual machine monitor](https://firecracker-microvm.github.io/).

## Further Reading

  - [CVE-2018-1000657](https://cve.mitre.org/cgi-bin/cvename.cgi?name=%20CVE-2018-1000657)
  - [The original issue with a failing test case](https://github.com/rust-lang/rust/issues/44800)
  - [Explanation of the CVE by Yechan Bae](https://gts3.org/2019/cve-2018-1000657.html)
  - [More on representation invariants (lecture 8)](https://ocw.mit.edu/courses/6-170-laboratory-in-software-engineering-fall-2005/pages/lecture-notes/)
  - [Code and instructions for reproducing the results in this post](https://github.com/model-checking/kani/tree/main/tests/cargo-kani/vecdeque-cve)

## Footnotes

[^footnote-with_capacity]: The method `with_capacity(x)` calls [`with_capacity_in(x)`](https://doc.rust-lang.org/src/alloc/collections/vec_deque/mod.rs.html#557) which allocates the next power of two larger than or equal to `x+1`

[^footnote-tail]: Moving the `tail` to update the front of the queue might seem a little strange, but the queue is double-ended so it has two "normal" modes of operation: `push_back` / `pop_front` or `push_front` / `pop_back`, which update the `head` / `tail` and `tail` / `head`, respectively.
