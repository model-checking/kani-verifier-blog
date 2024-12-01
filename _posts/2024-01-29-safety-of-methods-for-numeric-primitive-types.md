---
title: Safety of Methods for Numeric Primitive Types
layout: post
---

In this blog post, we discuss how we verified the absence of arithmetic overflow/underflow and undefined behavior in various unsafe methods provided by Rust's numeric primitive types, given that their safety preconditions are satisfied.

## Introduction
Ensuring the correctness and safety of numeric operations is crucial for developing reliable systems. In high-performance applications, numeric operations often require bypassing checks to maximize efficiency. However, ensuring the safety of these methods under their stated preconditions is critical to preventing undefined behavior.

In the past 3 months, we have rigorously analyzed unsafe methods provided by Rust's numeric primitive types, such as `unchecked_add` and `unchecked_sub`, which omit runtime checks for overflow and underflow, using formal verification techniques.



**FIXME: Change file name -- e.g. 2024-12-02**

## Challenge Overview
The [challenge](https://model-checking.github.io/verify-rust-std/challenges/0011-floats-ints.html) is divided into three parts:
- [Part 1] Unsafe Integer Methods: Prove safety of methods like ```unchecked_add```, ```unchecked_sub```, ```unchecked_mul```, ```unchecked_shl```, ```unchecked_shr```, and ```unchecked_neg``` for various integer types.
- [Part 2] Safe API Verification: Verify safe APIs that leverage the unsafe integer methods from Part 1, such as ```wrapping_shl```, ```wrapping_shr```, ```widening_mul```, and ```carrying_mul```.
- [Part 3] Float to Integer Conversion: Verify the absence of undefined behavior in ```to_int_unchecked``` for floating-point types ```f16``` and ```f128```. **FIXME: should we include f32 and f64 as well?**

In addition to verifying the methods under their specified safety preconditions, we needed to ensure the absence of specific undefined behaviors:
- Invoking undefined behavior via compiler intrinsics.
- Reading from uninitialized memory.
- Mutating immutable bytes.
- Producing an invalid value.

## Approach and Implementation
To tackle this challenge, we utilized Kani's verification capabilities to write proof harnesses for the unsafe methods. Our strategy involved:
1. **Specifying Safety Preconditions**: To ensure the methods behaved correctly, we explicitly specified safety preconditions in the code. These preconditions were used to:
   - Guide input generation.
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

### 1. Specifying Safety Preconditions
```rust
#[requires(!self.overflowing_add(rhs).1)]
pub const unsafe fn unchecked_add(self, rhs: Self) -> Self {
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
Here, the ```#[requires]``` attribute is used to specify that `unchecked_add` requires the addition to not overflow. This ensures that the function operates within defined behavior when called in an unsafe context. While we directly leveraged the existing precondition in `unchecked_add`, not every function has an explicit precondition check. Still, we can write preconditions for unsafe functions based on the `SAFETY` section in the official documentation or the `SAFETY` comments in the source code.

The same logic applies to the postconditions (`#[ensure]`) of a function.

### 2. Generating Verification Harnesses
We created macros to generate verification harnesses for each method and type. For example, to generate harnesses for ```unchecked_add```:
```rust
#[cfg(kani)]
mod verify {
    use super::*;

    macro_rules! generate_unchecked_math_harness {
        ($type:ty, $method:ident, $harness_name:ident) => {
            #[kani::proof_for_contract($type::$method)]
            pub fn $harness_name() {
                let num1: $type = kani::any::<$type>();
                let num2: $type = kani::any::<$type>();

                unsafe {
                    num1.$method(num2);
                }
            }
        }
    }

    generate_unchecked_math_harness!(i8, unchecked_add, unchecked_add_i8);
    generate_unchecked_math_harness!(i16, unchecked_add, unchecked_add_i16);
    // ... Repeat for other integer types
}
```
The harness contains several parts:
- Symbolic values: These values (```num1``` and ```num2```) are generated by Kani using ```kani::any```.
- Assumptions: With `#[kani::proof_for_contract]` annotation, Kani automatically inserts `kani::assume()` before the unsafe function call. It ensures that all generated values respect the preconditions of `unchecked_add`. For further details, you can refer to [Kani official RFC for function contracts]([url](https://github.com/model-checking/kani/blob/main/rfc/src/rfcs/0009-function-contracts.md#user-experience)).
- Unsafe Execution: The invocation of ```unchecked_add``` within an unsafe block for verification.

### 3. Handling Large Input Spaces
For methods like ```unchecked_mul```, verifying over the entire input space is infeasible due to the exponential number of possibilities. We addressed this by partitioning the input space into intervals:
```rust
generate_unchecked_mul_intervals!(i32, unchecked_mul,
    unchecked_mul_i32_small, -10i32, 10i32,
    unchecked_mul_i32_large_pos, i32::MAX - 1000i32, i32::MAX,
    unchecked_mul_i32_large_neg, i32::MIN, i32::MIN + 1000i32,
    unchecked_mul_i32_edge_pos, i32::MAX / 2, i32::MAX,
    unchecked_mul_i32_edge_neg, i32::MIN, i32::MIN / 2
);
```
**FIXME: A deeper explanation for "critical ranges" and "important cases".**
By focusing on critical ranges, we ensured that the verification process remained tractable while still covering important cases where overflows are likely to occur.

## Part 2: Verifying Safe APIs
We also verified safe APIs that internally use the previously verified unsafe methods through the above workflow. For example, verifying `widening_mul` for `u16`:
```rust
generate_widening_mul_intervals!(u16, u32,
    widening_mul_u16_small, 0u16, 10u16,
    widening_mul_u16_large, u16::MAX - 10u16, u16::MAX,
    widening_mul_u16_mid_edge, (u16::MAX / 2) - 10u16, (u16::MAX / 2) + 10u16
);
```

This macro generates harnesses that verify `widening_mul` over specified input intervals, ensuring that it operates safely across different ranges. By verifying these safe APIs, we validated that they uphold Rust's safety guarantees, even when internally relying on unsafe methods.

## Part 3: Verifying Float to Integer Conversion
For the `to_int_unchecked` method, we specified preconditions to ensure the float is finite and within the target integer type's representable range:
**FIXME: Kani Issue pending**
```rust
#[requires(self.is_finite() && self >= Self::MIN && self <= Self::MAX)] // FIXME
pub unsafe fn to_int_unchecked<Int>(self) -> Int where Self: FloatToInt<Int> {
    // Implementation
}
```
Our harnesses then verified that, under these preconditions, the conversion does not result in undefined behavior:
```rust
macro_rules! generate_to_int_unchecked_harness {
    ($floatType:ty, $($intType:ty, $harness_name:ident),+) => {
        $(
            #[kani::proof_for_contract($floatType::to_int_unchecked)]
            pub fn $harness_name() {
                let num: $floatType = kani::any();
                let result = unsafe { num.to_int_unchecked::<$intType>() };

                assert_eq!(result, num as $intType);
            }
        )+
    }
}

generate_to_int_unchecked_harness!(f128,
    i8, to_int_unchecked_f128_i8,
    i16, to_int_unchecked_f128_i16,
    // ... Repeat for other integer types
);
```

## Challenges Encountered and Lessons Learned
**FIXME: refine and format**
Handling Exponential Input Spaces
Some methods, especially those involving large integer types, posed significant challenges due to the size of their input spaces. We mitigated this by:

Partitioning Input Ranges: Focusing on critical intervals where overflows are likely.
Assumptions: Using kani::assume to limit inputs to manageable ranges.
Ensuring Correctness of Assumptions
Ensuring that our assumptions accurately reflected the safety preconditions was critical. Any incorrect assumption could lead to unsound verification results.

Efficient Macro Usage
Writing macros that generate a large number of harnesses required careful design to maintain readability and avoid code duplication.

Conclusion
This challenge provided valuable insights into the process of formally verifying unsafe methods in Rust's standard library. By leveraging Kani and carefully designing our verification harnesses, we successfully demonstrated the safety of numerous methods across various numeric primitive types.

Our work contributes to the robustness of Rust's standard library and highlights the importance of formal verification tools in modern software development.

We hope this post provides valuable insights into the verification process of unsafe numeric methods in Rust. If you're interested in formal verification or Rust programming, we encourage you to explore Kani and contribute to its ongoing development.

## References
[Kani Documentation](https://model-checking.github.io/kani/)
- Rust Numeric Types
- Rust Intrinsics

Link to the challenge: [Safety Verification: Floats and Integers](https://model-checking.github.io/verify-rust-std/challenges/0011-floats-ints.html)
