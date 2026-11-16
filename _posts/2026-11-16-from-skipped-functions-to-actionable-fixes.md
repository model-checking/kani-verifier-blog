---
title: "From Skipped Functions to Actionable Fixes: Understanding Kani AutoHarness"
layout: post
---
Authors: [Aryan Arun](https://github.com/acearyanarun), [Srivatsan Samraj](https://github.com/srivatsansamraj), [Yanjun Chen](https://github.com/CYJ904), [Tianshu Huang](https://github.com/Tianshu-Huang), [Jieyou Zhao](https://github.com/wodex1nhaoIeng)

Imagine asking a tool to check thousands of functions for programming errors. Some functions pass verification, some produce failures, and others are never checked at all.

Why would a verification tool skip a function?

That question came up during our Carnegie Mellon University practicum with the Kani team, where we have been evaluating automatic verification on Rust’s standard library. The reasons behind skipped functions are useful. They show where automation works today, where it needs help, and what kinds of changes could make more code checkable.

## A quick introduction to Kani and AutoHarness

Rust’s compiler prevents many memory-safety errors, but Rust programs can still panic or contain mistakes. [Kani is a verification tool](https://model-checking.github.io/kani/) that analyzes Rust code for properties such as the absence of panics, arithmetic overflows, and certain kinds of undefined behavior.

To check a function, Kani typically needs a proof harness: a short piece of Rust code that calls the function with symbolic inputs. Unlike an ordinary test that runs with a few chosen values, symbolic inputs let Kani reason about many possible values at once, subject to the model and any bounds used.

For example, consider this small Rust function:

```rust
fn is_even(value: u8) -> bool {
    value % 2 == 0
}
```

Someone could write a harness that supplies an arbitrary `u8` and asks Kani to check the resulting execution. For simple functions, much of that setup is repetitive. AutoHarness attempts to generate suitable harnesses automatically, reducing the manual work required to begin verification.

Now imagine trying that process across the Rust standard library. It contains many different functions, input types, and language features. Some are straightforward to prepare for verification while others are not.

## A skipped function has not failed verification

This distinction matters. When AutoHarness skips a function, it generally means that it could not generate an eligible harness under the current configuration and tool support. It does not mean that the function is buggy or unsafe.

Likewise, creating a harness is only the start. Once verification runs, Kani may establish the checked properties, report a failure that needs investigation, or run out of time or resources. A reported failure also needs interpretation: it might reflect a genuine counterexample, a modeling problem, an insufficient bound, or another tool limitation.

There are two different questions:

1. Can AutoHarness prepare this function for verification?
2. If verification runs, can Kani establish the properties being checked?

Counting generated harnesses answers the first question. It does not automatically answer the second.

## Why are some functions skipped?

During our standard-library evaluation, the team examined reasons reported for functions that AutoHarness could not handle. We organized related limitations into [tracked issues](https://github.com/model-checking/kani/issues/4879), including these recurring categories:

- Missing `Arbitrary` support: AutoHarness does not know how to create a suitable input of a required type.
- Generic functions: A function works with multiple types, and AutoHarness could not find a concrete type that satisfies the function’s requirements.
- Non-`usize` const generics: A function depends on a compile-time value that the current automatic setup does not support.
- Requires bounded arguments: An input, such as a string, can only be generated up to a size limit, and that mode must be enabled with an extra option.
- No function body: The available declaration does not contain an implementation body for Kani to inspect directly.

AutoHarness reports only the first reason it finds, so a function in one category may have other blockers too.

These are not five kinds of Rust bugs. They are different explanations for why automatic verification did not start. They also suggest different next steps: adding input-generation support, choosing a concrete type, enabling bounded generation, or determining whether analyzable code is available.

A list of skipped functions alone says little about what to fix. A list grouped by root cause is much easier to investigate. Our team used these categories to organize and discuss work. The skip reasons themselves come from AutoHarness; our categories group them so related work can be tracked together.

## Turning limitations into an engineering roadmap

At standard-library scale, manually inspecting every skipped function would be cumbersome. Grouping results by reason lets engineers ask better questions:

- Are many functions blocked by the same missing input type?
- Would better generic instantiation help many functions or only one unusual case?
- Is a function skipped because a feature is missing, or because an existing option was not enabled?
- After a change, did more functions become eligible and did those new harnesses actually verify?

The final question is especially important. We can rerun evaluations and compare results, but comparisons need clearly identified revisions, settings, and run dates. Otherwise, a change in harness counts might reflect a different Rust snapshot or configuration rather than an AutoHarness improvement.

This reveals a broader lesson about automation. A tool’s ability to explain why it could not do something can be as valuable as a success report. Useful diagnostics turn a large, ambiguous gap into smaller problems that developers can investigate, reproduce, and fix.

## What comes next?

AutoHarness continues to evolve, including work on more input types and language features. Some limitations can be addressed by improving automatic generation; others need new verification techniques or a more carefully defined verification scope.

Our experience with the Rust standard library suggests that progress should be measured in two ways: what AutoHarness can prepare for verification, and what Kani can actually verify. Understanding skipped functions helps with the first step and creates a more informed path toward the second.

A skipped function is not a failed proof. It is a clue about what the verification workflow needs next.
