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

In Part 2, we verified 9 safe `CStr` methods in [`core::ffi::c_str`](https://doc.rust-lang.org/stable/std/ffi/struct.CStr.html).

In this section, we outline our approach to verifying the safe methods of CStr using `from_bytes_with_nul` as an example. We then introduce `arbitrary_cstr`, a helper function that simplifies and supports the verification process, and demonstrate its utility with the `to_bytes` method as an example.

### Prologue: `from_bytes_with_nul`

We started with the harness for `from_bytes_with_nul`:

```rust
// pub const fn from_bytes_until_nul(bytes: &[u8]) -> Result<&CStr, FromBytesUntilNulError>
#[kani::proof]
#[kani::unwind(32)]
fn check_from_bytes_until_nul() {
    const MAX_SIZE: usize = 32; // Bound the verification size
    let string: [u8; MAX_SIZE] = kani::any();                   // (1)
    // Covers the case of a single null byte at the end, no null bytes, as
    // well as intermediate null bytes
    let slice = kani::slice::any_slice_of_array(&string);       // (1)

    let result = CStr::from_bytes_until_nul(slice);             // (2)
    if let Ok(c_str) = result {                                 // (3)
        assert!(c_str.is_safe());                               // (4)
    }
}
```

The harness consists of several components:

1. **Input Generation**: Use Kani to generate an input slice from a fixed-size, non-deterministic array, covering all possible inputs.
2. **Method Invocation**: Invoke the method under verification (`from_bytes_with_nul`) on the Kani-generated input.
3. **Result Check**: Validate the output of `from_bytes_with_nul`, which either returns an error or a reference to a CStr, depending on the input.
4. **Property Assertions & Correctness Checks**: Confirm that the result adheres to the expected behavior and upholds the safety invariant.

#### Input Generation

Initially, we fell into the logical fallacy of believing that we needed to explicitly define harnesses for specific test cases, such as a single null byte at the end, no null bytes, or intermediate null bytes. However, the essence of formal verification lies in avoiding restrictions on inputs, as the goal is to ensure the function behaves correctly across *all* possible inputs.

Our new approach involved generating an arbitrary, fixed-size array and taking a slice of it using Kani. The [`any_slice_of_array`](https://model-checking.github.io/kani/crates/doc/kani/slice/fn.any_slice_of_array.html) function proved invaluable for this purpose, as it allows us to consider all possible slices with a length less than or equal to MAX_SIZE. Restricting the array size serves to bound the verification scope. While strings can theoretically be infinitely long, this constraint strikes a balance between thorough verification and computational feasibility. On the other hand, by capturing slices from a fixed-size array, we ensured that a single harness could cover all possible scenarios: input slices with a null byte at the end, no null bytes, or even intermediate null bytes.

#### Verification Checks

After method invocation, we had two checks:

1. **Correctness Checks**: Ensure that the function returns `Ok` instead of an error when an valid input is given. An `Ok` result simply indicates that a `CStr` instance was successfully created; it does not inherently guarantee the safety of the `CStr`.
2. **Safety Checks**: Verify that the resulting `CStr` satisfies the safety invariant by calling `is_safe()`.

#### Performance Improvement

You may have noticed the use of `#[kani::unwind(32)]` in the harness. This was necessary since we were working with a `MAX_SIZE` of `32` bytes. The unwinding bound must account for:

- The main loop that processes the bytes, and
- Any additional iterations for safety checks, such as searching for null terminators.

In some cases, we need to unwind one extra iteration, such as with `#[kani::unwind(33)]`, to verify the presence of a null terminator (at position 32). This is especially crucial for functions that:

- Scan for null bytes (e.g. `strlen`)
- Verify string boundaries
- Check array indices up to and including the null terminator

The unwinding bound must be greater and equal to `MAX_SIZE + 1` to ensure complete verification of all possible execution paths, including edge cases involving the null terminator.

You can find more about [loop unwinding](https://model-checking.github.io/kani/tutorial-loop-unwinding.html) in the Kani tutorial.

### Interlude: Helper Function `arbitray_cstr`

In many cases, we needed to verify `CStr` methods that operate directly on a `CStr` object itself. To achieve this, we would like to generate an arbitrary `CStr` instance for verification, similar to how we generated input slices for `from_bytes_with_nul`.

The following code shows the implementation of `arbitray_cstr`:

```rust
fn arbitrary_cstr(slice: &[u8]) -> &CStr {
	// At a minimum, the slice has a null terminator to form a valid CStr.
	kani::assume(slice.len() > 0 && slice[slice.len() - 1] == 0);          // (1)
	let result = CStr::from_bytes_until_nul(&slice);                       // (2)
	// Given the assumption, from_bytes_until_nul should never fail
        assert!(result.is_ok());                                               // (3)
	let c_str = result.unwrap();
	assert!(c_str.is_safe());                                              // (4)
	c_str
}
```

`arbitray_cstr` consists of four key steps:

1. **Assumption**: Assumes that the input slice is non-empty and ends with a null terminator. This is a small optimization which guarantees that the input slice contains at least a null terminator.
2. **`CStr` Creation**: Attempts to construct a `CStr` using `from_bytes_until_nul`.
3. **Result Validation**: Confirms that the creation is successful.
4. **Invariant Check**: Validates that the resulting `CStr` adheres to the safety invariant.

#### Example Usage in the `to_bytes` harness:

The `to_bytes` method returns the byte slice of a `CStr` without the null terminator. Our goal was to verify that `to_bytes` behaves correctly for arbitrary valid `CStr` instances.

The following code block shows the `to_bytes` harness:

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

Before invoking the method under verification, we constructed a valid, safe `CStr` using `arbitrary_cstr`. Then, we called `to_bytes` on the `CStr` instance and performed both a correctness check and a safety check. We verified that `to_bytes` accurately returns the same content as the input slice and that the `CStr` continues to uphold the safety invariant after `to_bytes` is called.

With `arbitrary_cstr`, we achieved two key benefits:

1. We eliminated code duplication and improved code maintainability by centralizing the logic for generating valid `CStr` instances.
2. We ensured consistency and reliability in our verification process by leveraging a standardized method for constructing `CStr` objects that conform to the safety invariant.

### Epilogue: `count_bytes` & `as_ptr`

In the previous sections, we detailed our verification approach. Now, let's highlight a few other harnesses that we found interesting or challenging, focusing on `count_bytes` and `as_ptr.`

### Example: `count_bytes`

The `count_bytes` method is designed to efficiently return the length of a C-style string, excluding the null terminator. It is implemented as a constant-time operation based on the string's internal representation, which stores the length and null terminator.

To validate the design and correctness of the `count_bytes` method, we use the following harness. It ensures that the method works as expected for all valid inputs, handling cases where the null byte is already present or needs to be inserted.

```rust
#[kani::proof]
#[kani::unwind(32)]
fn check_count_bytes() {
    const MAX_SIZE: usize = 32;
    let mut bytes: [u8; MAX_SIZE] = kani::any();
    // Non-deterministically generate a length within the valid range [0, MAX_SIZE)
    let mut len: usize = kani::any_where(|&x| x < MAX_SIZE);
  
    // If a null byte exists before the generated length
    // adjust `len` to its position
    if let Some(pos) = bytes[..len].iter().position(|&x| x == 0) {
        len = pos;
    } else {
        // If no null byte, insert one at the chosen length
        bytes[len] = 0;
    }

    let c_str = CStr::from_bytes_until_nul(&bytes).unwrap();
    // Verify that count_bytes matches the adjusted length
    assert_eq!(c_str.count_bytes(), len);
    assert!(c_str.is_safe());
}
```

This harness was created before the introduction of `arbitrary_cstr`. While it did not utilize `arbitrary_cstr`, the verification logic was similar: generate an input slice, invoke count_bytes, optionally validate the result, and verify the safety invariant.

The harness explicitly handled two scenarios:

- A null byte before the null terminator in the input slice: The position of the null byte was identified, and `len` was dynamically adjusted to reflect its location.
- No null terminator in the input slice: A null byte was explicitly inserted at a designated position to ensure the slice could form a valid C-style string.

We can further enhance the harness by utilizing `arbitrary_cstr` to abstract away the input generation, as demonstrated below:

```rust
#[kani::proof]
#[kani::unwind(32)]
fn check_count_bytes() {
    const MAX_SIZE: usize = 32;
    let string: [u8; MAX_SIZE] = kani::any();
    let slice = kani::slice::any_slice_of_array(&string);
    let c_str = arbitrary_cstr(slice);
    // Retrieve the length of the stored bytes that actually get stored.
    let bytes = c_str.to_bytes();
    let len = bytes.len();
    assert_eq!(c_str.count_bytes(), len);
    assert!(c_str.is_safe());
}
```

By leveraging `arbitrary_cstr`, we avoided manual null insertion and verification. Instead, we relied on `arbitrary_cstr` to produce a valid `CStr` that inherently satisfies the safety invariant. We then directly compared `count_bytes()` with the length of `c_str.to_bytes()` to confirm correctness.

### Example : `as_ptr`

The `as_ptr` method returns a raw pointer to the underlying C string. Although `as_ptr` is safe to call, dereferencing the returned pointer is inherently unsafe. We must verify that `as_ptr` does not violate the safety invariant and that it points to a valid memory region containing the C string plus its null terminator.

The following code block shows the harness for `as_ptr`.

```rust
// pub const fn as_ptr(&self) -> *const c_char
#[kani::proof]
#[kani::unwind(33)] 
fn check_as_ptr() {
    const MAX_SIZE: usize = 32;
    let string: [u8; MAX_SIZE] = kani::any();
    let slice = kani::slice::any_slice_of_array(&string);
    let c_str = arbitrary_cstr(slice);

    let ptr = c_str.as_ptr();
    let bytes_with_nul = c_str.to_bytes_with_nul();
    let len = bytes_with_nul.len();

    // We ensure that `ptr` is valid for reads of `len` bytes
    unsafe {
        for i in 0..len {
            // Iterate and get each byte in the C string from our raw ptr
            let byte_at_ptr = *ptr.add(i);
            // Get the byte at every pos
            let byte_in_cstr = bytes_with_nul[i];
            // Compare the two bytes to ensure they are equal
            assert_eq!(byte_at_ptr as u8, byte_in_cstr);
        }
    }
    assert!(c_str.is_safe());
}
```

In this harness, we confirmed that:

- `as_ptr()` returns a pointer that can be safely read for `len` bytes.
- Each byte read from the raw pointer matches the corresponding byte in `bytes_with_nul`. This verification was performed within an unsafe block, as raw pointer manipulation (e.g., pointer arithmetic) is inherently unsafe.
- The CStr maintains its safety invariant.

## Part 3: Unsafe Methods

In Part 3, we focused on verifying the unsafe methods provided by CStr. Specifically, we examined `from_bytes_with_nul_unchecked`, `strlen`, and `from_ptr`, ensuring they maintain the safety invariant when used correctly.

We followed a similar workflow as before; however, before writing the harnesses, we first annotated the unsafe functions with [function contracts](https://github.com/model-checking/kani/blob/main/rfc/src/rfcs/0009-function-contracts.md).

### `from_bytes_with_nul_unchecked`

Similar to `from_bytes_with_nul`, the `from_bytes_with_nul_unchecked` function creates a `CStr` from a byte slice. However, unlike its checked counterpart, `from_bytes_with_nul_unchecked` performs no validation. As a result, it is marked unsafe because improper usage can lead to undefined behavior.

#### Function Contract

We defined the preconditions and postconditions of `from_bytes_with_nul_unchecked` according to its purpose and the safety requirements from its function documentation:

```rust
/// # Safety
/// The provided slice **must** be nul-terminated and not contain any interior
/// nul bytes.
///
// Function Contract:
#[requires(
    !bytes.is_empty() &&
    bytes[bytes.len() - 1] == 0 &&
    !bytes[..bytes.len() - 1].contains(&0)
)]
#[ensures(|result| result.is_safe())]
pub const unsafe fn from_bytes_with_nul_unchecked(bytes: &[u8]) -> &CStr { /* Implementation */ }
```

#### Preconditions (`#[requires]`)

`from_bytes_with_nul_unchecked` assumes the following:

- The input byte slice must not be empty.
- The last byte must be a null terminator (`0`).
- There must be no null bytes within the slice, except at the end.

Sound familiar? It is because these preconditions align exactly with the safety invariant for `CStr`.

#### Postconditions (`#[ensures]`)

- The resulting `CStr` must satisfy the safety invariant, ensuring it is a valid C string and is safe to use.

#### Verification Harness

The following code shows the harness for the contract of `from_bytes_with_nul_unchecked`, as specified by `proof_for_contract`:

```rust
#[kani::proof_for_contract(CStr::from_bytes_with_nul_unchecked)]
#[kani::unwind(33)]
fn check_from_bytes_with_nul_unchecked() {
    const MAX_SIZE: usize = 32;
    let string: [u8; MAX_SIZE] = kani::any();
    let slice = kani::slice::any_slice_of_array(&string);

    // Kani assumes that the input slice is null-terminated and contains
    // no intermediate null bytes
    let c_str = unsafe { CStr::from_bytes_with_nul_unchecked(slice) };
    // Kani ensures that the output CStr holds the CStr safety invariant

    // Correctness check
    let bytes = c_str.to_bytes();
    let len = bytes.len();
    assert_eq!(bytes, &slice[..len]);
}
```

Similar to `from_bytes_until_nul`, the above harness:

* Generates a byte array of `MAX_SIZE` length.
* Captures a slice of arbitrary-length, up to `MAX_SIZE`.
* Ensures that the input slice meets the preconditions of ``from_bytes_with_nul_unchecked``.
* Calls `from_bytes_with_nul_unchecked` within an unsafe block.
* Verifies that the resulting `CStr` adheres to the safety invariant and contains the same bytes as the input slice.

### `strlen`

#### Function Contract

The `strlen` function computes the length of a null-terminated C string by scanning memory until it finds a null terminator (`0`-value byte). It is defined as unsafe because:

- It operates directly on raw pointers with no built-in checks.
- If the input pointer does not point to a valid null-terminated string within `isize::MAX` bytes, undefined behavior can occur.
- To ensure correct usage, we define the following contract for strlen:

```rust
#[requires(is_null_terminated(ptr))]
#[ensures(|&result| result < isize::MAX as usize && unsafe { *ptr.add(result) } == 0)]
const unsafe fn strlen(ptr: *const c_char) -> usize {
    // Implementation
}
```

#### Preconditions (`#[requires]`)

- `ptr` must point to a valid null-terminated C string. We relied on a helper function `is_null_terminated` to confirm that there is a null terminator within `isize::MAX` bytes of `ptr`. The following code block shows the implementation of `is_null_terminated`:

```rust
#[cfg(kani)]
#[requires(!ptr.is_null())]
fn is_null_terminated(ptr: *const c_char) -> bool {
    let mut next = ptr;
    let mut found_null = false;
    // checks if `next` points to a valid value of type c_char (an 8-bit byte)
    while can_dereference(next) {
        if unsafe { *next == 0 } { // checks for a null terminator
            found_null = true;
            break;
        }
        next = next.wrapping_add(1);
    }
    if (next.addr() - ptr.addr()) >= isize::MAX as usize { // bound checking
        return false;
    }
    found_null
}
```

`is_null_terminated` simply iterates over each valid byte within the `isize::MAX` bound from `ptr` to find a null terminator.

#### Postconditions (`#[ensures]`)

- The returned value (`result`) is strictly less than `isize::MAX`, ensuring the length does not exceed architectural limits.
- `*ptr.add(result)` is 0, confirming that result correctly identifies the position of the null terminator.
- By implication, there are no null bytes before `result`, since `strlen` returns the index of the first null terminator.

#### Verification Harness

```rust
#[kani::proof_for_contract(super::strlen)]
#[kani::unwind(33)]
fn check_strlen_contract() {
    const MAX_SIZE: usize = 32;
    let mut string: [u8; MAX_SIZE] = kani::any();
    let ptr = string.as_ptr() as *const c_char;

    // Since we rely on the precondition that `ptr` must point to a null-terminated string,
    // Kani will assume `is_null_terminated(ptr)` holds. 
    // The harness does not insert explicit null bytes here; it checks whether
    // under the given assumptions, `strlen` maintains its contract.
    unsafe { super::strlen(ptr); }
}
```

This harness contains three parts:

- It generates an arbitrary array of length `MAX_SIZE` with Kani and treats the array as a C string buffer.
- Kani, guided by the preconditions, assumes `is_null_terminated(ptr)` is satisfied for this harness. If this condition is not met, no valid execution path can fulfill the contract.
- By calling `strlen` under these assumptions, it is verified that the input is a proper null-terminated C string. `strlen` will return a correct length and maintain the specified postconditions.

This demonstration ensures that if an external caller meets the preconditions (e.g., ensuring `ptr` points to a null-terminated C string), `strlen` will not introduce undefined behavior.

### `from_ptr`

#### Function Contract

The `from_ptr` function constructs a `CStr` from a raw pointer. It is unsafe because:

- The pointer must not be null.
- The C string must be null-terminated.
- The memory it points to must be valid and must not extend beyond `isize::MAX` bytes.

We specify the following contract to capture these requirements:

```rust
#[requires(!ptr.is_null() && is_null_terminated(ptr))]
#[ensures(|result: &&CStr| result.is_safe())]
pub const unsafe fn from_ptr<'a>(ptr: *const c_char) -> &'a CStr {
    // Implementation
}
```

#### Preconditions (`#[requires]`)

- ptr must not be null.
- ptr must point to a valid null-terminated C string, as guaranteed by `is_null_terminated` (`ptr`).

#### Postconditions (`#[ensures]`)

- The returned reference to a `CStr` (`&CStr`) satisfies the safety invariant, ensuring it is a valid, null-terminated C string with no interior null bytes.

#### Verification Harness

```rust
#[kani::proof_for_contract(CStr::from_ptr)]
#[kani::unwind(33)]
fn check_from_ptr_contract() {
    const MAX_SIZE: usize = 32;
    let string: [u8; MAX_SIZE] = kani::any();
    let ptr = string.as_ptr() as *const c_char;

    // Given the precondition is_null_terminated(ptr), Kani will attempt to verify
    // that from_ptr is safe under these assumptions. 
    unsafe { CStr::from_ptr(ptr); }
}
```

The harness has a similar structure as the `strlen` harness:

- It generates an arbitrary array of length `MAX_SIZE` and treats it as a potential C string.
- By relying on the precondition `is_null_terminated` (`ptr`), Kani explores paths where `ptr` is a valid null-terminated string.
- Under these conditions, `from_ptr` must produce a `CStr` that satisfies the safety invariant.

This ensures that as long as users provide a null-terminated string in a valid memory region, `from_ptr` will yield a safe `CStr`.

## Challenges Encountered & Lessons Learned

Lastly, we summarized the main challenges we encountered throughout the course and our reflections.

### Input Generation

One of the main challenges was generating appropriate inputs for verification. Initially, we considered generating specific test cases, but formal verification requires exploring all possible inputs within the specified bounds.

We utilized `kani::any_slice_of_array` and `kani::any_where` to generate arbitrary inputs while enforcing preconditions. This approach allowed us to cover a wide range of input scenarios, ensuring thorough verification.

### Unbounded Proofs and Loop Unwinding

Another challenge was dealing with unbounded loops in functions like `strlen`. Without setting an unwinding bound, Kani would run indefinitely. We addressed this by using `#[kani::unwind(N)]` to specify loop bounds, enabling Kani to perform bounded verification effectively.

### Verifying Unsafe Code

Verifying unsafe functions required precise specification of preconditions and postconditions. We needed to ensure that our contracts accurately captured the requirements for safe usage. This involved careful analysis of pointer accessibility, null termination, and memory safety.

### Balancing Verification Depth and Performance

Setting appropriate unwinding bounds was crucial to balance the depth of verification and performance. Larger bounds increase verification time, so we needed to choose values that provided sufficient coverage without excessive resource consumption.

## Conclusion

Through this project, we successfully verified that the safe and unsafe methods of Rust's `CStr` type uphold the safety invariant and prevent undefined behavior when used correctly. By leveraging formal verification with Kani, we ensured that these fundamental abstractions in Rust's standard library are reliable and robust.

This effort highlights the importance of formal methods in verifying low-level code, especially when dealing with unsafe operations and foreign function interfaces. By providing precise contracts and thorough verification harnesses, we contribute to Rust's mission of safety and reliability.

## References

[1] [Safety Invariant](https://rust-lang.github.io/unsafe-code-guidelines/glossary.html#validity-and-safety-invariant)

[2] [Challenge 13: Safety of CStr](https://github.com/model-checking/verify-rust-std/issues/150)

[3] [Loop Unwinding](https://model-checking.github.io/kani/tutorial-loop-unwinding.html)
