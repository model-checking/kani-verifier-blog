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

This post details our approach, highlights the implementation process, and discusses the challenges encountered while ensuring the safety of pointer arithmetic in Rust.

## Challenge Overview

The [challenge](https://model-checking.github.io/verify-rust-std/challenges/0003-pointer-arithmentic.html) focuses on formally verifying raw pointer arithmetic functions in Rust's standard library. It is structured into two parts:

1. Safety of pointer arithmetic functions: All unsafe functions provided in the challenge (e.g., `offset`, `byte_add`, `offset_from`, etc.) must be annotated with safety contracts, which must be formally verified.
    * The verification must be done for the following pointee types:
        * All integer types
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

The analysis began with a thorough review of the functions listed for verification. This involved examining their implementation, studying the official Rust documentation, and understanding their safety requirements. This process was instrumental in identifying potential sources of undefined behavior and clarifying their intended usage. These insights were critical for defining precise and robust safety contracts.

Among the functions analyzed, two stood out as foundational—offset and offset_from—due to their central role in enabling other pointer operations: 
* [`offset(self, count: isize) -> *const T`](https://doc.rust-lang.org/std/primitive.pointer.html#method.offset): Adds a signed offset to a pointer. The offset is specified by the argument `count` expressed in units of `T`; e.g., a count of 3 represents a pointer offset of `3 * size_of::<T>()` bytes.
* [`offset_from(self, origin: *const T) -> isize`](https://doc.rust-lang.org/std/primitive.pointer.html#method.offset_from): Calculates the distance between two pointers. The returned value is in units of T: the distance in bytes divided by `mem::size_of::<T>()`.

Functions like `add` and `byte_offset_from` heavily rely on these operations. For instance:
* `add` internally calls `offset` to increment a pointer by a certain offset.
* `byte_offset_from` casts pointers to `u8` before invoking `offset_from`.

By initially focusing on the safety of `offset` and `offset_from`, the verification effort focused on the fundamental components that underpin many related functions. This approach made it easier to define and extend contracts and proofs to dependent functions.

### Function Contracts

The preconditions and postconditions for the functions were primarily derived from the safety requirements outlined in the official Rust [documentation](https://doc.rust-lang.org/std/primitive.pointer.html#method.offset). For example, the safety requirements stated in the documentation for the `offset` function are as follows:
1. The offset in bytes, `count * size_of::<T>()`, computed on mathematical integers (without “wrapping around”), must fit in an `isize`.
2. If the computed offset is non-zero, then `self` must be derived from a pointer to some allocated object, and the entire memory range between `self` and the `result` must be in bounds of that allocated object. In particular, this range must not “wrap around” the edge of the address space.

#### Preconditions
The above safety requirements lead to the following preconditions:
1. If T is a zero-sized type, i.e., `size_of::<T>() == 0`, then the computed offset (`count * size_of::<T>()`) will always be 0. Thus, both safety checks are inherently satisfied, and no additional validations are required.
2. For non-zero-sized types,
    1. The product of `count` and `size_of::<T>()` must not overflow `isize` (Safety Requirement #1).
    2. Adding the computed offset (`count * size_of::<T>()`) to the original pointer (`self`) must not cause overflow (Safety Requirement #1).
    3. Both the original pointer (self) and the result of self.wrapping_offset(count) must point to the same allocated object (Safety Requirement #2). To support reasoning about provenance of two pointers, the `same_allocation` API was introduced in Kani. This is discussed in detail in the [Challenges](#challenges) 

These preconditions can be translated into code using the `#[requires]` attribute as follows: 

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

Based on the safety requirements and the function behavior, the following postconditions can be specified:
1. If the computed offset is 0, the resulting pointer will point to the same address as the original pointer (`self`).
2. Otherwise, the resulting pointer will point to an address within the bounds of the allocated object from which the original pointer (`self`) was derived.

These postconditions can be translated into code using the `#[ensures]` attribute as follows:

```rust
#[ensures(|result|
    // Postcondition 1
    (self.addr() == (*result).addr()) ||
    // Postcondition 2
    core::ub_checks::same_allocation(self, *result as *const T)
)]
```

These preconditions and postconditions align with the safety requirements specified above. Writing contracts for `offset` first helped us lay a foundation for verifying other pointer arithmetic functions such as `add`, `sub`, and others.

### Harnesses

Harnesses were written to validate the function contracts for various pointee types. Kani uses these harnesses to formally verify the contracts against diverse test cases, ensuring their correctness and robustness.

Each harness is designed to test the contracts of a specific function. To achieve this, they follow two primary steps:
1. **Generate the input arguments non-deterministically**: The inputs are created to represent various valid and edge-case scenarios without explicitly hardcoding them.
2. **Invoke the function with these arguments**: The function under test is called using the generated inputs, allowing Kani to evaluate whether the preconditions and postconditions hold for all possible inputs.

#### Example Proof for the `offset` Function

```rust
#[kani::proof_for_contract(<*const u8>::offset)]
pub fn check_const_add_i8() {
    // 200 bytes are large enough to cover all pointee types used for testing
    const BUF_SIZE: usize = 200;
    let mut generator = kani::PointerGenerator::<BUF_SIZE>::new();
    let test_ptr: *const u8 = generator.any_in_bounds().ptr;
    let count: isize = kani::any();
    unsafe {
        test_ptr.offset(count);
    }
}
```

This harness validates the `offset` function for pointers of type `*const u8`. It ensures that the function adheres to the safety contracts defined (as given in the previous section). The `<*const T>::offset` function accepts two arguments: a pointer (`*const T`) and an offset (`isize`). The proof generates these non-deterministically as follows:
* The `count` variable, of type `isize`, has an `Arbitrary` trait implemented, enabling the generation of non-deterministic values using `kani::any()`.
* `kani::PointerGenerator` is used to create a pointer `test_ptr`, guaranteed to lie within the bounds of the allocated buffer.

The `offset` function is called in an unsafe block with the generated `test_ptr` and `count`.

PointerGenerator can also create pointers with different allocation statuses, such as out-of-bounds, dangling, or null pointers. This was particularly useful in writing harnesses for `offset_from`, which require testing pointers with varied allocation statuses (see [here](https://github.com/model-checking/verify-rust-std/blob/main/library/core/src/ptr/const_ptr.rs)). 

However, the `PointerGenerator` API only supports generating pointers whose pointee types implement the `Arbitrary` trait. In other words, any `*const T` can be generated as long as `T` has the Arbitrary trait implemented and the generator is wide enough for `T`. Pointers with integer (`*const u32`) or tuple (`*const (u16, bool)`) pointee types can be generated but not slice (`*const [T]`) or dyn Trait pointee types. To test slice pointers, one can generate a non-deterministic slice from an array and derive a pointer from it, as shown below:

```rust
let arr: [u32; 8] = kani::Arbitrary::any_array();
let slice: &[u32] = kani::slice::any_slice_of_array(&arr);
let ptr: *const [u32] = slice;
```

Currently, an Arbitrary trait hasn't been implemented for pointers that could support non-deterministic generation of pointers covering the entire address space and different allocation statuses. An [issue](https://github.com/model-checking/kani/issues/3696) has been created to track this. 
 
#### Panicking Proofs

Sometimes, negative verification is necessary. The (`#[kani::should_panic]` attribute)[https://model-checking.github.io/kani/reference/attributes.html#kanishould_panic] can be used to specify that a proof harness is expected to panic.

For instance:

```rust
// Proof for unit size will panic as offset_from needs the pointee size to be greater than 0
 #[kani::proof_for_contract(<*const ()>::offset_from)]
 #[kani::should_panic]
 pub fn check_const_offset_from_unit() {
     let val: () = ();
     let src_ptr: *const () = &val;
     let dest_ptr: *const () = &val;
     unsafe {
         dest_ptr.offset_from(src_ptr);
     }
 }
```

The `offset_from` function being verified in this harness [panics](https://doc.rust-lang.org/std/primitive.pointer.html#panics) if the pointee is ZST. Since unit type `()` is a ZST, the harness is expected to panic. The `#[kani::should_panic]` attribute ensures this behavior is correctly tested.

### Verifying Usages

#### **`Vec::swap_remove`**

The `Vec::swap_remove` method removes an element at a specified index and replaces it with the last element in the vector. The Kani proof ensures:
- The vector's length decreases by one after the operation.
- The removed element matches the original element at the specified index.
- If the removed index is not the last, the index now contains the last element of the original vector.
- All other elements remain unaffected.

#### **`VecDeque::swap`**

The `VecDeque::swap` method swaps two elements at specified indices in a `VecDeque`. The Kani proof verifies:
- The elements at the specified indices are swapped correctly.
- All other elements in the `VecDeque` remain unchanged.

#### Summary of Usage Proofs

These proofs ensure the following:
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
