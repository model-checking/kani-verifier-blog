---
title: Verifying Raw Pointer Arithmetic Operations
layout: post
---
Authors: [Surya Togaru](https://github.com/stogaru), [Yifei Wang](https://github.com/xsxszab), [Szu-Yu Lee](https://github.com/szlee118)

## Introduction

In system-level programming ensuring memory safety when working with low-level constructs like pointers is critical. Undsafe operations like offset and offset_from in the Rust Standard Library are foundational for pointer arithmetic, but bugs in them can lead to undefined behavior, compromising program safety.

In this challenge, we focused on formally verifying the safety of these functions. We createdn of robust function contracts to capture preconditions and postconditions, and leveraged Kani to write proofs for different pointee types. This post details our approach, highlights the implementation process, and discusses the challenges encountered while ensuring the safety of pointer arithmetic in Rust.

## Challenge Overview

The [challenge](https://model-checking.github.io/verify-rust-std/challenges/0003-pointer-arithmentic.html) focuses on formally verifying raw pointer arithmetic functions in Rust's standard library. It is structured into two parts:

1. Safety of pointer arithmetic functions: All the unsafe functions given in the challenge (for example, `offset`, `byte_add`, `offset_from`, etc.) must be annotated with safety contracts and the contracts must be verified.
    * Additionally, verification must be done for the following pointee types:
        * All integers types
        * At least one `dyn Trait`
        * At least one slice
        * For unit type
        * At least one composite type with multiple non-ZST fields.
2. Safety of usages: Functions using the raw pointer arithmetic operations in their implementations must be proved to be safe.

Proofs written for any of the above methods must ensure the absence of the following [undefined behaviors](https://github.com/rust-lang/reference/blob/142b2ed77d33f37a9973772bd95e6144ed9dce43/src/behavior-considered-undefined.md):
* Accessing dangling or misaligned pointers
* Invoking undefined behavior via compiler intrinsics
* Producing an invalid value, even in private fields and locals.
* Performing a place projection that violates the requirements of in-bounds pointer arithmetic.

## Approach



## Implementation

### 1. Placeholder


### 2. Pointee Types

In our implementation, we cover a variety of pointee types to ensure robust verification:

- **Integer Types**: Includes `i8`, `i16`, `i32`, `i64`, `u8`, `u16`, `u32`, `u64`, and others. These fundamental types are frequently used in pointer arithmetic.
   - Integer types are common in pointer arithmetic and cover both signed and unsigned values.

   - **Example**: Verification for `offset` on `i32`:
    ```rust
    generate_arithmetic_harnesses!(
        i32,
        check_const_add_i32,
        check_const_sub_i32,
        check_const_offset_i32
    );
    ```
    
- **Slices**: Slices allow pointer operations over contiguous memory blocks.
    - **Example**: Verification for `offset` on a slice of `i32`:
    ```rust
    generate_slice_harnesses!(
        i32,
        check_const_add_slice_i32,
        check_const_sub_slice_i32,
        check_const_offset_slice_i32
    );
    ```
- **Dynamic Traits (`dyn Trait`)**: Verification extends to trait objects, providing support for dynamic dispatch.
    - **Example**: Verification for `byte_offset` on `dyn TestTrait`:
    ```rust
    gen_const_byte_arith_harness_for_dyn!(byte_offset, check_const_byte_offset_dyn);
    ```

By including these types, we address diverse use cases and scenarios in Rust's ecosystem.


#### Macros for Automation


### 3. Usage Scenarios

---

#### **`String::remove`**: Removing characters from a `String`

The `String::remove` method removes a character at a specified index in a string and shifts the remaining characters to fill the gap. The Kani proof verifies:
- The string's length decreases by one after the removal.
- The removed character is a valid ASCII character.
- The removed character matches the character at the specified index in the original string.

---

#### **`Vec::swap_remove`**: Efficiently removing and replacing elements in a vector

The `Vec::swap_remove` method removes an element at a specified index and replaces it with the last element in the vector. The Kani proof ensures:
- The vector's length decreases by one after the operation.
- The removed element matches the original element at the specified index.
- If the removed index is not the last, the index now contains the last element of the original vector.
- All other elements remain unaffected.

---

#### **`Option::as_slice`**: Converting an `Option` into a slice

The `Option::as_slice` method converts an `Option` containing a collection into a slice. The proof would validate:
- The result is a valid slice if the `Option` contains a value.
- The length of the resulting slice matches the length of the contained collection.

---

#### **`VecDeque::swap`**: Swapping elements in a double-ended queue

The `VecDeque::swap` method swaps two elements at specified indices in a `VecDeque`. The Kani proof verifies:
- The elements at the specified indices are swapped correctly.
- All other elements in the `VecDeque` remain unchanged.

---

#### Summary of Usage Proofs

These proofs ensure the following:
- For `String::remove`, the operation adheres to ASCII validity, proper index bounds, and string length constraints.
- For `Vec::swap_remove`, the vector maintains integrity during element removals and replacements.
- For `Option::as_slice`, the resulting slice is valid and matches the contained data.
- For `VecDeque::swap`, swapped and unaffected elements are verified for correctness.

These examples demonstrate how Kani ensures safety and correctness in common Rust operations.


## Challenges

Throughout the project, we faced several technical challenges related to Rust's specification, the Kani verifier's limitations, and the complex nature of pointer arithmetic operations. Below are some of the key challenges and how we addressed them or how the could be addressed in the future.

### 1. Ensuring Pointer Stays Within Allocation Bounds

#### Overview
One of the critical requirements when verifying Rust's pointer arithmetic operations is ensuring that the result of operations like `add`, `sub`, `offset`, and `offset_from` remains within the same memory allocation as the original pointer. This is essential for memory safety, as pointers crossing allocation boundaries can result in undefined behavior.

#### **Why This Problem Matters**
When pointer arithmetic crosses allocation boundaries, Rust’s guarantees about pointer provenance and memory safety no longer hold. This could allow pointers to access memory outside of their intended region, potentially leading to security vulnerabilities or crashes. Verifying that arithmetic stays within the same allocation is crucial for upholding Rust's safety guarantees.  

**Example Issue**:  
Consider the following simplified function that performs pointer arithmetic:  

```rust
unsafe fn add_offset<T>(ptr: *const T, count: usize) -> *const T {
    ptr.add(count)
}
```

Without explicit verification, there is no guarantee that the resulting pointer `ptr.add(count)` remains within the same allocation as `ptr`. Since `ptr` points to a heap-allocated memory, an unchecked `count` could result in a pointer out of bound.

#### **The Solution: `kani::mem::same_allocation`**

The **`kani::mem::same_allocation` API** was introduced to make it easier to ensure that pointer arithmetic stays within the same allocation. This API provides a simple and clear way to check if two pointers belong to the same memory allocation. It works with both **sized and unsized types** (e.g., slices, `dyn Trait`), an example usage is as follows:
```rust
kani::mem::same_allocation(ptr1, ptr2);
```
The introduction of `kani::mem::same_allocation` significantly simplified contract verification for pointer arithmetic functions. Instead of relying on custom assertions and manual tracking of allocation bounds, now we could use a clean and expressive way to define function contracts.

---

### 2. Determining the Necessity of Pointer Alignment in Function Contracts

#### Overview
When verifying pointer arithmetic functions like `add`, `sub`, `offset`, and `offset_from`, a key question arises:  
**Do the input and output pointers need to be aligned for these operations to be valid?**  

Initially, it seemed logical to require alignment checks in our function contracts. This assumption stemmed from Rust's strict alignment rules for dereferencing pointers. However, through our verification efforts, we discovered that **alignment is not a necessary requirement for pointer arithmetic itself**. This insight was unexpected, as it is not explicitly documented in Rust's documentation for [pointer operations](https://doc.rust-lang.org/std/primitive.pointer.html#method.offset). However, it significantly influenced how we structured our function contracts and defined preconditions.

#### Example
To illustrate this matter, consider the following example: 
```rust
let vec1 = vec![1, 2, 3];
let ptr: *const u8 = vec.as_ptr();
let ptr_unaligned = ptr.wrapping_byte_offset(1);
unsafe {ptr_unaligned.add(1);}
```
Here, `ptr_unaligned` is not aligned for type `u8`, but the operation `add` is valid since it doesn't dereference the pointer.

#### Impact on Verification
Once we realized that alignment checks were unnecessary, we refactored the function contracts by removing alignment checks from both preconditions and postconditions. It is now the caller's responsibility to ensure pointer alignment when dereferencing raw pointers.

---

### 3. Handling Function Contract Stubbing with Pointer Return Types 

#### Overview
One key insight of function contracts is their reusability. Once verified, they can stub (replace) the underlying function in other proofs, significantly reducing verification complexity. For a detailed explanation of how this works, refer to this [blog post](https://model-checking.github.io/kani-verifier-blog/2024/01/29/function-contracts.html).

However, Kani's current function contract stubbing mechanism cannot correctly handle functions that return pointers. The issue arises during the function replacement process, where Kani uses `kani::any()` to generate a random value representing the function's return value. Since Kani does not support generating random pointers (as the `Arbitrary` trait is not implemented for pointers), this leads to a compilation error.

#### Example Issue
When we attempt to stub a pointer-returning function, the following code fails to compile:

```rust
#[kani::proof_for_contract(<*mut T>::offset)]
fn offset_proof() {
    let test_ptr: *mut T = kani::any();
    unsafe { test_ptr.offset(1); }
}
```

Error message:

```bash
Error: the trait `Arbitrary` is not implemented for `*mut T`
```

**Solution**:
Currently, there is no clean workaround for this issue. The temporary solution is to avoid using Kani’s stubbing mechanism for functions with pointer return types. We raised this issue with the Kani development team, and they are tracking it for future support.
**Related Issue**: [Kani Issue #3732](https://github.com/model-checking/kani/issues/3732)
