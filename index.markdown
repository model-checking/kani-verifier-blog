---
layout: default
title: Kani
---
<div class="hero" markdown="1">

<h1 class="hero-title"><img class="hero-logo" src="{{ '/assets/images/kani-logo.png' | relative_url }}" alt="Kani"></h1>

<p class="tagline">Kani is a bit-precise model checker for Rust.</p>

If you want to be sure that a class of bugs, such as arithmetic overflow, out-of-bounds access, or
undefined behavior in `unsafe` code, can never occur in your Rust crate, you can use Kani to explore all
possible execution paths. Or go further and write a specification of how you expect your functions to
behave, and Kani will check whether it holds for all possible inputs. Kani aims to make mechanized proofs
easy to use for every Rust developer: write a harness like you would write a test, and Kani checks it over
all possible inputs.

<p><a class="button" href="https://model-checking.github.io/kani/">Get Started</a></p>
</div>

## Latest News

<ul class="post-list">
{%- for item in site.data.news %}
  <li>
    <span class="post-meta">{{ item.date | date: "%b %-d, %Y" }}</span>
    <a href="{% if item.url contains '://' %}{{ item.url }}{% else %}{{ item.url | relative_url }}{% endif %}">{{ item.text }}</a>
  </li>
{%- endfor %}
</ul>

[All blog posts]({{ "/blog/" | relative_url }})

## Active Projects

<ul>
{%- for project in site.projects %}
  <li><a href="{{ project.url | relative_url }}">{{ project.title }}</a>{% if project.summary %}: {{ project.summary }}{% endif %}</li>
{%- endfor %}
</ul>

[All projects]({{ "/projects/" | relative_url }})
