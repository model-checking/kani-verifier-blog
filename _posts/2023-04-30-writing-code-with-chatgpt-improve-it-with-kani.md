---
layout: post
title: "Writing Code with ChatGPT? Improve it with Kani."
---

Kani is a verification tool that can help you prove properties about your Rust code.
To learn more about Kani, check out [the Kani tutorial](https://model-checking.github.io/kani/kani-tutorial.html) and our [previous blog posts](https://model-checking.github.io/kani-verifier-blog/).


Recently, [ChatGPT](https://openai.com/blog/chatgpt)---OpenAI’s AI chatbot built on top of Large Language Models (LLMs)---has taken the world by storm.
People are using ChatGPT to write blog posts, do homework, and even write code!
That’s right: LLMs like ChatGPT can be used to write code, since code is essentially just another kind of text.
All you need to do is provide a text prompt describing the program you want, and it will generate the code for you, along with an explanation of what it does.

We were also eager to explore the possibilities of using LLMs for daily coding tasks, so we decided to put ChatGPT to the test.
In this blog post, we'll share our experiences with using ChatGPT and Kani to solve example coding problems, and explore how these technologies could revolutionize the way we approach software development.
The experiments we did include the following three tasks:
1. Writing a prompt and generate *unverified* code with ChatGPT.
2. Checking the generated code with Kani to see if it's correct.
3. Using both ChatGPT and Kani to generate verified code.


Our experiments showed that, while ChatGPT is easy to use and can efficiently generate code from text description, the generated code is often unsound.
This is where verification tools like Kani can help detect bugs, corner cases and unexpected behavior in the generated code, thereby helping users of ChatGPT write more proven code.

## Code Generation using ChatGPT
We demonstrate the three tasks with two examples.
Let's start our first task: can we write code using a prompt with ChatGPT?

#### Example 1.a
The first example is a toy problem of writing a Rust function to compute the average of two integers.
So the prompt is also very simple and straightforward.

```
Q: Can you write me a Rust function that computes the integer average of two integers?
```

Giving the above prompt, ChatGPT answered us with the following function

```rust
fn integer_average(a: i32, b: i32) -> i32 {
    (a + b) / 2
}
```

, an explanation
>In this function, we define a function called integer_average that takes two integer arguments a and b.
The function then adds the two arguments together and divides the result by 2 to compute the integer average.

, and even a driver function to call the average function.

```rust
fn main() {
    let a = 4;
    let b = 8;
    let result = integer_average(a, b);
    println!("The average of {} and {} is {}", a, b, result);
}
```

#### Example 2.a
The second example we tried is more like a real-world coding task.
First, we wrote a Rust function that computes the lowest unset bit in a `u32` integer.
Our implementation uses a loop to iterate through all 32 bits in the input.
And we know that this could be slower than using some [bit twiddling hacks](https://graphics.stanford.edu/~seander/bithacks.html).
In this case, our goal is to optimize the function with ChatGPT.
This is the prompt we used, which includes the implementation we wrote:

``` 
Q: Optimize this Rust function:
fn lowest_unset_bit(x: u32) -> Option<u8> {
    let mut mask = 1;
    for i in 0..32 {
        if x & mask == 0 {
            return Some(i);
        }
        mask <<= 1;
    }
    None
} 
```

After a few seconds, ChatGPT gave us a solution

``` rust
fn lowest_unset_bit(x: u32) -> Option<u8> {
    if x == std::u32::MAX{
        return None;
    }
    let y = x | (x + 1);
    let z = y ^ (y + 1);
    Some((z.trailing_zeros() % 32) as u8)
}
```

along with an explanation.

From these two examples, ChatGPT's code generation capabilities are thoroughly impressive.
Not only does it produce code that looks good at first glance, but it also provides explanations that give us greater confidence that the code is doing exactly what we intended it to do.
In fact, we can even request ChatGPT to generate a driver function and some test cases using follow-up prompts to further test the generated code.
However, as verification folks, we know that we still can't be completely sure that the code is correct without **verification**.


## Verification of Generated Code
So, naturally, our next task is: can we verify the generated programs with Kani?

#### Example 1.b
Continuing from Example 1.a.
We can simply transform the driver function into a harness by substituting the test cases with `kani::any()`.

``` rust
fn integer_average(a: i32, b: i32) -> i32 {
    (a + b) / 2     // <------ line 2
}

#[kani::proof]
fn main() {
    let a = kani::any();
    let b = kani::any();
    let result = integer_average(a, b);
    println!("The average of {} and {} is {}", a, b, result);
}
```

This harness verifies that, for any `i32` integers `a` and `b`, the function `integer_average` does not have any bug that [Kani can spot](https://model-checking.github.io/kani/tutorial-kinds-of-failure.html).

We ran Kani on the above program

```console
foo@bar:~$ kani integer_average.rs
```

and got the verification result

```console
...
SUMMARY:
 ** 1 of 4 failed
Failed Checks: attempt to add with overflow
 File: "...", line 2, in integer_average

VERIFICATION:- FAILED
Verification Time: 0.6991158s
```

The code is actually buggy! 
Although the average of two `i32` integers is in the range of `i32`, the intermediate sum `a + b` may overflow.
A counterexample is when `a` equals `i32::MAX` and `b` equals any positive integer, the sum of them will be greater than `i32::MAX`, and hence the overflow.

#### Example 2.b
Demonstrating that one program is an optimization of another requires proving two things: that the programs are equivalent and that the optimized version performs better.
Although proving the performance improvement can be challenging, we can at least verify the equivalence of the two implementations using Kani. 
We put the implementation we wrote and the implementation ChatGPT generated together and wrote a harness function for checking the equivalence of the implementation of `lowest_unset_bit` we provided and the implementation ChatGPT generated.
In the harness function, we let the input `x` be any `u32` integer, run both implementations on `x`, and check that the outputs return by them are the same.

``` rust
// Original implementation.
fn lowest_unset_bit_ori(x: u32) -> Option<u8> {
    let mut mask = 1;
    for i in 0..32 {
        if x & mask == 0 {
            return Some(i);
        }
        mask <<= 1;
    }
    None
} 
// Optimized implementation generated by ChatGPT.
fn lowest_unset_bit_opt(x: u32) -> Option<u8> {
    if x == std::u32::MAX{
        return None;
    }
    let y = x | (x + 1);        // <------ line 18 
    let z = y ^ (y + 1);
    Some((z.trailing_zeros() % 32) as u8)
} 

#[kani::proof]
fn check() {
    let x: u32 = kani::any();
    assert_eq!(lowest_unset_bit_ori(x), lowest_unset_bit_opt(x));   // <------ line 26
}
```

Running Kani on the program with the command

```
> kani lowest_unset_bit.rs
```

gave us the verification result

```
...
SUMMARY:
 ** 2 of 70 failed
Failed Checks: attempt to add with overflow
 File: "...", line 18, in lowest_unset_bit_opt
Failed Checks: assertion failed: lowest_unset_bit_ori(x) == lowest_unset_bit_opt(x)
 File: "...", line 26, in check

VERIFICATION:- FAILED
Verification Time: 0.84979576s
```

The generated implementation is incorrect!
There were two failed checks.
The first one `Failed Checks: attempt to add with overflow` says that the addition `x + 1` may overflow.
The other one says that equivalent check may fail---the two implementations are actually not equivalent.


To better understand the bug, we asked Kani to produce a counterexample with the `--concrete-playback` option (discussed in [our previous post](https://model-checking.github.io/kani-verifier-blog/2022/09/22/internship-projects-2022-concrete-playback.html))

```
> cargo kani --enable-unstable --concrete-playback=print | grep "//" | awk '{print $2}'
2147483647
```

The counterexample is when `x` equals `2147483647` (`i32::MAX`).


The examples above illustrate that, although code generation is efficient and accessible, it's crucial to exercise caution and avoid blindly trusting the generated code, as it may contain errors.
We believe there are two factors that contribute to this unreliability.
Firstly, the training corpus for most LLMs is unverified code.
Secondly, text prompts can be ambiguous, leading to the production of flawed code.
Fortunately, program verifiers such as Kani can provide valuable information about generated code, such as verification results, and counterexamples.
Armed with this information, developers can locate and fix bugs more effectively.
But what about the potential for language models like ChatGPT to leverage such insights to improve code generation accuracy?
It's an intriguing question that merits further exploration.




## Code Generation with Verifiers in the Loop
The last task we explore in this blog is: can we combine Kani and ChatGPT to generate correct and verified code?

#### Example 1.c
Continuing from Example 1.b.
Recall that we found the overflow error in the expression `a + b` in the generated code with Kani.
We shared this information with ChatGPT.

```
Q: The expression (a + b) / 2 may overflow.
```

ChatGPT agreed with us and fixed the overflow with a new implementation using `checked_add`:

``` rust
fn integer_average(num1: i32, num2: i32) -> i32 {
    match num1.checked_add(num2) {
        Some(sum) => sum / 2,
        None => {
            // Handle overflow gracefully
            println!("Overflow occurred!");
            std::i32::MAX // Fallback value
        }
    }
}
```

We reran Kani on this new implementation.
Kani verified that this new version is correct!
However, the function is no longer complete because it doesn't computes the average for all `i32` integers as we specified.
For example, it does not compute the average for the input `integer_average(std::i32::MAX, 1)`.
So, we tried again with the following prompt to generate a complete version of `integer_average`.

```
Q: Can you give me a fix that does not throw any error?
```

This time, ChatGPT found us an implementation that accepts all `i32` integers as input.

```
fn integer_average(num1: i32, num2: i32) -> i32 {
    num1 / 2 + num2 / 2 + (num1 % 2 + num2 % 2) / 2
}
```

Kani verifies that this implementation is correct.

```
> kani integer_average.rs

...
SUMMARY:
 ** 0 of 6 failed

VERIFICATION:- SUCCESSFUL
Verification Time: 0.5309424s
```

#### Example 2.c
Recall that we got a counterexample `x = 2147483647` from Kani for the equivalence check of `lowest_unset_bit`.
We reported this counterexample to ChatGPT and asked for a fix.

```
Q: The optimized version does not produce the same value as the original for x = 2147483674.
```

It gave as a new optimization.

``` rust
fn lowest_unset_bit(x: u32) -> Option<u8> {
    if x == std::u32::MAX{
        return None;
    }
    Some((x ^ (x + 1)).trailing_zeros() as u8)
} 
```

We ran Kani to check if the new version is equivalent to the original implementation with the same harness function.
This time, there was only one failed check.

```
...
SUMMARY:
 ** 1 of 70 failed
Failed Checks: assertion failed: lowest_unset_bit_ori(x) == lowest_unset_bit_opt(x)
 File: "...", line 22, in check

VERIFICATION:- FAILED
Verification Time: 0.84979576s
```

The overflow has been fixed, but the equivalence failure persists. 
Similarly, we produced another counterexample `x = 4293918719` with Kani, reported it to ChatGPT, and got another optimization.

``` rust
fn lowest_unset_bit(x: u32) -> Option<u8> {
    if x == std::u32::MAX{
        return None;
    }
    let y = !x;
    Some(y.trailing_zeros() as u8)
} 
```

Kani successfully verified that this optimization is equivalent to the original implementation.

```
> kani lowest_unset_bit.rs

...
SUMMARY:
 ** 0 of 68 failed

VERIFICATION:- SUCCESSFUL
Verification Time: 5.308244s
```

The Kani proof saves us from spending a lot of time understanding the bit hack and convincing ourselves that the two implementations are equivalent.

## Summary

In this post, we showed how to generate programs with ChatGPT, how to verify generated code with Kani, and how to generate verified code with both ChatGPT and Kani.
With increasingly powerful code generation capabilities, software development is becoming more automated and accessible.
However, as developers spend less time on implementation details, corner cases, and safety issues, their code becomes more susceptible to errors.
For this reason, specifications may become more critical than ever, serving as the new ground truth in cases where developers no longer write code line by line.
We believe program verifiers like Kani will play a critical role in ensuring the correctness of such code, revealing potential bugs, and helping developers fix them.
