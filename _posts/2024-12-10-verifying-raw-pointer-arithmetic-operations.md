---
title: Verifying Raw Pointer Arithmetic Operations
layout: post
---
Authors: [Surya Togaru](https://github.com/stogaru), [Yifei Wang](https://github.com/xsxszab), [Szu-Yu Lee](https://github.com/szlee118), [Mayuresh Joshi](https://github.com/MayureshJoshi25)

## Introduction

Rust is famous for its strong memory safety features and that has made it popular for building reliable and secure systems like operating systems. However, Rust also permits the use of unsafe code block for tasks like pointer arithmetic operations which is useful but it can bypass Rust’s safety checks and lead to security issues or bugs.

Our challenge focused on verifying pointer arithmetic in Rust. By this, we ensured that even unsafe code is used correctly which helps prevent vulnerabilities and make Rust applications more reliable and secure.

#### Problem statement:
AWS is working to ensure the safety of Rust’s unsafe constructs using formal verification and automated reasoning. The problem statement we selected for our team was to verify the safety of standard library code that handles pointer arithmetic operations using the Kani verifier (a formal verification tool). By this, we aimed to strengthen trust in Rust’s safety guarantees in large-scale, safety-critical systems. 

#### What is pointer arithmetic?
Pointer arithmetic operations include addition, subtraction and offset which deal with raw pointer manipulation and accessing specific memory locations.
Pointer arithmetic is commonly used in applications that require precise control over memory such as operating systems, embedded systems and performance critical systems. If these operations are implemented incorrectly, they can cause serious harm and issues such as out-of-bounds memory access and data corruption/crashes.

#### What has our team has done?
Our team utilized Kani, a formal verification tool to check the safety of raw pointer arithmetic in Rust. Our achievements are:
-	We implemented and verification function contracts for 16 pointer operations, such as add(), sub(), and offset().
-	We validated these contracts using Kani proofs across five different pointee types: integers, slices, unit, composite and dynamic traits.
Further details are discussed further in the blog.


## Challenge Overview

The [challenge](https://model-checking.github.io/verify-rust-std/challenges/0003-pointer-arithmentic.html) focuses on formally verifying raw pointer arithmetic functions in Rust's standard library. It is structured into two parts:

1. Safety of pointer arithmetic functions: All unsafe functions provided in the challenge (e.g., `offset`, `byte_add`, `offset_from`, etc.) must be annotated with safety contracts, which must then be formally verified.
    * The verification must be done for the following pointee types:
        * All integers types
        * At least one `dyn Trait`
        * At least one slice
        * For unit type
        * At least one composite type with multiple non-ZST fields.
2. Safety of usages: Few functions that utilize raw pointer arithmetic methods in their implementation must be proven safe.

Any proofs written for these functions must ensure the absence of the following [undefined behaviors](https://github.com/rust-lang/reference/blob/142b2ed77d33f37a9973772bd95e6144ed9dce43/src/behavior-considered-undefined.md):
* Accessing dangling or misaligned pointers
* Invoking undefined behavior via compiler intrinsics
* Producing an invalid value, even in private fields and locals.
* Performing a place projection that violates the requirements of in-bounds pointer arithmetic.

## Implementation

### Approach
The implementation addressed the two parts of the challenge as follows:

1. **Verification of Pointer Arithmetic Functions**: Firstly, we identified `offset` and `offset_from` as foundational to other pointer arithmetic functions, as these two operations form the basis of many related functionalities. Then, we focused on formally verifying the raw pointer arithmetic functions (offset, offset_from, etc.) by specifying and verifying their safety contracts. These contracts captured preconditions and postconditions to prevent undefined behavior. Harnesses were written to verify the safety contracts. These harnesses were designed to handle five distinct pointee types, as per the challenge specifications.

2. **Verification of Usages**: The goal was to ensure that the contracts for these methods were sufficient and that the usage of pointer arithmetic in other functions adhered to the defined safety guarantees. Documentation and analysis of function behavior were essential in defining input space and verifying that the functions operated safely across all expected inputs.

### Function Analysis

The analysis began with a thorough review of the functions listed for verification. This included, examining the implmentation of these functions, studying the official Rust [documentation](https://doc.rust-lang.org/std/primitive.pointer.html) and understanding their safety requirements. This helped identify potential sources of undefined behavior, understand their intended usage. These insights were critical in defining accurate safety contracts. 

Among the given functions, two key functions—`offset` and `offset_from`—stood out as foundational due to their role in enabling other operations. 
* [`offset(self, count: isize) -> *const T`](https://doc.rust-lang.org/std/primitive.pointer.html#method.offset): Adds a signed offset to a pointer. The offset is specified by the argument `count` which is specified in units of `T`; e.g., a count of 3 represents a pointer offset of `3 * size_of::<T>()` bytes.
* [`offset_from(self, origin: *const T) -> isize`](https://doc.rust-lang.org/std/primitive.pointer.html#method.offset_from): Calculates the distance between two pointers. The returned value is in units of T: the distance in bytes divided by `mem::size_of::<T>()`.

Functions like `add` and `byte_offset_from` rely heavily on these operations. For instance:
* `add` internally calls `offset` to increment a pointer by a certain offset.
* `byte_offset_from` casts pointers to `u8` before invoking `offset_from`.

By focusing on the safety of offset and offset_from, the verification effort concentrated on the fundamental components, providing a strong base for related functions. This approach made it easier to define and extend contracts and proofs to dependent functions.

### Funtion Contracts

The preconditions and postconditions for the functions were primarily derived from the safety requirements outlined in the official Rust [documentation](https://doc.rust-lang.org/std/primitive.pointer.html#method.offset). For example, the safety requirements stated in teh documentation for the `offset` function are as follows:
1. The offset in bytes, `count * size_of::<T>()`, computed on mathematical integers (without “wrapping around”), must fit in an `isize`.
2. If the computed offset is non-zero, then `self` must be derived from a pointer to some allocated object, and the entire memory range between `self` and the `result` must be in bounds of that allocated object. In particular, this range must not “wrap around” the edge of the address space.

#### Preconditions
The above safety requirements lead to the following preconditions:
1. If T is a zero-sized type, i.e., `size_of::<T>() == 0`, then the computed offset (`count * size_of::<T>()`) will always be 0. Hence, both the safety checks will be satisfied and no other validations are required.
2. Else for non-zero-sized types,
    1. the product of `count` and `size_of::<T>()` must not overflow `isize` (Safety Requirement #1).
    2. adding the computed offset (`count * size_of::<T>()`) to the original pointer (`self`) must not cause overflow (Safety Requirement #1).
    3. Both the original pointer (self) and the result of self.wrapping_offset(count) must point to the same allocated object (Safety Requirement #2). To support reasoning about provenance of two pointers, the `same_allocation` API was introduced in Kani. This is discussed in detail in the [Challenges](#challenges) 

Translating these into code and stating them as preconditions using the `#[requires]` attribute gives us:

```rust
#[requires(
    // Precondition 1
    (core::mem::size_of::<T>() == 0) ||
    // Precondition 2.1
    (count.checked_mul(core::mem::size_of::<T>() as isize)
        // Precondition 2.2
        .map_or(false, |computed_offset| (self as isize).checked_add(computed_offset).is_some()) &&
        // Precondition 2.3
        core::ub_checks::same_allocation(self, self.wrapping_offset(count)))
)]
```

#### Postconditions

Based on the safety requirements and the function working, the follwoing postconditions can be specified:
1. If the computed offset is 0, the resulting pointer will point to the same address as the original pointer (`self`).
2. Otherwise, the resulting pointer will point to an address within the bounds of the allocated object from which the original pointer (`self`) was derived.

Translating these into code and stating them as postconditions using the `#[ensures]` attribute gives us:

```rust
#[ensures(|result|
    // Postcondition 1
    (self.addr() == (*result).addr()) ||
    // Postcondition 2
    core::ub_checks::same_allocation(self, *result as *const T)
)]
```

These preconditions and postconditions align with the safety requirements specified above. Writing contracts for `offset` first helped us a lay a foundation for verifying other pointer arithmetic functions such as `add`, `sub` and so on.

### Harnesses



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


#### **`String::remove`**: Removing characters from a `String`

The `String::remove` method removes a character at a specified index in a string and shifts the remaining characters to fill the gap. The Kani proof verifies:
- The string's length decreases by one after the removal.
- The removed character is a valid ASCII character.
- The removed character matches the character at the specified index in the original string.

#### **`Vec::swap_remove`**: Efficiently removing and replacing elements in a vector

The `Vec::swap_remove` method removes an element at a specified index and replaces it with the last element in the vector. The Kani proof ensures:
- The vector's length decreases by one after the operation.
- The removed element matches the original element at the specified index.
- If the removed index is not the last, the index now contains the last element of the original vector.
- All other elements remain unaffected.

#### **`VecDeque::swap`**: Swapping elements in a double-ended queue

The `VecDeque::swap` method swaps two elements at specified indices in a `VecDeque`. The Kani proof verifies:
- The elements at the specified indices are swapped correctly.
- All other elements in the `VecDeque` remain unchanged.


#### Summary of Usage Proofs

These proofs ensure the following:
- For `String::remove`, the operation adheres to ASCII validity, proper index bounds, and string length constraints.
- For `Vec::swap_remove`, the vector maintains integrity during element removals and replacements.
- For `Option::as_slice`, the resulting slice is valid and matches the contained data.
- For `VecDeque::swap`, swapped and unaffected elements are verified for correctness.

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
