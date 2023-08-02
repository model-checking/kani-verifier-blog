---
layout: post
title:  "Turbocharging Rust Code Verification"
---

Kani is a bit-precise model checker that can verify properties about your Rust code.

To learn more about Kani, check out the [Kani tutorial](https://model-checking.github.io/kani/kani-tutorial.html) and our [previous blog posts](https://model-checking.github.io/kani-verifier-blog/).

Over the past 9 months we have optimised Kani at different levels to either improve general performance or solve some specific performance problems encountered on user verification harnesses.

In this post, we'll discuss three optimizations enabled through three different components of Kani. In short:

- By allowing the selection of the specific SAT solver (globally or per harness) we can obtain consistent speedups of 2x-8x and up to 200x on specific harnesses, and an 85% reduction in total runtime on crate like [s2n-quic-core](https://github.com/aws/s2n-quic/tree/main/quic/s2n-quic-core);
- By adding a new GOTO program serializer that exports files in CBMC's own binary format, we obtain a consistent x4 speedup on the GOTO code generation + export step;
- By improving constant propagation in CBMC for union types, Kani can now solve in a few seconds verification harnesses that used to explode in time and memory.

Compared to the last version of 2022, the current version of Kani (August 2023) is swifter and solves more problems in less time.

But before diving into the details of each new feature and optimization, we'll start with a high-level overview of Kani's architecture.

## Kani Architecture Overview

First, let's briefly introduce you to Kani's high level architecture to understand where modifications were performed.

Kani can be invoked either directly on a file using `kani my_file.rs` or on a whole package or crate via `cargo kani` (see usage [here]( https://model-checking.github.io/kani/usage.html)). In both cases the verification process is very similar and Kani will execute until it can check all harnesses found in the code, and it will report whether each harnesses was successfully verified or failed.

Internally, this verification process is a bit more complicated, and can be split into three main stages:

1. **Compilation:** The Rust crate under verification and its dependencies are compiled into a program in a format that's more suitable to verification.
2. **Symbolic execution:** This program is then symbolically executed in order to generate a single logic formula that represents all possible execution paths and the properties to be checked.
3. **Satisfiability solving:** This logic formula is then solved by employing a SAT or SMT solver that either finds a combination of concrete values that can satisfy the formula (a counterexample to a property exists), or prove that no assignment can satisfy the formula (all properties hold).

In fact, Kani employs a collection of tools to perform the different stages of the verification.
Kani's main process is called `kani-driver`, and its main purpose is to orchestrate the execution and communication of these other tools:

1. The compilation stage is done mostly[^build-details] by `kani-compiler`, which is an extension of the Rust compiler that we have developed. `kani-compiler` will generate a `goto-program` by combining all the logic that is reachable from a harness.
2. For the symbolic execution stage Kani invokes [CBMC](https://www.cprover.org/cbmc/).
3. The satisfiability checking stage is performed by CBMC itself, by invoking a [satisfiability (SAT) solver](https://en.wikipedia.org/wiki/SAT_solver) such as [MiniSat](http://minisat.se/).


Finally, Kani ships with a crate (named `kani`) that provides a set of APIs that defines attributes, functions, traits and implementations that allow users to create and customize their harnesses. This crate is automatically added as a dependency to every other crate Kani compiles.

![Kani architecture](/kani-verifier-blog/assets/images/kani-high-level.png)

Note that the verification problem is computationally hard. Thus, some optimizations can have a positive effect only on a subset of harnesses, while other optimizations can bring benefits overall. Kani was designed to provide a good out-of-the box experience, but also to allow experimentation and further customization to achieve an optimal performance for each harness.

[^build-details]: To verify [Cargo](https://doc.rust-lang.org/stable/cargo/) packages, Kani employs Cargo to correctly build all the dependencies before translating them to GOTO programs.

## Supporting Multiple SAT Solvers

SAT solving is typically the most time-consuming part of a Kani run. There is a large number of SAT solvers available, whose performance can vary widely depending on the specific type of formula, and it can be very helpful to be able to try different SAT solvers on the same problem to determine which one performs best.

By default, CBMC uses the [MiniSat](http://minisat.se/) SAT solver.
While CBMC can be configured to use a different SAT solver at build time, having to rebuild it to switch SAT solvers is inconvenient.
Thus, we introduced an enhancement to CBMC's build system that allows CBMC to be built with multiple SAT solvers, so that the user can select one of them at _runtime_ via an option (`--sat-solver`)[^1].

With this enhancement in CBMC, and to ease the selection of the SAT solver for Kani users, we've introduced a Kani attribute, `kani::solver`, that can be used to specify the SAT solver to use for each harness.
We've also introduced a global command-line switch, `--solver <SOLVER>`, that overrides the harness `kani::solver` attribute.

For instance, one can configure a Kani harness to use [CaDiCaL](https://github.com/arminbiere/cadical) as follows:

```rust
#[kani::proof]
#[kani::solver(cadical)] // <--- Use CaDiCaL for this harness
fn my_harness() { ... }
```

Changing the solver can result in orders of magnitude performance difference. Thus, we encourage users to try different solvers to find the one that performs the best on their harness. At the time of writing, the following three solvers are supported out of the box by Kani: `minisat` (the default solver [Minisat](https://github.com/niklasso/minisat)), `cadical` ([Cadical](https://github.com/arminbiere/cadical)), and `kissat` ([Kissat](https://github.com/arminbiere/kissat)). Kani also allows using other SAT solvers available as standalone binaries in your system `PATH`. This can be done using:

```rust
#[kani::solver(bin="<SAT_SOLVER_BINARY>")]
```

An example of a SAT solver that we've found effective for certain classes of programs (e.g. ones involving cryptographic operations) is [CryptoMiniSat](https://github.com/msoos/cryptominisat). After installing CryptoMiniSat and adding the binary to your path, you can configure a Kani harness to use it via:

```rust
#[kani::solver(bin="cryptominisat5")]
```

The graphs below show a comparison of the runtimes in seconds obtained using the global `--solver` switch with MiniSat, CaDiCaL and Kissat on the Kani harnesses in the [`s2n-quic`](https://github.com/aws/s2n-quic) repository, with a timeout of 30 minutes.

The comparison was done using Kani 0.33.0 and CBMC 5.88.1.

![Minisat vs Cadical](/kani-verifier-blog/assets/images/cadical.png)
![Minisat vs Kissat](/kani-verifier-blog/assets/images/kissat.png)

We see that Kissat and CaDiCaL can solve verification harnesses that would timeout with MiniSat, and provide significant speedups on some other verification harnesses.
For example, for `random::tests::gen_range_biased_test`, verification time goes down from 1460 seconds with MiniSat to 6.8 and 5.5 seconds with CaDiCaL and Kissat, respectively, thereby providing speedups of more than 200X.
Similarly, for `sync::spsc::tests::alloc_test`, verification time goes down from 1004 seconds with MiniSat to 63 seconds with Kissat (a 16X speedup), and 70 seconds with CaDiCaL (a 14X speedup).

We also see that MiniSat remains the fastest solver for harnesses that already run in a matter of seconds.
Of the harnesses that run for more than 10 seconds, Kissat is the fastest on 47% of them, CaDiCaL is the fastest on 24%, and MiniSat on the rest.

By picking the best solver for each harness using the `kani::solver` attribute, we can can bring the total cumulative runtime from 2 hours and 20 minutes down to 15 minutes (counting timeouts as 1800s), while solving two more harnesses. Great savings if your harnesses are run in CI!

[^1]: Without our enhancement to CBMC, it was already possible to select a different SAT solver without rebuilding CBMC via the `--external-sat-solver` option. However, this option doesn't use the solver in incremental mode(i.e. through its library API, keeping the solver alive between successive calls), and instead relies on writing DIMACS files to disk, which often results in decreased performance.

## Adding Direct Export of GOTO Binaries

`kani-compiler` translates a Rust program into a GOTO program and exports it as a *symbol table* for CBMC to analyse. A *symbol table* stores the definitions and source locations of all symbols manipulated by the program (types symbols and their definitions, static symbols and their initial value, functions symbols and their bodies, etc.).
The symbol table contents hence mostly consists of serialized abstract syntax trees.
Originally, Kani serialized symbol tables to JSON and then used the CBMC utility `symtab2gb` to translate the JSON symbol table into a *GOTO binary*, which is the format that CBMC actually expects as input.
The JSON to GOTO binary conversion was one of the most time consuming steps in the compilation stage.
We implemented direct GOTO binary serialisation in Kani, which allows us to skip the costly invocation of `symtab2gb`.
Kani can now perform the MIR-to-GOTO code generation and GOTO binary export 4x faster than before.

The table below reports total time and memory consumption when running `kani --tests --only-codegen` with `kani-0.33.3` for three crates of the `s2n-quic` project, with JSON symbol table export versus GOTO binary export.

| Crate                | User time (JSON) | User time (GOTO bin.) | Peak Mem. (JSON) | Peak Mem. (GOTO bin.) |
| -------------------  | ---------------: | --------------------: | ---------------: | --------------------: |
| `s2n-quic-core`      |             198s |              **111s** |        **669Mb** |                 815Mb |
| `s2n-quic-platform`  |              99s |               **91s** |        **449Mb** |                 450Mb |
| `s2n-quic-xdp`       |              92s |               **95s** |        **450Mb** |                 450Mb |


For `s2n-quic-core`, which contains 37 verification harnesses, we observe a reduction of 45% of *User time* from 199s down to 111s, and a 20% memory consumption increase from ~670Mb to ~815Mb.
For the two other crates which contain respectively 3 and 1 harnesses, the *User time* is dominated by Rust to MIR compilation and the total gains with GOTO binary export are lower
at roughly 10% and even degrade to negative 4%, albeit for a virtually non memory consumption increase.

Looking in more detail at GOTO code generation and GOTO binary export time for individual harnesses, excluding the Rust-to-MIR compilation time,
we see that GOTO binary export is ~9x faster than JSON export, and that the GOTO code generation and export step is now ~4x faster (see the _Detailed table_ below). The savings seem small but accumulate to eventually make a noticeable difference.

GOTO binary export is now the default export mode, because it is faster when there are multiple verification harnesses in a crate, which is more often the case in practice.
The memory consumption can be sometimes higher than with JSON export, but it can also sometimes be lower depending on how much opportunity for sharing of identical subtrees the crate offers (on large crates like `std` or `proc_macro` we've observed up to 2x reduction in memory usage). Should you ever need it, JSON export can still be activated with the command line switch `--write-json-symbtab`.


<details>
<summary>
Detailed GOTO codegen and export times table
</summary>
<div markdown=1>

| Harness                                                     | GOTO codegen time (s) | JSON export (s) | GOTO-binary export (s) | export speedup | codegen + export speedup |
| ----------------------------------------------------------- | --------------------: | --------------: | ---------------------: | -------------: | -----------------------: |
| `ct::tests::ct_ge...`                                       |                  0,32 |            1,48 |               **0,17** |           8,70 |                     3,67 |
| `ct::tests::ct_gt...`                                       |                  0,26 |            1,32 |               **0,14** |           9,42 |                     3,95 |
| `ct::tests::ct_le...`                                       |                  0,26 |            1,32 |               **0,14** |           9,42 |                     3,95 |
| `ct::tests::ct_lt...`                                       |                  0,26 |            1,33 |               **0,14** |           9,50 |                     3,97 |
| `ct::tests::rem...`                                         |                  0,26 |            1,32 |               **0,16** |           8,25 |                     3,76 |
| `ct::tests::sub...`                                         |                  0,26 |            1,33 |               **0,14** |           9,50 |                     3,97 |
| `ct::tests::div...`                                         |                  0,26 |            1,33 |               **0,14** |           9,50 |                     3,97 |
| `ct::tests::add...`                                         |                  0,26 |            1,33 |               **0,14** |           9,50 |                     3,97 |
| `ct::tests::mul...`                                         |                  0,26 |            1,32 |               **0,14** |           9,42 |                     3,95 |
| `frame::crypto::tests::try_fit_test...`                     |                  0,66 |            3,31 |               **0,39** |           8,48 |                     3,78 |
| `frame::stream::tests::try_fit_test...`                     |                  0,67 |            3,44 |               **0,38** |           9,05 |                     3,91 |
| `inet::checksum::tests::differential...`                    |                  0,51 |            2,46 |               **0,26** |           9,46 |                     3,85 |
| `inet::ipv4::tests::header_getter_setter_test...`           |                  0,44 |            2,11 |               **0,22** |           9,59 |                     3,86 |
| `inet::ipv4::tests::scope_test...`                          |                  1,01 |            5,18 |               **0,56** |           9,25 |                     3,94 |
| `inet::ipv6::tests::header_getter_setter_test...`           |                  0,44 |            2,17 |               **0,23** |           9,43 |                     3,89 |
| `inet::ipv6::tests::scope_test...`                          |                  1,08 |            5,34 |               **0,59** |           9,05 |                     3,84 |
| `interval_set::tests::interval_set_inset_range_test...`     |                  0,83 |             4,3 |               **0,45** |           9,55 |                     4,00 |
| `packet::number::map::tests::insert_value...`               |                  0,28 |            1,49 |               **0,16** |           9,31 |                     4,02 |
| `packet::number::sliding_window::test::insert_test...`      |                  0,86 |            4,22 |               **0,46** |           9,17 |                     3,84 |
| `packet::number::tests::example_test...`                    |                  1,09 |            5,67 |               **0,59** |           9,61 |                     4,02 |
| `packet::number::tests::rfc_differential_test...`           |                  0,30 |            1,62 |               **0,18** |           9,40 |                      4.0 |
| `packet::number::tests::truncate_expand_test...`            |                  0,63 |            3,23 |               **0,35** |           9,22 |                      3,9 |
| `packet::number::tests::round_trip...`                      |                  0,22 |            1,18 |               **0,13** |           9,00 |                     4,00 |
| `random::tests::gen_range_biased_test...`                   |                  0,31 |            1,58 |               **0,18** |           8,77 |                     3,85 |
| `recovery::rtt_estimator::test::weighted_average_test...`   |                  0,43 |            2,23 |               **0,24** |           9,29 |                     3,97 |
| `slice::tests::vectored_copy_fuzz_test...`                  |                  0,73 |            3,33 |               **0,35** |           9,51 |                     3,75 |
| `stream::iter::fuzz_target::fuzz_builder...`                |                  0,26 |            1,35 |               **0,14** |           9,64 |                     4,02 |
| `sync::cursor::tests::oracle_test...`                       |                  0,92 |            4,41 |               **0,46** |           9,58 |                     3,86 |
| `sync::spsc::tests::alloc_test...`                          |                  0,82 |            4,15 |               **0,45** |           9,22 |                     3,91 |
| `varint::tests::checked_ops_test...`                        |                  0,95 |            4,94 |               **0,55** |           8,98 |                     3,92 |
| `varint::tests::table_differential_test...`                 |                  0,95 |            4,93 |               **0,51** |           9,66 |                     4,02 |
| `varint::tests::eight_byte_sequence_test...`                |                  0,96 |            4,97 |               **0,52** |           9,55 |                     4,00 |
| `varint::tests::four_byte_sequence_test...`                 |                  0,95 |            4,95 |               **0,52** |           9,51 |                     4,01 |
| `varint::tests::two_byte_sequence_test...`                  |                  0,97 |            4,98 |               **0,52** |           9,57 |                     3,99 |
| `varint::tests::one_byte_sequence_test...`                  |                  0,25 |            1,32 |               **0,14** |           9,42 |                     4,02 |
| `varint::tests::round_trip_values_test...`                  |                  0,27 |            1,38 |               **0,15** |           9,20 |                     3,92 |
| `xdp::decoder::tests::decode_test...`                       |                  0,58 |            2,93 |               **0,31** |           9,45 |                     3,94 |
| `message::cmsg::tests::round_trip_test...`                  |                  0,37 |            1,59 |               **0,19** |           8,36 |                     3,50 |
| `message::cmsg::tests::iter_test...`                        |                  0,77 |            3,75 |               **0,41** |           9,14 |                     3,83 |
| `message::msg::tests::address_inverse_pair_test...`         |                  0,85 |            4,07 |               **0,43** |           9,46 |                     3,84 |
| `task::completion_to_tx::assign::tests::assignment_test...` |                  0,36 |            1,48 |               **0,17** |           8,70 |                     3,47 |
|                                                             |             **Total** |       **Total** |              **Total** |        **Avg** |                  **Avg** |
|                                                             |                  22,8 |          114,66 |              **12,33** |           9,29 |                     3,90 |

</div>
</details>

<details>
<summary>
Details on the GOTO binary format
</summary>
<div markdown=1>

Internally, CBMC uses a single generic data structure called [`irept`](https://github.com/diffblue/cbmc/blob/develop/src/util/irep.h#L308) to represent all tree-structured data (see [statements](https://github.com/diffblue/cbmc/blob/develop/src/util/std_expr.h), [expressions](https://github.com/diffblue/cbmc/blob/develop/src/util/std_expr.h), [types](https://github.com/diffblue/cbmc/blob/develop/src/util/std_types.h) and [source locations](https://github.com/diffblue/cbmc/blob/develop/src/util/source_location.h) in the CBMC code base). A GOTO binary is mainly a collection of serialised `irept`.

The `Irep` type would look like this if written in Rust:

```rust
// an opaque type for an interned String
struct IrepId;

// a generic tree node
struct Irep {
    // node identifier, defines the interpretation of the node
    id: IrepId,
    // Subtrees indexed by integer
    sub: Vec<Rc<Irep>>,
    // Subtrees keyed by name
    named_sub: Map<IrepId, Rc<Irep>>,
}
```

`Ireps` are tagged by an `IrepId` (an interned string) giving them their meaning. An `Irep` references other `Ireps` through reference counted smart pointers. `Ireps` also allow safe sharing of subtrees, with a copy-on-write update mechanism. For instance the expression `x + y` would be represented by an `Irep` similar to this:

```rust
Irep {
    id = IrepId("+"),
    sub: Vec(
        Irep(
            id = "symbol_expr",
            named_sub: Map((IrepId("identifier"), Irep(id: IrepId("x"))))
        ),
        Irep(
            id = "symbol_expr",
            named_sub: Map((IrepId("identifier"), Irep(id: IrepId("y"))))
        ),
    )
}
```

The serialization/deserialization algorithm for GOTO binaries uses a technique called *value numbering* to avoid repeating identical `Ireps` and strings in the binary file.

A _value numbering_ for a type `K` is a function that assigns a unique number in the range `[0, N)` to each value in a multiset `S` of values of type `K` ((multiset: some values can be repeated).
Numberings are usually implemented using a hash map of type `HashMap<K, usize>`.
Each value `k` in the set `S` is numbered by performing a lookup in the map: if an entry for `k` is found, return the associated value, otherwise insert a new entry `(k, numbering.size())` and return the unique number for that entry.
Value numbering for `Ireps` uses vectors of integers as keys. An `Irep` is numbered by first numbering its id, recursively numbering its subtrees and named subtrees, and forming a key from these unique numbers.
Then, a lookup is performed for that key in the numbering. Since two `Ireps` with the same id, subtrees and named subtrees are represented by the same key, the unique number of the key also identifies the `Irep` uniquely by its contents. CBMC's binary serde algorithm uses numbering functions for `Ireps` and `Strings` that are used as a cache of already serialised `Ireps` and `Strings`.
An `Irep` node is fully serialised only the first time it is encountered. Later occurrences are serialised by reference, i.e. only by writing their unique identifier.
This achieves maximum sharing of identical subtrees and strings in the binary file.

The format also uses *7-bit variable length encoding* for integer values to reduce the overall file size.
The encoding works as follows: an integer represented using `N` bytes is serialised to a list of `M` bytes, where each byte encodes a group of seven bits of the original integer and one bit signals the continuation of the list.
For instance, the decimal value 32bit decimal `190341` is represented as `00000000000000101110011110000101` in binary.
Splitting this number in groups of 7-bits starting from the right, we get `0000101 1001111 0001011 0000000 0000`.
We see that all bits in the two last groups are false, so only the first three groups will be serialised.
With continuation bits added (represented in parentheses), the encoding for this 4-byte number only uses 3-bytes:  `(1)0000101(1)1001111(0)0001011`.

The GOTO binary serde code can be found [here](https://github.com/model-checking/kani/blob/main/cprover_bindings/src/irep/goto_binary_serde.rs).

</div>
</details>

## Enabling Constant Propagation for Individual Fields of Union Types

Union types are very common in goto-programs emitted by Kani, due to the fact that Rust code typically uses `enums`, which are themselves modelled as tagged unions at the goto-program level.
Initially the *field sensitivity* transform in CBMC enabled constant propagation for individual array cells and individual struct fields, but not for union fields.
Since constant propagation helps pruning control flow branches during symbolic execution and can greatly reduce the runtime of an analysis, ensuring that constant propagation also works for union fields is important for Rust programs.
Field-sensitivity was first extended to unions in `cbmc-5.71.0`, but did not make it to Kani until `kani v0.17.0` built on top of `cbmc v5.72.0`.
The feature was then refined and stabilized in several iterations and became stable with `cbmc v5.85.0` in early June 2023, and released through `kani v0.31.0` built on top of `cbmc v5.86.0`.
This new CBMC feature vastly improved performance for Rust programs manipulating `Vec<T>` and `BTreeSet<T>` data types, and allowed us to solve a number performance issues reported by our users: [#705](https://github.com/model-checking/kani/issues/705), [#1226](https://github.com/model-checking/kani/issues/1226), [#1657](https://github.com/model-checking/kani/issues/1657), [#1673](https://github.com/model-checking/kani/issues/1673), [#1676](https://github.com/model-checking/kani/issues/1676).

The following tables and plots were obtained by running the kani `perf` test suite with `kani 0.33.0`, `cbmc 5.88.1` with `cadical` as default SAT solver for all tests, a timeout of 900s, with and without applying the union-field sensitivity transform.


| verification Harness                      | no-sens | sens | change          |
| ---------------------------------- | ------- | ---- | --------------- |
| btreeset/insert_any/main           | False   | True | ✅ newly passing |
| btreeset/insert_multi/insert_multi | False   | True | ✅ newly passing |
| btreeset/insert_same/main          | False   | True | ✅ newly passing |
| misc/display_trait/slow            | False   | True | ✅ newly passing |
| misc/struct_defs/fast_harness      | False   | True | ✅ newly passing |

Field sensitivity allows 5 new verification harnesses to be solved under the 900s limit.

![Total time](/kani-verifier-blog/assets/images/field-sens-plots/total-time.png)

We observe significant 10% to 99% reduction in rutime for roughly a third of verification harnesses (and 5 newly solved harnesses within the 900s time limit), but we also observe a 10% to 55% runtime degradation or 25% of the verification harnesses, so this feature does not bring a consistent benefit. However, the cumulative total time to run the `perf` suite without union field sensitivity is roughly 6500s, and it drops to 1784s with union field sensitivity activated. Disabling union field sensitivity for harnesses where it degrades performance would only bring the cumulative total time down to 1676s. So we can say getting rid of timeouts and gains on a subset of harnesses offset the losses on the rest of harnesses.

<details>

<summary>
Detailed total time table
</summary>

<div markdown=1>

| verification Harness                                                                          | no-sens   | sens      | best      | change   |
| -------------------------------------------------------------------------------------- | --------- | --------- | --------- | -------- |
| misc/struct_defs/fast_harness                                                          | 900       | 0,89      | 0,89      | -99,9%   |
| misc/display_trait/slow                                                                | 900       | 2,67      | 2,67      | -99,703% |
| misc/struct_defs/slow_harness2                                                         | 66,72     | 0,24      | 0,24      | -99,631% |
| btreeset/insert_any/main                                                               | 900       | 5,14      | 5,14      | -99,429% |
| misc/struct_defs/slow_harness1                                                         | 20,33     | 0,21      | 0,21      | -98,925% |
| vec/box_dyn/main                                                                       | 97,24     | 1,79      | 1,79      | -98,154% |
| btreeset/insert_same/main                                                              | 900       | 16,65     | 16,65     | -98,149% |
| btreeset/insert_multi/insert_multi                                                     | 900       | 19,87     | 19,87     | -97,791% |
| vec/string/main                                                                        | 142,38    | 4,02      | 4,02      | -97,173% |
| s2n-quic/quic/s2n-quic-core/inet::checksum::tests::differential                        | 66,29     | 26,03     | 26,03     | -60,724% |
| s2n-quic/quic/s2n-quic-core/interval_set::tests::interval_set_inset_range_test         | 4,88      | 3,87      | 3,87      | -20,684% |
| s2n-quic/quic/s2n-quic-core/ct::tests::rem                                             | 1,33      | 1,11      | 1,11      | -16,406% |
| s2n-quic/quic/s2n-quic-core/ct::tests::div                                             | 1,15      | 0,98      | 0,98      | -14,491% |
| misc/display_trait/fast                                                                | 2,43      | 2,13      | 2,13      | -12,386% |
| s2n-quic/quic/s2n-quic-core/frame::crypto::tests::try_fit_test                         | 8,9       | 7,9       | 7,9       | -11,219% |
| s2n-quic/quic/s2n-quic-core/frame::stream::tests::try_fit_test                         | 41,29     | 36,83     | 36,83     | -10,801% |
| s2n-quic/quic/s2n-quic-core/packet::number::tests::truncate_expand_test                | 2,75      | 2,59      | 2,59      | -5,906%  |
| s2n-quic/quic/s2n-quic-core/varint::tests::table_differential_test                     | 1,15      | 1,08      | 1,08      | -5,83%   |
| s2n-quic/quic/s2n-quic-core/varint::tests::round_trip_values_test                      | 19,27     | 18,15     | 18,15     | -5,79%   |
| s2n-quic/tools/xdp/s2n-quic-xdp/task::completion_to_tx::assign::tests::assignment_test | 47,06     | 44,53     | 44,53     | -5,378%  |
| s2n-quic/quic/s2n-quic-core/slice::tests::vectored_copy_fuzz_test                      | 81,54     | 77,71     | 77,71     | -4,705%  |
| s2n-quic/quic/s2n-quic-core/packet::number::tests::example_test                        | 0,38      | 0,36      | 0,36      | -4,474%  |
| s2n-quic/quic/s2n-quic-core/sync::cursor::tests::oracle_test                           | 474,06    | 459,59    | 459,59    | -3,052%  |
| format/fmt_i8                                                                          | 43,83     | 42,94     | 42,94     | -2,032%  |
| misc/array_fold/array_sum_fold_proof                                                   | 0,93      | 0,92      | 0,92      | -1,416%  |
| s2n-quic/quic/s2n-quic-core/packet::number::tests::rfc_differential_test               | 3,89      | 3,85      | 3,85      | -1,119%  |
| s2n-quic/quic/s2n-quic-platform/message::cmsg::tests::iter_test                        | 19,5      | 19,33     | 19,33     | -0,865%  |
| s2n-quic/quic/s2n-quic-core/ct::tests::mul                                             | 0,75      | 0,75      | 0,75      | -0,285%  |
| s2n-quic/quic/s2n-quic-core/packet::number::map::tests::insert_value                   | 2,62      | 2,65      | 2,62      | 1,196%   |
| vec/vec/main                                                                           | 2,18      | 2,21      | 2,18      | 1,742%   |
| s2n-quic/quic/s2n-quic-core/ct::tests::add                                             | 0,68      | 0,69      | 0,68      | 2,447%   |
| s2n-quic/quic/s2n-quic-core/ct::tests::ct_gt                                           | 0,63      | 0,65      | 0,63      | 2,727%   |
| s2n-quic/quic/s2n-quic-core/inet::ipv4::tests::scope_test                              | 4,25      | 4,38      | 4,25      | 3,238%   |
| s2n-quic/quic/s2n-quic-core/ct::tests::sub                                             | 0,67      | 0,69      | 0,67      | 3,454%   |
| s2n-quic/quic/s2n-quic-core/ct::tests::ct_lt                                           | 0,63      | 0,65      | 0,63      | 3,998%   |
| s2n-quic/quic/s2n-quic-core/packet::number::tests::round_trip                          | 19,38     | 20,2      | 19,38     | 4,212%   |
| s2n-quic/quic/s2n-quic-core/ct::tests::ct_le                                           | 0,62      | 0,65      | 0,62      | 4,286%   |
| s2n-quic/quic/s2n-quic-core/ct::tests::ct_ge                                           | 0,62      | 0,65      | 0,62      | 4,939%   |
| s2n-quic/quic/s2n-quic-core/varint::tests::eight_byte_sequence_test                    | 13,66     | 14,37     | 13,66     | 5,166%   |
| s2n-quic/quic/s2n-quic-core/stream::iter::fuzz_target::fuzz_builder                    | 0,82      | 0,87      | 0,82      | 6,349%   |
| s2n-quic/quic/s2n-quic-core/packet::number::sliding_window::test::insert_test          | 1,46      | 1,55      | 1,46      | 6,566%   |
| s2n-quic/quic/s2n-quic-core/inet::ipv4::tests::header_getter_setter_test               | 19,59     | 21,04     | 19,59     | 7,365%   |
| s2n-quic/quic/s2n-quic-platform/message::cmsg::tests::round_trip_test                  | 463,27    | 497,46    | 463,27    | 7,38%    |
| misc/array_fold/array_sum_for_proof                                                    | 0,86      | 0,95      | 0,86      | 9,393%   |
| s2n-quic/quic/s2n-quic-core/inet::ipv6::tests::scope_test                              | 16,4      | 17,95     | 16,4      | 9,491%   |
| s2n-quic/quic/s2n-quic-core/inet::ipv6::tests::header_getter_setter_test               | 48,89     | 53,53     | 48,89     | 9,492%   |
| s2n-quic/quic/s2n-quic-core/recovery::rtt_estimator::test::weighted_average_test       | 117,62    | 129,32    | 117,62    | 9,943%   |
| s2n-quic/quic/s2n-quic-core/varint::tests::checked_ops_test                            | 2,49      | 2,76      | 2,49      | 11,022%  |
| s2n-quic/quic/s2n-quic-core/varint::tests::two_byte_sequence_test                      | 11,21     | 12,5      | 11,21     | 11,501%  |
| s2n-quic/quic/s2n-quic-core/varint::tests::four_byte_sequence_test                     | 11,64     | 14,06     | 11,64     | 20,729%  |
| s2n-quic/quic/s2n-quic-core/varint::tests::one_byte_sequence_test                      | 8,76      | 10,82     | 8,76      | 23,515%  |
| format/fmt_u8                                                                          | 9,41      | 12,06     | 9,41      | 28,233%  |
| s2n-quic/quic/s2n-quic-core/sync::spsc::tests::alloc_test                              | 92,84     | 126,45    | 92,84     | 36,206%  |
| s2n-quic/quic/s2n-quic-core/random::tests::gen_range_biased_test                       | 10,48     | 14,76     | 10,48     | 40,818%  |
| s2n-quic/quic/s2n-quic-core/xdp::decoder::tests::decode_test                           | 5,17      | 7,59      | 5,17      | 46,713%  |
| s2n-quic/quic/s2n-quic-platform/message::msg::tests::address_inverse_pair_test         | 7,09      | 10,98     | 7,09      | 54,841   |
|                                                                                        | **total** | **total** | **total** |          |
|                                                                                        | 6521,99   | 1784,57   | 1676,07   |          |

</div>
</details>

![Symex time](/kani-verifier-blog/assets/images/field-sens-plots/symex-time.png)

We see that symbolic execution time is sometimes improved, sometimes degraded. The degradation can possibly be explained by the fact that symex has to generate more constraints and handle more basic variables with the transform activated, and spend more time applying simplifications. But this extra work has a beneficial impact on the number of symbolic execution steps and number of VCCs generated for the SAT solver, and ultimately SAT solver runtime (as seen below).

![Symex steps](/kani-verifier-blog/assets/images/field-sens-plots/symex-steps.png)

The number of basic symbolic execution steps is sometimes slightly higher but otherwise mostly lower with union field sensitivity activated.

![number of VCCs](/kani-verifier-blog/assets/images/field-sens-plots/vccs.png)

The number of verification conditions generated is sometimes slightly higher but otherwise mostly lower with union field sensitivity activated.

![SAT solving time](/kani-verifier-blog/assets/images/field-sens-plots/sat-time.png)

Overall the SAT solving time is sometimes slightly degraded but otherwise mostly improved across the board with field-sensitivity.

<details>
<summary>
Details on the field-sensitivity transform
</summary>
<div markdown=1>

CBMC's constant propagation algorithm only propagates values for scalar variables with a basic datatype such as `bool`, `int`, ... but not for aggregates. To enable propagation for individual fields of aggregates, CBMC decomposes them into their individual scalar fields, by introducing new variables in the program, and resolving all field access expressions to these new variables.

For unions, just like for structs, the transform introduces a distinct variable for each field of the union. However, contrary to structs, the different fields of a union overlap in the byte-level layout. As a result, every time a union field gets assigned with a new value, all fields of the union are actually impacted, and the impact depends on how the fields overlap in the layout. This means that the variables representing the different fields of the union have to be handled as a group and globally updated after each update to any one of them.

For instance, for a union defined as follows (using C syntax for simplicity):

```c
union {
  unsigned long a;
  unsigned int b;
} u;
```

The byte-level layout of the fields is such that the lowest 4 bytes of `u.a` and all bytes of `u.b` overlap. As a result, updating `u.a` updates all bytes `u.b`, and updating `u.b` updates the lowest 4 bytes of `u.a`:

```c
u       uuuuuuuuuuuuuuuu
u.a     aaaaaaaaaaaaaaaa
u.b             bbbbbbbb
idx.   16       7      0
      MSB             LSB
```

The transform introduces a variable `u_a` to represent `u.a`, and a variable `u_b` to represent `u.b`. These two variables are not independent, and every-time one of the fields is updated in the original program, both variables are updated in the transformed program.

Applying the transform to the following program:

```c
int main() {
  union {
    unsigned long a;
    unsigned int b;
  } u;

  u.a = 0x0000000000000000;
  u.b = 0x87654321;
  assert(u.a == 0x0000000087654321);
  assert(u.b == 0x87654321);
  return 0;
}
```

produces the following transformed program:

```c
int main() {
  unsigned long u_a;
  unsigned int u_b;

  // the bytes of u_b are equal the low bytes of u_a
  u_b = (unsigned int) u_a;

  // u.a = 0x0000000000000000;
  u_a = 0x0000000000000000;
  u_b = (unsigned int) 0x0000000000000000;

  // u.b = 0x87654321;
  u_a = (u_a & 0xFFFFFFFF00000000) | ((unsigned long) 0x87654321);
  u_b = 0x87654321;

  // assert(u.a == 0x0000000087654321);
  assert(u_a == 0x0000000087654321);

  // assert(u.b == 0x87654321);
  assert(u_b == 0x87654321);
  return 0;
}
```

</div>
</details>

## Conclusion

In conclusion, we would like to point out the multi-faceted approach to optimizing a tool such as Kani and making verification scalable in general.
Some optimizations are geared towards solving unsolvable cases whereas others are more general in nature.
A reflection of the difficult problem space we are dealing with.
Specific tools can achieve better performance with niche optimizations, but tools like Kani have to be optimized at various levels to achieve realistic performant verification.
We hope you enjoyed the blog post and get a sense of the need for a multi-faceted approach !
