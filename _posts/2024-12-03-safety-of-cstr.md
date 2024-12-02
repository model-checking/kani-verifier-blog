---
title: Safety of CStr
layout: post
---

**FIXME: overview**
**FIXME: title should indicate that this challenge is incomplete. like Safety of CStr: Part 1 or something?**

## Introduction
**FIXME**

## Challenge Overview
**FIXME**

## Part 1: Safety Invariant
**FIXME: add a brief intro of safety invariant here and how it helps verifying CStr**

### Implementation
**FIXME: 1. Invariant trait impl for CStr, 2. Definition of a safe, valid CStr**
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

### Run Kani on the `from_bytes_with_nul` harness
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

#### Example Usage: `to_bytes`

```rust
// pub const fn to_bytes(&self) -> &[u8]
#[kani::proof]
#[kani::unwind(32)]
fn check_to_bytes() {
    const MAX_SIZE: usize = 32;
    let string: [u8; MAX_SIZE] = kani::any();
    let slice = kani::slice::any_slice_of_array(&string);
    let c_str = arbitrary_cstr(slice);

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

## Challenges Encountered
**FIXME**

## Lessons Learned
**FIXME**

## Conclusion
**FIXME**

## References
[1] xx
[2] xx