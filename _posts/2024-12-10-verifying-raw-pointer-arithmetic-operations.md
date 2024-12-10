---
title: Verifying Raw Pointer Arithmetic Operations
layout: post
---
Authors: [Surya Togaru](https://github.com/stogaru), [Yifei Wang](https://github.com/xsxszab), [Szu-Yu Lee](https://github.com/szlee118), [Mayuresh Joshi](https://github.com/MayureshJoshi25)

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
