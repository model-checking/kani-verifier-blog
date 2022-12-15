---
layout: post
title: "Easily verify your Rust in CI with Kani and Github Actions "
---

Formal verification tools, such as Kani, are valuable because they provide a way to definitively check, using mathematical techniques, whether a property of your code is true under all circumstances.  To put it colloquially: testing is great for catching the FIRST bug, formal verification is great for knowing you’ve caught the LAST bug.  

Code, however, is seldom static. As code evolves, how can we ensure that it remains correct; i.e. how do we catch the NEXT bug? In the testing world, this is where **Continuous Integration** (CI) shines: by ensuring that tests are re-run on all code-changes, CI enables developers to catch bugs before they impact users.  Many platforms, such as GitHub, provide facilities to automatically incorporate CI into existing development workflows.  For example, [GitHub Actions](https://github.com/features/actions) provides developers with a facility to run checks, ranging from tests, to linters, to code-formatters, and have the results displayed on on the pull request (PR) in real time.  Repositories can even [require that certain checks pass before merging a PR](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/defining-the-mergeability-of-pull-requests/about-protected-branches#require-status-checks-before-merging).  For example, on our own Kani repo, a CI status report on a PR might look like this:

<img src="{{site.baseurl | prepend: site.url}}/assets/images/kani-ci-checks.png" alt="Kani CI Checks" />

Similarly, **Continuous Verification** enables developers to prevent regressions before they happen. Kani users have asked us for an easy way to integrate continuous verification into their existing development workflows. To this end, we are excited to announce the [Kani Rust Verifier Action](https://github.com/marketplace/actions/kani-rust-verifier) on the GitHub Marketplace.

## How to use the Kani GitHub action

If you have a [Rust Cargo](https://doc.rust-lang.org/cargo/) project in a GitHub repo, using the Kani CI action as simple as adding it to your `ci.yaml` file, where `<MAJOR>.<MINOR>` is the version of Kani you wish to use.  

To get the latest version, visit the [kani verifier action](https://github.com/marketplace/actions/kani-rust-verifier) on the marketplace, and click on the green “Use Latest Version” button, which will give you a yaml snippet you can paste into your `.yml` file.
<img src="{{site.baseurl | prepend: site.url}}/assets/images/kani-verifier-action.png" alt="Kani Verifier Action on GitHub Marketplace" />

For example, for kani 0.17, your `kani-ci.yml` file might look like this:

```yaml
name: Kani CI
on:
  pull_request:
  push:
jobs:
  run-kani:
    runs-on: ubuntu-20.04
    steps:
      - name: 'Checkout your code.'
        uses: actions/checkout@v3

# You can get the latest version from
# https://github.com/marketplace/actions/kani-rust-verifier
      - name: 'Run Kani on your code.'
        uses: model-checking/kani-github-action@v0.17
```

For more advanced use cases, we provide facilities to override the working directory, as well as to configure the Kani command itself. For example, the [s2n-quic](https://github.com/aws/s2n-quic) project uses [the following CI configuration](https://github.com/aws/s2n-quic/blob/main/.github/workflows/ci.yml#L613), which overrides the working directory, and enables the `--tests` option of `cargo kani`.

<img src="{{site.baseurl | prepend: site.url}}/assets/images/s2n-quic-using-kani-action.png" alt="How s2n quic integrates the Kani action" />

For full details, consult [the documentation](https://model-checking.github.io/kani/install-github-ci.html)

## When to run the Kani action

One question we have received from our users is “When should we run the Kani action?”  Is it better to run it on every PR, once on a PR right before merge, or nightly?  The answer is an emphatic “it depends!”.  The great thing about  GitHub Actions are that you can use them in the way that best fits your workflow.  Our experience is that the sooner verification runs, the better: it’s easier to debug and fix issues when they’re found right away, rather than after they’re merged.  Our experience is that many Kani proofs can complete quickly on standard CI hardware.  Proofs that run in a similar time-frame to existing tests make sense to run on a similar cadence, e.g. on every pull request or code-push.

Some proofs, on the other hand, may be memory and compute intensive.  In these cases, your organization may prefer nightly jobs to reduce cost and avoid introducing latency to the PR process.  Our suggestion is to start with running proofs on every pull request, but start moving some of them to a separate nightly run if they begin to take too much time.

## Caveats 

The Kani GitHub action executes on standard GitHub Action runners. By default, these machines are [not particularly powerful](https://docs.github.com/en/actions/using-github-hosted-runners/about-github-hosted-runners#supported-runners-and-hardware-resources): (7GB of RAM, 2 core processors).  Formal verification can be memory and compute intensive: if you find the Kani action running out of memory and CPU, we suggest using [large runners](https://docs.github.com/en/actions/using-github-hosted-runners/using-larger-runners) or [AWS CodeBuild](https://aws.amazon.com/codebuild/).

To test drive Kani yourself, check out our [“getting started” guide](https://model-checking.github.io/kani/getting-started.html). We have a one-step install process and examples, so you can try proving your code today.  If you are running into issues with Kani or have feature requests or suggestions, we’d [love to hear from you](https://github.com/model-checking/kani/issues).
