---
title: AutoHarness
layout: project
summary: "Automatic generation of proof harnesses with the <code>kani autoharness</code> subcommand."
status: Experimental
leads: '<a href="https://github.com/feliperodri">@feliperodri</a>'
milestone: https://github.com/model-checking/kani/milestone/33
milestone_title: Autoharness
---
## Overview

AutoHarness is Kani's automatic harness generation feature, exposed through the `autoharness` subcommand
(`cargo kani autoharness -Z autoharness`). Kani scans a crate for functions whose arguments all implement
the `kani::Arbitrary` trait, generates a proof harness for each, and runs them. The generated harnesses are
internal to Kani: it makes no changes to your source code. Where a function has a function contract or loop
contracts, Kani verifies those instead.

## Motivation

Many proof harnesses follow a predictable format: to verify a function `foo`, create arbitrary values for
each of its arguments and call `foo` on them. AutoHarness automates writing that boilerplate so that users
can start verifying a crate without first writing harnesses by hand.

## Goals

The goal of AutoHarness is to fully automate the proof harness workflow proposed in
[Code-Level Model Checking in the Software Development Workflow](https://cdn.amazon.science/d0/de/cbec0b4547e3ae7ff077f8aa978f/code-level-model-checking-in-thesoftware-development-workflow.pdf).
Users should be able to run Kani on their entire crate and immediately see:

- what can be verified out of the box, and which guarantees that gives them;
- what needs contracts before it can be verified;
- what hits Kani's limitations, and why.

## Current Work

The feature is experimental and enabled with `-Z autoharness`. Active and completed work is tracked in the
[Autoharness milestone](https://github.com/model-checking/kani/milestone/33) and the
[tracking issue (#3832)](https://github.com/model-checking/kani/issues/3832). Refer to those for current
status rather than this page.

## Resources

- [Automatic Harness Generation](https://model-checking.github.io/kani/reference/experimental/autoharness.html) in the Kani Book
- [Tracking issue #3832: Automatic Harnesses](https://github.com/model-checking/kani/issues/3832)
- [Autoharness GitHub milestone](https://github.com/model-checking/kani/milestone/33)

## Get Involved

- Try `kani autoharness` on your crate and report problems or ideas as [GitHub issues](https://github.com/model-checking/kani/issues).
- Pick up or comment on work in the [Autoharness milestone](https://github.com/model-checking/kani/milestone/33).
- Read the [Kani developer documentation](https://model-checking.github.io/kani/dev-documentation.html) before contributing.
- See [Contact]({{ "/contact/" | relative_url }}) for where to discuss.
