---
layout: post
title: "How Kani helped find bugs in Hifitime"
---

Hifitime is a scientifically accurate time management library that provides nanosecond precision of time durations and time computations for 65 thousand years, just as suitable for desktop applications as for embedded processors without a floating point unit (FPU). The purpose of this blog post is to show how Kani helped solve a number of important non-trivial bugs in Hifitime. For completeness' sake, let's start with a quick introduction of the notion of time, and what is slightly different about scientific time compared to "human time".

## Why time matters

_Time is just counting subdivisions of the second, it's a trivial and solved problem._ Well, it's not quite trivial, and often incorrectly solved.

As explained in "Beyond Measure" by James Vincent, measuring the passing of time has been important for societies since they arose. From using the flow of the Nile River to measure the passage of a year, to tracking the position of the Sun in the sky to delimit the start and end of a day, the definition of the time has changed quite a bit. 

On Earth, humans follow a local time, which is supposed to be relatively close to the idea that noon is when the Sun is at its height in the sky for the day. We've also decided that the divisions of time must be fixed: for example, an hour lasts 3600 seconds regardless of whether it's 01:00 or 14:00. If we only follow this, then time drifts because the Earth does not in fact complete a full rotation on itself in _exactly_ 23 hours 56 minutes and 4.091 seconds. For "human time" (Universal Coordinated Time, `UTC`) to catch up with the time with respect to the stars (`UT1`), we regularly introduce "leap seconds." Like leap years, where we introduce an extra day every fourth year, leap seconds introduce an extra seconds _every so often_, as [announced by the IERS](https://www.ietf.org/timezones/data/leap-seconds.list). When scientists report to the IERS that the Earth is about to drift quite a bit compared to UTC, IERS announces at least six month in advance that at a given day, a given day will have extra second to catch up. In practice, this typically means that UTC clocks "stop" the time for one second: this means UTC is _not_ a continuous time scale, that second we didn't count in UTC still happened for the universe! As the Standards Of Fundamental Astronomy (SOFA) eloquently puts it:

> Leap seconds pose tricky problems for software writers, and consequently there are concerns that these events put safety-critical systems at risk. The correct solution is for designers to base such systems on TAI or some other glitch-free time scale, not UTC, but this option is often overlooked until it is too late.
> -- "SOFA Time Scales and Calendar Tools", Document version 1.61, section 3.5.1

<img src="{{site.baseurl | prepend: site.url}}/assets/images/utc-time-scale-drift.png" alt="UTC drifts with respect to other time scales" />

Luckily there a few glitch free time scales to choose from. Hifitime uses TAI, the international atomic time. This allows quick synchronization with UTC time because both UTC and TAI "tick" at the same rate as they are both Earth based time scales. In fact, with general relativity, we understand that time is affected by gravity fields. This causes the additional problem that a second does not tick with the same frequency on Earth as it does in the vacuum between Mars and Jupiter (which which are as far apart as Mars is from the Sun). As such, the position of planets published by NASA JPL are provided in a time scale in which the influence of the gravity of Earth has been removed and where the "ticks" are fixed at the solar system barycenter: the Dynamic Barycentric Time (TDB) time scale.

<img src="{{site.baseurl | prepend: site.url}}/assets/images/tai-vs-et-vs-tdb.png" alt="TT is fixed to TAI but TDB and ET are periodic" />


## Support for dates way in the past and way in the future

Hifitime stores durations as a tuple... 

Formal verification tools like Kani check that certain classes of bugs will not occur in your program under any circumstance.
Kani uses mathematical techniques to explore your code over all inputs, meaning that while testing is a great way to catch the *first* bug, formally verifying your code with Kani is a great way to validate that you've caught the *last* bug.
To learn more about Kani, and how you can use it to prevent bugs in your Rust code, you can [read the Kani documentation](https://model-checking.github.io/kani/), or [consult the real-world examples on our blog]({{site.baseurl | prepend: site.url}}).

Code, however, is seldom static.
As code evolves, how can we ensure that it remains correct; i.e. how do we catch the *next* bug?
Many codebases already contain test suites and other checks that can run automatically.
Developers can use a platform like [GitHub Actions](https://github.com/features/actions) to run these tests upon every code change, as part of continuous integration, and even [ensure that the tests pass before the code can be merged](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/defining-the-mergeability-of-pull-requests/about-protected-branches#require-status-checks-before-merging).
This assures developers that a code change does not introduce a bug for inputs covered by the test suite.

For developers looking for a higher assurance of software quality, Kani proofs can be validated automatically as part of continuous integration.
To this end, we are excited to announce the [Kani Rust Verifier Action](https://github.com/marketplace/actions/kani-rust-verifier) on the GitHub Marketplace.

## How to use the Kani GitHub action

If you have a [Rust Cargo](https://doc.rust-lang.org/cargo/) project in a GitHub repo, using the Kani CI action is as simple as adding it to your GitHub Actions workflow file.
Your Kani checks will appear as part of the same workflow as your existing tests, as shown in this [s2n-quic](https://github.com/aws/s2n-quic) CI report:

<img src="{{site.baseurl | prepend: site.url}}/assets/images/kani-in-s2n-quic-ci.png" alt="s2n-quic CI report showing both tests and Kani proofs verified on a pull request" />

To get the latest version, visit the [Kani Verifier action](https://github.com/marketplace/actions/kani-rust-verifier) on the marketplace, and click on the green "Use Latest Version" button, which will give you a yaml snippet you can paste into your `.yml` file.
<img src="{{site.baseurl | prepend: site.url}}/assets/images/kani-verifier-action.png" alt="A list of tests and checks run on a pull request as part of continuous integration, with all checks required and passing" />

For example, for Kani 0.17, your `kani-ci.yml` file might look like this:

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

For more advanced use cases, we provide facilities to override the working directory, as well as to configure the Kani command itself.
For example, the [s2n-quic](https://github.com/aws/s2n-quic) project uses [the following CI configuration](https://github.com/aws/s2n-quic/blob/c221530beb37addf81c7ed58461a945750a1b251/.github/workflows/ci.yml#L613), which overrides the working directory, and enables the `--tests` option of `cargo kani`.

```yaml
on:
  push:
    branches:
      - main
  pull_request:
    branches:
      - main
# ...
jobs:
  kani:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
        with:
          submodules: true

      - name: Kani run
        uses: model-checking/kani-github-action@v0.17
        with:
          working-directory: quic/s2n-quic-core
          args: --tests
```

For full details, consult [the documentation](https://model-checking.github.io/kani/install-github-ci.html).

## When to run the Kani action

CI systems such as GitHub Actions offer multiple options for when workflows, such as the Kani action, should execute.
Options include validating every push to every PR, validating once on a PR right before merge, or validating on a fixed time interval, such as nightly. 
In general, the sooner verification runs, the better: it’s easier to debug and fix issues when they’re found right away, rather than after they’re merged.

Our experience is that many Kani proofs can complete quickly on standard CI hardware.
Proofs that run in a similar time-frame to existing tests make sense to run on a similar cadence, e.g.
if you run your unit-tests on every code-push, then validate your Kani proofs on every code-push as well.

Some proofs, on the other hand, may be memory and compute intensive.
In these cases, your organization may prefer nightly jobs to reduce cost and avoid introducing latency to the PR process.
Our suggestion is to start with running proofs on every pull request, but start moving some of them to a separate nightly run if they begin to take too much time.

## Caveats 

The Kani GitHub Action executes on standard GitHub Action Runners; these machines [provide 7GB of RAM and 2 processing cores](https://docs.github.com/en/actions/using-github-hosted-runners/about-github-hosted-runners#supported-runners-and-hardware-resources).
Formal verification can be memory and compute intensive: if you find the Kani action running out of memory and CPU, we suggest using [large runners](https://docs.github.com/en/actions/using-github-hosted-runners/using-larger-runners) or [AWS CodeBuild](https://aws.amazon.com/codebuild/).

To test drive Kani yourself, check out our [“getting started” guide](https://model-checking.github.io/kani/getting-started.html).
We have a one-step install process and examples, so you can start proving your code today.
If you are running into issues with Kani or have feature requests or suggestions, we’d [love to hear from you](https://github.com/model-checking/kani/issues).
