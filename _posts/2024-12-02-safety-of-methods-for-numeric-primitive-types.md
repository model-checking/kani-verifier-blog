---
title: Safety of Methods for Numeric Primitive Types
layout: post
---
Authors: [Rajath M Kotyal](https://github.com/rajathkotyal), [Yen-Yun Wu](https://github.com/Yenyun035), [Lanfei Ma](https://github.com/lanfeima), [Junfeng Jin](https://github.com/MWDZ)

In this blog post, we discuss how we verified the absence of arithmetic overflow/underflow and undefined behavior in various unsafe methods provided by Rust's numeric primitive types, given that their safety preconditions are satisfied.

## Introduction
Ensuring the correctness and safety of numeric operations is crucial for developing reliable systems. In high-performance applications, numeric operations often require bypassing checks to maximize efficiency. However, ensuring the safety of these methods under their stated preconditions is critical to preventing undefined behavior.

In the past 3 months, we have rigorously analyzed unsafe methods provided by Rust's numeric primitive types, such as `unchecked_add` and `unchecked_sub`, which omit runtime checks for overflow and underflow, using formal verification techniques.

## Challenge Overview
The [challenge](https://model-checking.github.io/verify-rust-std/challenges/0011-floats-ints.html) is divided into three parts:
1. Unsafe Integer Methods: Prove safety of methods like `unchecked_add`, `unchecked_sub`, `unchecked_mul`, `unchecked_shl`, `unchecked_shr`, and `unchecked_neg` for various integer types.
2. Safe API Verification: Verify safe APIs that leverage the unsafe integer methods from Part 1, such as `wrapping_shl`, `wrapping_shr`, `widening_mul`, and `carrying_mul`.
3. Float to Integer Conversion: Verify the absence of undefined behavior in `to_int_unchecked` for all floating-point types: `f16`, `f32`, `f64`, and `f128`.

In addition to verifying the methods under their specified safety preconditions, we needed to ensure the absence of specific [undefined behaviors](https://github.com/rust-lang/reference/blob/142b2ed77d33f37a9973772bd95e6144ed9dce43/src/behavior-considered-undefined.md):
- Invoking undefined behavior via compiler intrinsics.
- Reading from uninitialized memory.
- Mutating immutable bytes.
- Producing an invalid value.

## Approach
To tackle this challenge, we utilized [Kani](https://github.com/model-checking/kani)'s verification capabilities to write proof harnesses for the unsafe methods. Our strategy involved:
1. **Specifying Safety Preconditions**: To ensure the methods behaved correctly, we explicitly specified safety preconditions in the code. These preconditions were used to:
   - Guide Kani input generation.
   - Define the boundaries for valid inputs.
   - Avoid triggering undefined behavior in cases where the preconditions were violated.

2. **Writing Verification Harnesses**: We developed Kani proof harnesses for each unsafe method by:
   - Generating inputs that satisfy the required safety preconditions.
   - Invoking the methods within an `unsafe` block to verify their correctness and safety under the defined conditions.

3. **Using Macros for Code Generation**: To efficiently handle the large number of methods and types that required verification, we utilized Rust macros. These macros automated the generation of proof harnesses, reducing redundancy and improving maintainability.

4. **Handling Large Input Spaces**: For methods with large input spaces (e.g., `unchecked_mul` for 64-bit integers), we made the verification process more tractable by:
   - Introducing assumptions to limit the range of inputs.
   - Focusing on specific edge cases (e.g., maximum values, zero, and boundary conditions) that are most likely to cause overflow or underflow.

We will walk through each part with examples from the Unsafe Integer Methods part of the challenge.

## Implementation

### 1. Specifying Safety Preconditions
The following code demonstrates how to specify safety preconditions for an unsafe numeric method `unchecked_add` using [**function contracts**](https://github.com/model-checking/kani/blob/main/rfc/src/rfcs/0009-function-contracts.md) to ensure correct behavior under the stated conditions.

```rust
#[requires(!self.overflowing_add(rhs).1)] // We added this precondition
pub const unsafe fn unchecked_add(self, rhs: Self) -> Self { // existing source code
    assert_unsafe_precondition!(
        check_language_ub,
        concat!(stringify!($SelfT), "::unchecked_add cannot overflow"),
        (
            lhs: $SelfT = self,
            rhs: $SelfT = rhs,
        ) => !lhs.overflowing_add(rhs).1,
    );

    // SAFETY: The caller guarantees that the preconditions are met.
    unsafe {
        intrinsics::unchecked_add(self, rhs)
    }
}
```
Here, we added the `#[requires]` attribute above the existing source code to specify that `unchecked_add` requires the addition to not overflow. This ensures the function operates within its intended behavior when called in an unsafe context. While we directly utilized the existing precondition in `unchecked_add`, not every function includes an explicit precondition check. However, we can define preconditions for unsafe functions based on the `SAFETY` section in the official documentation or the explanatory `SAFETY` comments in the source code.

Similarly, postconditions (`#[ensures]`) serve to define the guarantees that a function must uphold after its execution. These ensure the function output or state adheres to the intended expectations, providing an additional safeguard for correctness.

### 2. Generating Verification Harnesses
Sometimes, we need to verify a method for multiple types, which often requires writing numerous harnesses. However, these harnesses usually share the same logic, which makes it inefficient and error-prone to copy and paste similar code repeatedly. This is where [**macros**](https://doc.rust-lang.org/book/ch19-06-macros.html) come in handy. As an improvement, we can define a single reusable template that dynamically generates harnesses for different types using macro, which reduces redundancy and improves maintainability.

In this next code block, we created a macro to generate verification harnesses for each method and type. It showcases the use of macros to generate reusable verification harnesses for different numeric types and methods, ensuring correctness without duplicating code.

```rust
#[cfg(kani)]
mod verify {
    use super::*;

    // Generate harnesses for methods involving two operands
    // `type`: Integer type
    // `method`: Method to verify
    // `harness_name`: A unique identifier for a harness
    macro_rules! generate_unchecked_math_harness {
        ($type:ty, $method:ident, $harness_name:ident) => {
            #[kani::proof_for_contract($type::$method)]
            pub fn $harness_name() {
                let num1: $type = kani::any::<$type>(); // (1)
                let num2: $type = kani::any::<$type>(); // (1)
                // (2)
                unsafe { num1.$method(num2); } // (3)
                // (4)
            }
        }
    }

    generate_unchecked_math_harness!(i8, unchecked_add, unchecked_add_i8);
    generate_unchecked_math_harness!(i16, unchecked_add, unchecked_add_i16);
    // ... Repeat for other integer types (32/64/128-bit/architecture-dependent signed/unsigned integers)
}
```
A harness contains several parts:
1. [**Symbolic values**](https://model-checking.github.io/kani/tutorial-nondeterministic-variables.html): `num1` and `num2` are symbolic values generated using `kani::any()`. Kani employs symbolic execution to explore a wide range of input possibilities systematically.
2. **Assumptions**: With `#[kani::proof_for_contract]` annotation, Kani automatically inserts `kani::assume()` before the unsafe function call. It ensures that all generated values respect the preconditions of `unchecked_add`. If there are additional assumptions not captured by function contracts, you can specify them manually as well. You can find further details in [Kani official RFC for function contracts](https://github.com/model-checking/kani/blob/main/rfc/src/rfcs/0009-function-contracts.md#user-experience).
3. **Unsafe Execution**: The invocation of `unchecked_add` within an unsafe block for verification. [`unsafe`](https://doc.rust-lang.org/book/ch19-01-unsafe-rust.html) code blocks enable unsafe Rust features, such as calling unsafe functions or dereferencing raw pointers.
4. **Assertions**: Similar to assumptions, with `#[kani::proof_for_contract]` annotation, Kani automatically inserts `kani::assert()` after the unsafe function call. It checks if the function behaves as expected (e.g. returning an expected result) or if certain safety invariants hold after function call.

### 3. Handling Large Input Spaces
For methods like `unchecked_mul`, verifying over the entire input space is infeasible due to the exponential number of possibilities. To improve the performance, we partitioned the input space into intervals.

The following code illustrates a strategy to handle large input spaces by partitioning input ranges into manageable intervals for verification, focusing on critical edge cases.
```rust
// `type`: Integer type of operands
// `method`: Method to verify, i.e. `unchecked_mul`
// `harness_name`: A unique identifier for a harness
// `min`: The lower bound for input generation
// `max`: The upper bound for input generation
macro_rules! generate_unchecked_mul_intervals {
    ($type:ty, $method:ident, $($harness_name:ident, $min:expr, $max:expr),+) => {
        $(
            #[kani::proof_for_contract($type::$method)]
            pub fn $harness_name() {
                let num1: $type = kani::any::<$type>();
                let num2: $type = kani::any::<$type>();

                // Improve unchecked_mul performance for {32, 64, 128}-bit integer types
                // by adding upper and lower limits for inputs
                kani::assume(num1 >= $min && num1 <= $max);
                kani::assume(num2 >= $min && num2 <= $max);

                // Precondition: multiplication does not overflow
                // Kani automatically inserts: `kani::assume(!num1.overflowing_mul(num2).1)`
                unsafe { num1.$method(num2); }
            }
        )+
    }
}

generate_unchecked_mul_intervals!(i32, unchecked_mul,
    unchecked_mul_i32_small, -10i32, 10i32,                    // Cases near zero
    unchecked_mul_i32_large_pos, i32::MAX - 1000i32, i32::MAX, // maximum corner cases
    unchecked_mul_i32_large_neg, i32::MIN, i32::MIN + 1000i32, // minimum corner cases
    unchecked_mul_i32_edge_pos, i32::MAX / 2, i32::MAX,        // wide range towards maximum
    unchecked_mul_i32_edge_neg, i32::MIN, i32::MIN / 2         // wide range towards maximum
);
```

By focusing on critical ranges, we ensured that the verification process remained tractable while still covering important cases where overflows are likely to occur. The critical ranges include :
- **Small Ranges Near Zero**: Includes values around 0, where behavior transitions (e.g., sign changes) are more likely to expose issues like arithmetic underflow.
- **Boundary Checks**: Covers the maximum (`i32::MAX`) and minimum (`i32::MIN`) values , ensuring the method handles edge cases correctly.
- **Halfway Points**: For instance, from `i32::MAX / 2` to `i32::MAX`. This helps validate behavior at large magnitudes. For types like 64-bit integers (`i64`) and above, where state space `(2^64 * 2^64 = ~2^128 combinations)` becomes impractical to verify, leveraging narrower ranges or sampling are critical.

## Part 2: Verifying Safe APIs
Leveraging the above workflow, we extended our efforts to ensure the safety of Rust's safe APIs.

### Why verify safe APIs?
Safe APIs, such as `widening_mul` or `wrapping_shl`, internally leverage unsafe operations (e.g., `unchecked_mul` or `unchecked_shl`). While marked safe, their reliability still depends on the correctness of these underlying operations. For example, verifying `widening_mul` ensures no overflow, underflow, and undefined behavior occurs in the wider type used internally. When verifying safe APIs like `widening_mul`, we consider the underlying unsafe functions and target specific input intervals to ensure correctness across critical ranges, balancing thoroughness with practicality.

### Example: `u16::widening_mul`
```rust
// Verify `widening_mul`, which internally uses `unchecked_mul`
// `type`: Integer type of operands
// `wide_type`: An integer type larger than `type`
// `harness_name`: A unique identifier for a harness
// `min`: The lower bound for input generation
// `max`: The upper bound for input generation
macro_rules! generate_widening_mul_intervals {
    ($type:ty, $wide_type:ty, $($harness_name:ident, $min:expr, $max:expr),+) => {
        $(
            #[kani::proof]
            pub fn $harness_name() {
                let lhs: $type = kani::any::<$type>();
                let rhs: $type = kani::any::<$type>();

                // Improve performance for large integer types
                kani::assume(lhs >= $min && lhs <= $max);
                kani::assume(rhs >= $min && rhs <= $max);

                let (result_low, result_high) = lhs.widening_mul(rhs);

                // Correctness checks
                // Compute expected result using wider type
                let expected = (lhs as $wide_type) * (rhs as $wide_type);
                let expected_low = expected as $type;
                let expected_high = (expected >> <$type>::BITS) as $type;

                assert_eq!(result_low, expected_low);
                assert_eq!(result_high, expected_high);
            }
        )+
    }
}

generate_widening_mul_intervals!(u16, u32,
    widening_mul_u16_small, 0u16, 10u16,
    widening_mul_u16_large, u16::MAX - 10u16, u16::MAX,
    widening_mul_u16_mid_edge, (u16::MAX / 2) - 10u16, (u16::MAX / 2) + 10u16
);
```
This code might look familiar to you, as we applied a similar approach when verifying the unsafe multiplication method, `unchecked_mul`, as discussed in the [Handling Large Input Spaces](#3-handling-large-input-spaces) section. This macro generates harnesses that verify `widening_mul` over specified input intervals, ensuring that it operates safely across different ranges. In addition to the safety checks performed automatically by Kani, we incorporated explicit correctness checks on function results. While not strictly required, these checks provide an added layer of assurance by verifying function outputs against expected results.

## Part 3: Verifying Float to Integer Conversion
After verifying safe integer APIs, our focus shifted to another critical area: verifying the `to_int_unchecked` method, which handles float-to-integer conversions.

### First try
Initially, we applied the approach introduced before to specify safety preconditions and write a harness generation macro:
```rust
// Preconditions
// - Input float cannot be NaN
// - Input float cannot be infinite
// - Input float must be representable in the target integer type
// `is_finite` handles the first two cases
#[requires(self.is_finite() && self >= Self::MIN && self <= Self::MAX)]
pub unsafe fn to_int_unchecked<Int>(self) -> Int where Self: FloatToInt<Int> { /* Implementation */ }

// `floatType`: Type of float to convert (f16, f32, f64, or f128)
// `intType`: Target integer type
// `harness_name`: A unique identifier of a harness
macro_rules! generate_to_int_unchecked_harness {
    ($floatType:ty, $($intType:ty, $harness_name:ident),+) => {
        $(
            #[kani::proof_for_contract($floatType::to_int_unchecked)]
            pub fn $harness_name() {
                let num: $floatType = kani::any();
                // Kani automatically inserts preconditions (`kani::assume()`) here
                let result = unsafe { num.to_int_unchecked::<$intType>() };
                assert_eq!(result, num as $intType); // Correctness check
            }
        )+
    }
}

generate_to_int_unchecked_harness!(f32,
    i8, to_int_unchecked_f32_i8,
    i16, to_int_unchecked_f32_i16,
    // ... Repeat for other integer types
);
```
However, when we ran Kani on our harnesses, the verification failed:
```
...
Failed Checks: float_to_int_unchecked is not currently supported by Kani.
...
Summary:
Verification failed for - num::verify::checked_to_int_unchecked_f32
Complete - 0 successfully verified harnesses, 1 failures, 1 total.
```
From the verification report, we realized that Kani did not support `float_to_int_unchecked` which is internally called by `to_int_unchecked`. We filed a [Kani feature request for `float_to_int_unchecked`](https://github.com/model-checking/kani/issues/3629) immediately, and `float_to_int_unchecked` was introduced shortly [2].

### Second Try
Without changing any code, we ran Kani on the harnesses again. While we hoped things would go smoothly, another error occurred:
```
Check 14: <f32 as convert::num::FloatToInt>::to_int_unchecked.arithmetic_overflow.2
- Status: FAILURE
- Description: "float_to_int_unchecked: attempt to convert a value out of range of the target integer"
- Location: library/core/src/convert/num.rs:30:30 in function <f32 as convert::num::FloatToInt>::to_int_unchecked
```
Kani reported that the preconditions were violated because the resulting integer type could not accommodate the integer representation of the input float. Upon investigation, we discovered that the `Self::MAX` and `Self::MIN` in the contract were mistakenly referring to the maximum and minimum values of the float type rather than those of the resulting integer type.
```rust
#[requires(self.is_finite() && self >= Self::MIN && self <= Self::MAX)] // Incorrect maximum and minimum values
```
Consequently, we began exploring potential solutions.
```rust
// Failed Attempt 1
// Tried to access the maximum and minimum values of the target integer type, but MAX and MIN were
// not found in type `Int`
#[requires(self.is_finite() && self >= Int::MIN && self <= Int::MAX)]

// Failed Attempt 2
// Matched the target integer type to the checks.
// A check for each integer type. A total of 12 checks is not pretty.
// Casting an integer to a float (e.g. `i32::MAX as f32`) brings imprecision as well.
#[requires(self.is_finite() && (type_name::<Int>().contains("i8") && self >= i8::MIN as Self && self <= i8::MAX as Self) && <...11 checks omitted> )]

// Failed Attempt 3
// Based on the idea of Attempt 2, we wrote a macro to check, but the `Int` type failed to
// match to the target integer type, e.g. `Int` did not match to the first case when it is `i8`.
macro_rules! is_in_range {
    (i8, $floatType:ty, $num:ident) => { $num >= i8::MIN as $floatType && $num <= i8::MAX as $floatType };
    (i16, $floatType:ty, $num:ident) => { $num >= i16::MIN as $floatType && $num <= i16::MAX as $floatType };
    ...
}
#[requires(self.is_finite() && is_in_range!(Int))]
```
During the experiment, we encountered two challenging issues:
1. [Imprecision in Integer-to-Float Casting](https://github.com/model-checking/verify-rust-std/pull/134?new_mergebox=true#issuecomment-2465756450): When casting an integer to a floating-point type, precision can be lost. For instance, casting `i32::MAX` (`2147483647`) to `f32` results in `2147483648.0`. This leads to a scenario where the contract precondition considers the `f32` value `2147483648.0` valid, even though it falls outside the representable range of `i32`.
2. [Inexact Floating-Point Representations](https://github.com/model-checking/verify-rust-std/discussions/187): Not all decimal values can be exactly represented as floating-point numbers. When a value is assigned to a float, the actual stored value might slightly differ due to the limitations of floating-point precision.

Unfortunately, despite multiple attempts, we were unable to derive an ideal solution. As a result, we submitted a [Kani feature request for `float_to_int_in_range`](https://github.com/model-checking/kani/issues/3711) method. The `float_to_int_in_range` method determines whether a float can be accurately represented in the target integer type, addressing the two challenges discussed above.

### Last Try
At this point, we had everything we needed. We updated the function contract to incorporate the `float_to_int_in_range` method.
```rust
// Preconditions
// - Input float cannot be NaN
// - Input float cannot be infinite
// - Input float must be representable in the target integer type
// `is_finite` handles the first two cases
#[requires(self.is_finite() && float_to_int_in_range::<Self, Int>(self))]
pub unsafe fn to_int_unchecked<Int>(self) -> Int where Self: FloatToInt<Int> { /* Implementation */ }
```

After running Kani again, all harnesses passed the verification checks. By this point, we completed the challenge.

## Challenges Encountered & Lessons Learned
Lastly, we summarized the main challenges we encountered throughout the course and our reflections.

### Handling Exponential Input Spaces
Verifying methods with large integer types was challenging due to the vast number of possible input combinations. To manage this, we implemented:
- Partitioning Input Ranges: We targeted critical intervals where overflows are most likely, such as boundary values and mid-range points.
- Using Assumptions: Leveraging `kani::assume`, we constrained inputs to these manageable ranges, ensuring comprehensive coverage of important cases without overwhelming the verifier.

### Ensuring Assumptions Reflect Safety Preconditions
Aligning our assumptions with the actual safety preconditions of each method was essential. Any mismatch could result in unsound verification, either by overlooking edge cases or by falsely validating incorrect behaviors.

### Writing Efficient Macros
Creating macros to generate numerous harnesses required meticulous design. We focused on maintaining readability and reusability, which minimized code duplication and enhanced the scalability and maintainability of our verification process.

### Dealing with Floating-Point Complexities
Floating-point numbers presented two significant challenges:
1. Their inherent imprecision often caused discrepancies between the stored values and their expected representations, leading to verification failures.
2. Not all decimal values have exact floating-point representations, meaning that the actual stored value might slightly differ from the intended one.
To address these issues, we utilized the `float_to_int_in_range` method to account for these issues without compromising the rigor of our checks.

### Addressing Tool Limitations
While Kani provided robust verification capabilities, certain limitations, such as the initial lack of support for `float_to_int_unchecked`, required creative workarounds and feature requests. Collaborating with the Kani community and iterating on our verification approach highlighted the importance of evolving tools to meet the demands of formal verification for complex systems.

## Conclusion
This [challenge](https://model-checking.github.io/verify-rust-std/challenges/0011-floats-ints.html) provided valuable insights into the process of formally verifying unsafe methods in Rust's standard library. By leveraging Kani and carefully designing our verification harnesses, we successfully demonstrated the safety of numerous methods across various numeric primitive types.

Our work contributes to the robustness of Rust's standard library and highlights the importance of formal verification tools in modern software development.

We hope this post provides valuable insights into the verification process of unsafe numeric methods in Rust. If you're interested in formal verification or Rust programming, we encourage you to explore [Kani](https://github.com/model-checking/kani) and contribute to its ongoing development.

## References
[1] [Kani Documentation](https://model-checking.github.io/kani/)
* Rust Numeric Types
* Rust Intrinsics

[2] Kani [PR#3660](https://github.com/model-checking/kani/pull/3660) and [PR#3701](https://github.com/model-checking/kani/pull/3701) to resolve [Kani Issue#3629](https://github.com/model-checking/kani/issues/3629).

[3] Kani [PR#3742](https://github.com/model-checking/kani/pull/3742) to resolve [Kani Issue#3711](https://github.com/model-checking/kani/issues/3711).

[4] [Challenge 11: Safety of Methods for Numeric Primitive Types](https://model-checking.github.io/verify-rust-std/challenges/0011-floats-ints.html)