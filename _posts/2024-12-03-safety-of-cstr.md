---
title: Safety of CStr (Tentative)
layout: post
---

Authors: [Rajath M Kotyal](https://github.com/rajathkotyal), [Yen-Yun Wu](https://github.com/Yenyun035), [Lanfei Ma](https://github.com/lanfeima), [Junfeng Jin](https://github.com/MWDZ)

In this blog post, we discuss how we verified that the safety invariant holds in various safe and unsafe methods provided by the Rust's `CStr` type.

## Introduction
The `CStr` type in Rust serves as a bridge between Rust and C, enabling safe handling of null-terminated C strings. While `CStr` provides an abstraction for safe interaction, ensuring its safety invariant is vital to prevent undefined behavior, such as invalid memory access or data corruption.

In this blog post, we delve into the process of formally verifying the safety of `CStr` using [AWS Kani](https://github.com/model-checking/kani). By examining its safe and unsafe methods, we ensure that they adhere to Rust's strict safety guarantees. Through this effort, we highlight the importance of robust verification for low-level abstractions in Rust's ecosystem.

## Challenge Overview
The [`CStr` challenge](https://github.com/model-checking/verify-rust-std/blob/main/doc/src/challenges/0013-cstr.md) is divided into four parts:
1. Safety Invariant: Define and implement the Invariant trait for `CStr` to enforce null-termination and absence of interior null bytes.
2. Safe CStr Function Verification: Verify that safe functions like `from_bytes_with_nul` and `to_bytes` maintain the `CStr` safety invariant.
3. Unsafe CStr Function Verification: Define function contracts for unsafe functions. Verify that unsafe functions, such as `from_bytes_with_nul_unchecked` and `strlen`, maintain the `CStr` safety invariant.
4. Trait Implementation Verification: Verify that the trait implementations of `CloneToUninit` and `ops::Index<RangeFrom<usize>>` for `CStr` are safe.

In addition to verifying the safety invariant preservation after function call, we needed to ensure the absence of specific [undefined behaviors](https://github.com/rust-lang/reference/blob/142b2ed77d33f37a9973772bd95e6144ed9dce43/src/behavior-considered-undefined.md):
- Accessing (loading from or storing to) a place that is dangling or based on a misaligned pointer.
- Performing a place projection that violates the requirements of in-bounds pointer arithmetic.
- Mutating immutable bytes.
- Accessing uninitialized memory.

We will discuss Part 1, Part 2, and Part 3 in this blog post.

## Part 1: Safety Invariant
The [safety invariant](https://rust-lang.github.io/unsafe-code-guidelines/glossary.html#validity-and-safety-invariant) defines the conditions that safe code can assume about data to justify its operations. While unsafe code may temporarily violate this invariant, the invariant must be upheld when interacting with unknown safe code. In this challenge, the safety invariant is used to verify that the methods of the `CStr` type are sound, ensuring they safely encapsulate their underlying unsafety.

The safety invariant in Rust is defined as the `Invariant` trait:
```rust
pub trait Invariant {
    /// Specify the type's safety invariants 
    fn is_safe(&self) -> bool;
}
```

### Implementation
If you're familiar with C, you likely know that a [C-string](https://en.wikipedia.org/wiki/C_string_handling#Definitions) is simply an array of bytes ending with a null terminator to mark the end of the string. Therefore, we can define a valid `CStr` as:
1. A empty `CStr` only contains a null byte.
2. A non-empty `CStr` should end with a null-terminator and contains no intermediate null bytes.

The following code shows the implementation of the `Invariant` trait for `CStr`:
```rust
#[unstable(feature = "ub_checks", issue = "none")]
impl Invariant for &CStr {
    /**
     * Safety invariant of a valid CStr:
     * 1. An empty CStr should have a null byte.
     * 2. A valid CStr should end with a null-terminator and contains
     *    no intermediate null bytes.
     */
    fn is_safe(&self) -> bool {
        let bytes: &[c_char] = &self.inner;
        let len = bytes.len();

        !bytes.is_empty() && bytes[len - 1] == 0 && !bytes[..len-1].contains(&0)
    }
}
```
`bytes` represents the private field of `CStr` that holds an array of bytes, including the null terminator. For any valid CStr, bytes is never empty, as it must contain at least a null byte. This refers to the `!bytes.is_empty()` check.

The checks `bytes[len - 1] == 0` and `!bytes[..len-1].contains(&0)` correspond to the two aforementioned conditions: ensuring the byte sequence ends with a null terminator and contains no interior null bytes, respectively.

## Part 2: Safe CStr functions
In this section, we focus on verifying the safe methods provided by CStr. Specifically, we examine `from_bytes_with_nul` and `to_bytes`, ensuring they maintain the safety invariant of CStr.We also introduce a helper function `arbitray_cstr` to aid in the verification process.

###  Prologue: `from_bytes_with_nul`
#### Input generation
Initially, we entered a logical fallacy that we have to explicitly define harnesses for different test cases, e.g. xxx. However, in formal verification, we shouldn't set restrictions on inputs since our goal is to verify a function behaves as expected given ALL possible input values. Ref: https://github.com/model-checking/verify-rust-std/discussions/181#discussioncomment-11376618

Defined a max array size for verification to avoid performance issue. At first, generated a fixed size array as inputs, but found that we had to verify all arrays with length <= the max array size. Therefore, leveraged `kani::any_slice_of_array` to obtain an input slice from the fixed size array. This covers every cases for `from_bytes_with_nul`.

#### Verification checks

1. Correctness Check: Ensures that the function returns `Ok` when given valid input and that the resulting `CStr` is as expected.
2. Safety Check: Verifies that the resulting `CStr` satisfies the safety invariant by calling `is_safe()`.

Code for verifying the safe function `from_bytes_with_nul` code:

In this harness:

- We generate an arbitrary byte array of size up to MAX_SIZE.
- We obtain a slice of this array.
- We attempt to create a CStr using from_bytes_with_nul.
- If the creation is successful, we verify that the resulting CStr satisfies the safety invariant.

```rust
#[kani::proof]
#[kani::unwind(32)]
fn check_from_bytes_with_nul() {
    const MAX_SIZE: usize = 32;
    let bytes: [u8; MAX_SIZE] = kani::any();
    let slice = kani::slice::any_slice_of_array(&bytes);

    // Attempt to create a CStr from the slice
    let result = CStr::from_bytes_with_nul(slice);
    if let Ok(c_str) = result {
        // Verify that the CStr satisfies the safety invariant
        assert!(c_str.is_safe());
    }
}
```

#### Run Kani on the `from_bytes_with_nul` harness

In this verification harness, we use `#[kani::unwind(32)]` because we're working with a `MAX_SIZE` of `32` bytes. The unwinding bound needs to accommodate:

- The main loop that processes the bytes
- Any additional iterations for safety checks (e.g., searching for null terminators)

We sometimes need to unwind one extra time, eg. `#[kani::unwind(33)]` to verify the null terminator at position `32`. This is particularly important for functions that:
Scan for null bytes (like `strlen`)
- Verify string boundaries
- Check array indices up to and including the null terminator
- The unwinding bound must be ≥ MAX_SIZE + 1 to ensure complete verification of all possible execution paths, including edge cases involving the null terminator.

More about loop unwind : https://model-checking.github.io/kani/tutorial-loop-unwinding.html

### Interlude

To verify methods that operate on CStr instances, we need a way to generate arbitrary valid CStr objects. The `arbitrary_cstr` helper function serves this purpose.

#### Helper function `arbitray_cstr`
We are verifying some CStr methods calling on the CStr itself. So we want to generate an arbitrary CStr to verify those methods, just like we generated an input slice for `from_bytes_with_nul`.

The `arbitray_cstr` function:

- Assumes that the input slice is **non-empty** and ends with a **null terminator**.
- Attempts to create a `CStr` using `from_bytes_until_nul`.
- Verifies that the creation is successful and that the resulting `CStr` satisfies the safety invariant.

```rust
fn arbitrary_cstr(slice: &[u8]) -> &CStr {
	// At a minimum, the slice has a null terminator to form a valid CStr.
	kani::assume(slice.len() > 0 && slice[slice.len() - 1] == 0);
	let result = CStr::from_bytes_until_nul(&slice);
	// Given the assumption, from_bytes_until_nul should never fail
    assert!(result.is_ok());
	let c_str = result.unwrap();
	assert!(c_str.is_safe());
	c_str
}
```

#### Example Usage in the `to_bytes` harness: 

The `to_bytes` method returns the byte slice of a `CStr` without the null terminator. We need to verify that this method behaves correctly for arbitrary valid `CStr` instances.

```rust
// pub const fn to_bytes(&self) -> &[u8]
#[kani::proof]
#[kani::unwind(32)]
fn check_to_bytes() {
    const MAX_SIZE: usize = 32;
    let string: [u8; MAX_SIZE] = kani::any();
    let slice = kani::slice::any_slice_of_array(&string);
    let c_str = arbitrary_cstr(slice); // Creation of a valid CStr

    let bytes = c_str.to_bytes();
    let end_idx = bytes.len();
    // Comparison does not include the null byte
    assert_eq!(bytes, &slice[..end_idx]);
    assert!(c_str.is_safe());
}
```

### Epilogue: `some_CStr_function` worth talking about
**FIXME**
### Example: `count_bytes`

The `count_bytes` method is designed to efficiently return the length of a C-style string, excluding the null terminator. It is implemented as a constant-time operation based on the string's internal representation, which stores the length and null terminator.

### Harness: `check_count_bytes`

```rust
#[kani::proof]
#[kani::unwind(32)]
fn check_count_bytes() {
    const MAX_SIZE: usize = 32;
    let mut bytes: [u8; MAX_SIZE] = kani::any();
    
    // Non-deterministically generate a length within the valid range [0, MAX_SIZE]
    let mut len: usize = kani::any_where(|&x| x < MAX_SIZE);
    
    // If a null byte exists before the generated length
    // adjust len to its position
    if let Some(pos) = bytes[..len].iter().position(|&x| x == 0) {
        len = pos;
    } else {
        // If no null byte, insert one at the chosen length
        bytes[len] = 0;
    }

    let c_str = CStr::from_bytes_until_nul(&bytes).unwrap();
    // Verify that count_bytes matches the adjusted length
    assert_eq!(c_str.count_bytes(), len);
}
```

To validate the design and correctness of the `count_bytes` method, we use the following harness. It ensures that the method works as expected for all valid inputs, handling cases where the null byte is already present or needs to be inserted.

The count_bytes method leverages Rust's memory-safe guarantees and the internal structure of CStr to provide efficient length computation.

## Part 3: Unsafe Methods

In this section, we focus on verifying the unsafe methods provided by CStr. Specifically, we examine `from_bytes_with_nul_unchecked`, `strlen`, and `from_ptr`, ensuring they maintain the safety invariant when used correctly.

### `from_bytes_with_nul_unchecked`

The `from_bytes_with_nul_unchecked` function creates a CStr from a `byte` slice **without** performing any checks. It is marked unsafe because incorrect usage can lead to undefined behavior.

**Function Contract**
We define the preconditions and postconditions as follows :

#### Preconditions (`#[requires]`):
- The byte slice must not be empty.
- The last byte must be a null terminator `(0)`.
- There must be no null bytes within the slice except at the end.

#### Postconditions (`#[ensures]`):
- The resulting `CStr` must satisfy the safety invariant, ensuring it is a valid C string.

```rust
#[requires(
    !bytes.is_empty() &&
    bytes[bytes.len() - 1] == 0 &&
    !bytes[..bytes.len() - 1].contains(&0)
)]
#[ensures(|result| result.is_safe())]
pub const unsafe fn from_bytes_with_nul_unchecked(bytes: &[u8]) -> &CStr {
    // Implementation
}
```

Verification Harness : 
```rust
#[kani::proof_for_contract(CStr::from_bytes_with_nul_unchecked)]
#[kani::unwind(32)]
fn check_from_bytes_with_nul_unchecked() {
    let max_size = 32;
    let len: usize = kani::any_where(|&len| len > 0 && len <= max_size);
    let mut bytes = vec![0u8; len];
    for i in 0..(len - 1) {
        bytes[i] = kani::any_where(|&b| b != 0);
    }
    bytes[len - 1] = 0; // Null terminator

    // Unsafe block to call the unsafe function
    let c_str = unsafe { CStr::from_bytes_with_nul_unchecked(&bytes) };
    // Verify that the resulting CStr satisfies the safety invariant
    assert!(c_str.is_safe());
}
```
- We generate a byte vector of arbitrary length up to `max_size`.
- The vector is filled with non-`zero` bytes, ensuring no interior null bytes.
- The last byte is set to zero to serve as the null terminator.
- We call `from_bytes_with_nul_unchecked` within an unsafe block and verify that the resulting `CStr` satisfies the safety invariant.


### `strlen`
**FIXME**

### `from_ptr`
**FIXME**

## Challenges Encountered & Lessons Learned

### Input Generation

One of the main challenges was generating appropriate inputs for verification. Initially, we considered generating specific test cases, but formal verification requires exploring all possible inputs within the specified bounds.

We utilized `kani::any_slice_of_array `and `kani::any_where` to generate arbitrary inputs while enforcing preconditions. This approach allowed us to cover a wide range of input scenarios, ensuring thorough verification.

### Unbounded Proofs and Loop Unwinding

Another challenge was dealing with unbounded loops in functions like strlen. Without setting an unwinding bound, Kani would run indefinitely. We addressed this by using `#[kani::unwind(N)]` to specify loop bounds, enabling Kani to perform bounded verification effectively.

### Verifying Unsafe Code

Verifying unsafe functions required precise specification of preconditions and postconditions. We needed to ensure that our contracts accurately captured the requirements for safe usage. This involved careful analysis of pointer accessibility, null termination, and memory safety.

### Balancing Verification Depth and Performance

Setting appropriate unwinding bounds was crucial to balance the depth of verification and performance. Larger bounds increase verification time, so we needed to choose values that provided sufficient coverage without excessive resource consumption.

## Conclusion

Through this project, we successfully verified that the safe and unsafe methods of Rust's CStr type uphold the safety invariant and prevent undefined behavior when used correctly. By leveraging formal verification with Kani, we ensured that these fundamental abstractions in Rust's standard library are reliable and robust.

This effort highlights the importance of formal methods in verifying low-level code, especially when dealing with unsafe operations and foreign function interfaces. By providing precise contracts and thorough verification harnesses, we contribute to Rust's mission of safety and reliability.

## References
[1] [Safety Invariant](https://rust-lang.github.io/unsafe-code-guidelines/glossary.html#validity-and-safety-invariant)
[2] [Challenge 13](https://github.com/model-checking/verify-rust-std/issues/150) 
