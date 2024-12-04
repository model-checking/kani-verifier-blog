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
**FIXME: Use some examples, e.g.**
* `from_bytes_with_nul`
* `to_bytes` (introduced helper function `arbitray_cstr`)
* any of `bytes`, `to_str`, `as_ptr`?

###  Prologue: `from_bytes_with_nul`
#### Input generation
Initially, we entered a logical fallacy that we have to explicitly define harnesses for different test cases, e.g. xxx. However, in formal verification, we shouldn't set restrictions on inputs since our goal is to verify a function behaves as expected given ALL possible input values. Ref: https://github.com/model-checking/verify-rust-std/discussions/181#discussioncomment-11376618

Defined a max array size for verification to avoid performance issue. At first, generated a fixed size array as inputs, but found that we had to verify all arrays with length <= the max array size. Therefore, leveraged `kani::any_slice_of_array` to obtain an input slice from the fixed size array. This covers every cases for `from_bytes_with_nul`.

#### Verification checks
1. Correctness check (`let OK(c_str)` that part)
2. Safety check (`c_str.is_safe()` part)

#### Run Kani on the `from_bytes_with_nul` harness
Maybe talk about loop unwinding here.
1. What happens if not using `kani::unwind` -> Kani runs indefinitely (unbounded verification)
2. Loop unwinding -> Bounded verification
https://model-checking.github.io/kani/tutorial-loop-unwinding.html

### Interlude
**FIXME: transitions here**

#### Helper function `arbitray_cstr`
We are verifying some CStr methods calling on the CStr itself. So we want to generate an arbitrary CStr to verify those methods, just like we generated an input slice for `from_bytes_with_nul`.

The function xxx. For better performance, it assumes that all input slices **preconditions** so that no need to waste time calling `from_bytes_until_nul` on invalid slices (i.e. slices that xxx).

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

#### Example Usage: `to_bytes` harness

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

## Part 3: whether to keep this depends on work progress

## Challenges Encountered & Lessons Learned
### Input Generation
`any_slice_of_array`

### Unbounded Proofs
loop unwinding

## Conclusion
**FIXME**

## References
[1] [Safety Invariant](https://rust-lang.github.io/unsafe-code-guidelines/glossary.html#validity-and-safety-invariant)
[2] xx