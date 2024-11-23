---
title: Safety of Methods for Numeric Primitive Types
link_to_challenge: [Safety Verification: Floats and Integers](https://model-checking.github.io/verify-rust-std/challenges/0011-floats-ints.html)
layout: post
---

In this blog post, we discuss on verifying the absence of arithmetic overflow/underflow and undefined behavior in various unsafe methods provided by Rust's numeric primitive types, given that their safety preconditions are satisfied.

The post is divided into three parts:

- Unsafe Integer Methods: Prove safety of methods like ```unchecked_add```, ```unchecked_sub```, ```unchecked_mul```, ```unchecked_shl```, ```unchecked_shr```, and ```unchecked_neg``` for various integer types.
- Safe API Verification: Verify safe APIs that leverage the unsafe integer methods from Part 1, such as ```wrapping_shl```, ```wrapping_shr```, ```widening_mul```, and ```carrying_mul```.
- Float to Integer Conversion: Verify the absence of undefined behavior in ```to_int_unchecked``` for floating-point types ```f16``` and ```f128```.FIXME: should we include f16 and f32 as well? 

In addition to verifying the methods under their specified safety preconditions, we needed to ensure the absence of specific undefined behaviors:

- Invoking undefined behavior via compiler intrinsics.<br />
- Reading from uninitialized memory.<br />
- Mutating immutable bytes.<br />
- Producing an invalid value.<br />

## Approach and Implementation.

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



An example of how we specified safety preconditions in the code is as follows:
### Specifying Safety Preconditions

```rust
#[inline(always)]
#[cfg_attr(miri, track_caller)] // even without panics, this helps for Miri backtraces
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
Here, the ``` #[requires]``` attribute is used to specify that unchecked_add requires the addition to not overflow. This ensures that the function operates within defined behavior when called in an unsafe context.

### Generating Verification Harnesses
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

                // Assume no overflow occurs
                kani::assume(!num1.overflowing_add(num2).1);

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
In the harness, we:

- Symbolic Values: We generated symbolic values (```num1``` and ```num2```) using ```kani::any```.
- Assumptions: Assumed that no overflow occurs using ```kani::assume```.
- Unsafe Execution: Called ```unchecked_add``` within an unsafe block for verification.
### Handling Large Input Spaces
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

By focusing on critical ranges, we ensured that the verification process remained tractable while still covering important cases where overflows are likely to occur.

## Verifying Safe APIs
We also verified safe APIs that internally use the unsafe methods. For example, verifying widening_mul for u16:

```rust
generate_widening_mul_intervals!(u16, u32,
    widening_mul_u16_small, 0u16, 10u16,
    widening_mul_u16_large, u16::MAX - 10u16, u16::MAX,
    widening_mul_u16_mid_edge, (u16::MAX / 2) - 10u16, (u16::MAX / 2) + 10u16
);
```

This macro generates harnesses that verify widening_mul over specified input intervals, ensuring that it operates safely across different ranges. By verifying these safe APIs, we validated that they uphold Rust's safety guarantees, even when internally relying on unsafe methods.

## Verifying Float to Integer Conversion : 

For the to_int_unchecked method, we specified preconditions to ensure the float is finite and within the representable range:

```rust
#[requires(self.is_finite() && self >= Self::MIN && self <= Self::MAX)]
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

                // Assume preconditions
                kani::assume(num.is_finite());
                kani::assume(num >= <$intType>::MIN as $floatType);
                kani::assume(num <= <$intType>::MAX as $floatType);

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

## Challenges and Lessons Learned

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
(Kani Documentation)[https://model-checking.github.io/kani/]
Rust Numeric Types
Rust Intrinsics







