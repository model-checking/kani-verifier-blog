# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Jekyll static site (theme `minima`, `kramdown`, `jekyll-feed`) for the Kani Rust Verifier project website (Home, Blog, Projects, Research, Contact, plus a link to the Kani Book), published at `https://model-checking.github.io/kani-verifier-blog`. There is no application code or test suite; the content is blog posts.

## Commands

```bash
bundle install              # install gems (Jekyll ~> 4.2.2)
bundle exec jekyll serve    # local preview (default http://localhost:4000/kani-verifier-blog/)
bundle exec jekyll build    # build into _site/ (git-ignored)
```

`_config.yml` is not hot-reloaded; restart `jekyll serve` after editing it.

## Structure

- `_data/navigation.yml`: top nav (rendered by `_includes/header.html`). `_data/publications.yml`: Research page entries.
- `_projects/*.md`: Projects collection (`layout: project`; front matter `status`, `leads`, `milestone`, `summary`). `_projects/autoharness.md` is the template for new projects. Do not publish unreleased work.
- `index.markdown`, `blog.markdown` (`/blog/`), `projects.markdown`, `research.markdown`, `contact.markdown`: top-level pages. Documentation content belongs in the Kani Book, not here.
- `assets/main.scss`: minima import plus small site additions.

- `_posts/YYYY-MM-DD-slug.md`: one file per post. Front matter is `title:` and `layout: post`. Posts conventionally start with an `Authors: [Name](github-url), ...` line, followed by an intro and `##` sections.
- `_includes/head.html`: overrides the minima head; loads MathJax 2.7.7 from cdnjs. `_includes/mathjax.html` configures `$...$` and `\(...\)` as inline math, so a literal `$` in prose may need escaping (`\$`).
- `assets/images/`, `assets/diagrams/`: images and diagrams referenced by posts.
- `about.markdown`, `404.html`: legacy pages, kept so URLs don't change.

## Gotchas

- `future: false` in `_config.yml`: a post dated in the future will not appear on the live site until that date.
- `baseurl` is `kani-verifier-blog` (no leading slash). In posts, reference assets through `{{ site.baseurl }}` or `relative_url` so links work both locally and when deployed.
- Use inclusive language (primary/replica, allowlist/denylist) in posts.
- Commits are made via PRs against `main`; commit messages follow the style `Add Blog for <topic> (#NN)`.
- Post URLs use Jekyll's default permalink (`/:year/:month/:day/:title`); do not set a global `permalink` in `_config.yml`.
- Local build: system Ruby is too old, and Jekyll 4.2.2 with Ruby 3.2+ needs `logger` 1.5.3 and `liquid` 4.0.4 (do not commit those to the Gemfile without checking CI). Serve with `--baseurl ""` to browse at `http://localhost:4000/`.
