---
layout: post
title: "How Kani helped find bugs in Hifitime"
---

Hifitime is a scientifically accurate time management library that provides nanosecond precision of durations and time computations for 65 thousand years, just as suitable for desktop applications as for embedded processors without a floating point unit (FPU). The purpose of this blog post is to show how Kani helped solve a number of important non-trivial bugs in hifitime.

For completeness' sake, let's start with [an introduction of the notion of time](#why-time-matters), how hifitime [avoids loss of precision](#avoiding-loss-of-precision), and finally [why Kani is crucial](#importance-of-kani-in-hifitime) to ensuring the correctness of hifitime.

## Why time matters

_Time is just counting subdivisions of the second, it's a trivial and solved problem._ Well, it's not quite trivial, and often incorrectly solved.

As explained in "Beyond Measure" by James Vincent, measuring the passing of time has been important for societies for millennia. From using the flow of the Nile River to measure the passage of a year, to tracking the position of the Sun in the sky to delimit the start and end of a day, the definition of the time has changed quite a bit. 

On Earth, humans follow a local time, which is supposed to be relatively close to the idea that noon is when the Sun is at its height in the sky for the day. We've also decided that the divisions of time must be fixed: for example, an hour lasts 3600 seconds regardless of whether it's 01:00 or 14:00. If we only follow this fixed definition of an hour, then time drifts because the Earth does not in fact complete a full rotation on itself in _exactly_ 23 hours 56 minutes and 4.091 seconds (that's the duration of a sidereal day). For "human time" (Universal Coordinated Time, `UTC`) to catch up with the time with respect to the stars (`UT1`), we regularly introduce "leap seconds." Like leap years, where we introduce an extra day every fourth year (with rare exceptions), leap seconds introduce an extra seconds _every so often_, as [announced by the IERS](https://www.ietf.org/timezones/data/leap-seconds.list). When scientists report to the IERS that the Earth is about to drift quite a bit compared to `UTC`, IERS announces that on a given day at least six months in the future, there will be an extra second in that day to allow for the rotation of the Earth to catch up. In practice, this typically means that UTC clocks "stop" the time for one second: this means UTC is _not_ a continuous time scale: that second we didn't count in UTC still happened for the universe! As the Standards Of Fundamental Astronomy (SOFA) eloquently puts it:

> Leap seconds pose tricky problems for software writers, and consequently there are concerns that these events put safety-critical systems at risk. The correct solution is for designers to base such systems on TAI or some other glitch-free time scale, not UTC, but this option is often overlooked until it is too late.
> -- "SOFA Time Scales and Calendar Tools", Document version 1.61, section 3.5.1

<img src="{{site.baseurl | prepend: site.url}}/assets/images/utc-time-scale-drift.png" alt="UTC drifts with respect to other time scales" />

Luckily there a few glitch-free time scales to choose from. Hifitime uses TAI, the international atomic time. This allows quick synchronization with UTC time because both UTC and TAI "tick" at the same rate as they are both Earth based time scales. In fact, with general relativity, we understand that time is affected by gravity fields. This causes the additional problem that a second does not tick with the same frequency on Earth as it does in the vacuum between Mars and Jupiter (which is more than twice as far apart as Mars is from the Sun by the way). As such, the position of planets published by NASA JPL are provided in a time scale in which the influence of the gravity of Earth has been removed and where the "ticks" of one second are fixed at the solar system barycenter: the Dynamic Barycentric Time (TDB) time scale.

<img src="{{site.baseurl | prepend: site.url}}/assets/images/tai-vs-et-vs-tdb.png" alt="TT is fixed to TAI but TDB and ET are periodic" />


## Avoiding loss of precision

The precision of floating point values is constrained by its representation in the processor. Moreover, some microcontrollers do not have a floating point unit (FPU), meaning that any floating point operation is emulated through software, adding a considerable number of CPU cycles for any computation.

Dates, or "epochs," are _simply_ the duration past a certain reference epoch. Operations on these epochs, like adding 26.7 days, will cause rounding errors (even sometimes in a single operations like on this [`f32`](https://play.rust-lang.org/?version=stable&mode=debug&edition=2018&gist=b760579f103b7192c20413ebbe167b90)).

Time scales have different reference epochs, and to correctly convert between different time scales, we must ensure that we don't lose any precision in the computation of these offsets. That's especially important given that one of the most common scales in astronomy is the Julian Date, whose reference epoch is 4713 BC (or -4712). Storing such a number with an `f64` would lead to very large rounding errors.

Hence, to avoid loss of precision, hifitime stores all durations as a tuple of the number of centuries and the number of nanoseconds into this century. For example `(0, 1)` is a duration of one nanosecond. Then, the Epoch is a structure containing the TAI duration since the TAI reference epoch of 01 January 1900 at noon and the time scale in which the Epoch was initialized. ([_Maybe_ hifitime should be even more precise?](https://github.com/nyx-space/hifitime/issues/186))

## Importance of Kani in hifitime

The purpose of hifitime is to convert between time scales, and these drift apart from each other. Time scales are only used for scientific computations, so it's important to correctly compute the conversion between these time scales. As previously discussed, for ensure exactly one nanosecond precision, hifitime stores durations as a tuple of integers, as these aren't affected by successive rounding errors. The drawback of this approach is that we now have to rewrite the arithmetics of durations and get it right!

This is where Kani comes in very handy. From its definition, Durations have a minimum and maximum value. On an unsigned 64 bit integer, we can store enough nanoseconds for four full centuries a bit. But we want want normalize all operations such that the nanosecond counter stays within one century (until we're reached the maximum number of centuries). Centuries are stored in a _signed_ 16 bit integer, and are the only field that store whether the duration is positive or negative.

At first sight, it seems like a relatively simple task to make sure that this math is correct. It turns out that lots of bug may happen near the min and max durations, and when performing operations between very large and very small durations. Kani has helped fix at least eight different categories of bugs in a single pull request: <https://github.com/nyx-space/hifitime/pull/192>. Most of these were bugs near the boundaries of a Duration definition: around the zero, maximum, and minimum durations. But many of the bugs were on important and common operations: partial equality, negation, addition, and subtraction operations.

One of the great things of Kani is that it doesn't require explicitly exhaustive tests. In fact, Kani operates on the mid-layer representation. It then solves for satifiability: "can this operation ever be executed, and if so, what are the cases where it may cause issues."

Thanks to how Kani analyzes a program, tests can either be bounded or not. A bounded test includes an assertion: execute a set of instructions and then check something. This is a typical test case.

Kani can also have unbounded tests where there is no explicit condition to check. Instead, only the successive operations of a function call are executed, and each are tested by Kani for failure cases by analyzing the inputs and finding cases where inputs will lead to runtime errors like overflows. This approach is how most of the bugs in hifitime have been found.

Unbounded tests effectively ensure that sanity of the operations in a given function call. Bounded tests provide the same while also checking equalities. If either of these tests fail, Kani can provide a test failure report outlining the sequence of operations, and the binary representation of each intermediate operation, to help the developer gain an understanding of why their implementation is incorrect.

The overhead to implement tests in Kani is very low, and the benefits are immense. Basically, write a Kani verification like a unit test, run the model verifier, and you've formally verified this part of the code. Amazing!