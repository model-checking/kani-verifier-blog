---
layout: post
title:  "Run and debug Rust verification harnesses from VS Code"
---

Kani is a verification tool that can help you systematically test properties about your Rust code.
To learn more about Kani, check out the [Kani tutorial](https://model-checking.github.io/kani/kani-tutorial.html) and our [previous blog posts](https://model-checking.github.io/kani-verifier-blog/).

We are delighted to introduce the [Kani VS Code Extension](https://marketplace.visualstudio.com/items?itemName=model-checking.kani-vscode-extension), which is now available on the VS Code marketplace.
To allow a more comfortable verification experience, Kani is now usable from the VS Code user interface.
The extension automatically detects all harnesses within the package, and allows you to run and debug them directly in VS Code.
Until now, developers could only run and debug harnesses via a command-line interface.

<img src="{{site.baseurl | prepend: site.url}}/assets/images/vs-code-images/kani-demo.gif" style="box-shadow: 0 2px 4px rgba(0, 0, 0, 0.5);" alt="view-kani-demo" />

## Introducing the Kani VS Code Extension

The [Kani VS Code extension](https://marketplace.visualstudio.com/items?itemName=model-checking.kani-vscode-extension) offers a hassle-free and seamless integration into Visual Studio Code, making it more convenient to write and debug harnesses.
As you write Kani harnesses, the extension detects them and conveniently displays them within your testing panel.
The extension offers detailed diagnostics, feedback about verification failures, error messages, and stack traces.
This empowers you to find bugs and verify their code quicker.
You can install the extension from the [webpage](https://marketplace.visualstudio.com/items?itemName=model-checking.kani-vscode-extension) on VS Code marketplace or by searching for `Kani` in the extensions tab of your VS Code window.

## A Simple Example

To show some of the features in the extension, we will work through a familiar example, the rectangle example that we introduced in our [first blog post](https://model-checking.github.io/kani-verifier-blog/2022/05/04/announcing-the-kani-rust-verifier-project.html).

```rust
#[derive(Debug, Copy, Clone)]
struct Rectangle {
    width: u64,
    height: u64,
}

impl Rectangle {
    fn can_hold(&self, other: &Rectangle) -> bool {
        self.width > other.width && self.height > other.height
    }

    fn stretch(&self, factor: u64) -> Option<Self> {
        let w = self.width.checked_mul(factor)?;
        let h = self.height.checked_mul(factor)?;
        Some(Rectangle { width: w, height: h })
    }
}
```

In order to verify properties about the rectangle, we wrote a verification harness.
The harness postulates that when the rectangle is stretched, it can hold another rectangle of its original size (dimensions).
If verified succesfully, this means that for any given stretch factor and any height and width of the original rectangle, this property holds true.

```rust
#[kani::proof]
pub fn stretched_rectangle_can_hold_original() {
    let original = Rectangle { width: kani::any(), height: kani::any() };
    let factor = kani::any();
    if let Some(larger) = original.stretch(factor) {
        assert!(larger.can_hold(&original));
    }
}
```

#### How Kani is used currently

The current way of interacting with Kani is through the command line.
Users invoke `cargo kani` and specify the harness they want to verify.
Kani produces text-based output that tells you whether your verification attempt has succeeded or failed.

```
$ cargo kani --harness stretched_rectangle_can_hold_original
# --snip--
Check 2: verification::stretched_rectangle_can_hold_original.assertion.1
         - Status: FAILURE
         - Description: "assertion failed: larger.can_hold(&original)"
         - Location: src/main.rs:36:13 in function verification::stretched_rectangle_can_hold_original
# --snip--
VERIFICATION:- FAILED
```

## Using the VS Code extension

With the extension, running Kani on a verification harness, is as simple as clicking a button.
In the following sections, we’ll walk you through using the extension’s core features to debug and finally verify the rectangle example mentioned above.

### View Kani harnesses

As soon as your Rust package is opened using the Kani extension in a VS Code instance, you should see the Kani harnesses loaded as regular unit tests in the Testing Panel on the [primary side bar](https://code.visualstudio.com/api/ux-guidelines/sidebars#primary-sidebar) of VS Code.
This is how the testing page looks like when you click on the panel.

<img src="{{site.baseurl | prepend: site.url}}/assets/images/vs-code-images/view-kani-harnesses.png" alt="view-kani-harnesses" />

### Run Kani harnesses

You can then run your harnesses using the tree view by clicking the play button beside the harness that was automatically picked up by the Kani Extension.
Once you run the harness using the extension, you are shown a green check mark if verification succeeded, or a failure banner if it failed.

In our example, as with the command line, we can see through visual markers such as the failure banner pop-up and the red failure marker, that verification failed.

You are then presented with two options:

1. [Generate the report for the harness](https://github.com/model-checking/kani-vscode-extension/blob/main/docs/user-guide.md#view-trace-report)
2. [Run concrete playback to generate unit tests](https://github.com/model-checking/kani-vscode-extension/blob/main/docs/user-guide.md#use-concrete-playback-to-debug-a-kani-harness).

<img src="{{site.baseurl | prepend: site.url}}/assets/images/vs-code-images/run-kani-harness.gif" style="box-shadow: 0 2px 4px rgba(0, 0, 0, 0.5);" alt="run-kani-harness" />

Kani's [concrete playback](https://model-checking.github.io/kani-verifier-blog/2022/09/22/internship-projects-2022-concrete-playback.html) feature allows you to generate unit tests that call a function with the exact arguments that caused the assertion violation.
The VSCode extension makes using concrete playback easy.
You can read more about concrete playback in our [documentation](https://model-checking.github.io/kani/debugging-verification-failures.html).

### Generate a counterexample unit test

Next, we’ll generate the unit test by clicking on the `Run Concrete Playback for stretched_rectangle_can_hold_original` link that appears through a blue link on the error banner.

<img src="{{site.baseurl | prepend: site.url}}/assets/images/vs-code-images/generate-counter-example.gif" style="box-shadow: 0 2px 4px rgba(0, 0, 0, 0.5);" alt="generate-unit-test" />

By simply clicking on a link, we have our counterexample unit test pasted directly below the harness.
This is what the unit test looks like:

```rust
#[test]
fn kani_concrete_playback_stretched_rectangle_can_hold_original() {
    let concrete_vals: Vec<Vec<u8>> = vec![
        // 4611686018427387904ul
        vec![0, 0, 0, 0, 0, 0, 0, 64],
        // 0ul
        vec![0, 0, 0, 0, 0, 0, 0, 0],
        // 2ul
        vec![2, 0, 0, 0, 0, 0, 0, 0],
    ];
    kani::concrete_playback_run(concrete_vals, stretched_rectangle_can_hold_original);
}
```

You can see in the GIF above that the source code is now annotated with two options on top of the generated unit test, `Run Test (Kani)` and `Debug Test (Kani)`, which allow you to run and debug the test just like any other Rust unit test.

### Run Kani-generated test

Running the unit test using the `Run Test (Kani)` button shows us what we were expecting -- that the unit test is failing.
This is because the unit test is using the counterexample to invoke the function `stretched_rectangle_can_hold_original`.

<img src="{{site.baseurl | prepend: site.url}}/assets/images/vs-code-images/run-concrete-playback-test.png" alt="run-concrete-playback-test" />

### Debug Kani unit test

In order to peek under the hood to find out the missing assumptions that lead to unexpected behavior, it is really important to look at the concrete counterexamples for which our assertions fail.
By setting breakpoints and clicking the `Debug Test (Kani)` button, you are taken into the debugger which allows you to inspect the specific values for which the assertion fails.

<img src="{{site.baseurl | prepend: site.url}}/assets/images/vs-code-images/run-debugger.gif" style="box-shadow: 0 2px 4px rgba(0, 0, 0, 0.5);" alt="run-debugger" />

In our case, we can see that for `original.height = 0` , the larger rectangle’s height or `larger.height` also stays 0, which shows that for that counterexample, the property `can_hold` does not hold.

### And finally, verify the harness with the right assumptions

Now that we know that for `original.width = 0`, our assertion fails, we can repeat the experiment with explicit assumptions.
The experiments should reveal that for all parameters, having a `0` value will cause the assertion to fail.
Additionally, there is a problem if `factor` is `1` because in this case `stretch` will return `Some(...)`, but the stretched rectangle will be the same size as the original.
We missed these cases in our unit and property-based tests.

We will now add these assumptions through `kani::assume` and re-run the verification in the extension.

<img src="{{site.baseurl | prepend: site.url}}/assets/images/vs-code-images/verifying-success.gif" style="box-shadow: 0 2px 4px rgba(0, 0, 0, 0.5);" alt="verifying-success" />

And with that green check mark, you can be assured that the harness has been verified!

## Wrapping up

You can use Kani through VS Code using the Kani VS Code extension, [available on the marketplace](https://marketplace.visualstudio.com/items?itemName=model-checking.kani-vscode-extension) now.
With this new extension you can now iteratively verify your code directly in the VS Code UI.
It lets you verify harnesses with a simple click, highlights property violations, lets you generate unit tests and debug them

The Kani extension has more features which weren’t mentioned in the blog, that you can read about in our [user guide documentation](https://github.com/model-checking/kani-vscode-extension/blob/main/docs/user-guide.md).

Please go ahead and try the extension yourself!

If you are running into issues with the Kani extension or have feature requests or suggestions, we’d [love to hear from you](https://github.com/model-checking/kani-vscode-extension/issues/new/choose).
