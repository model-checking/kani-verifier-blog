---
layout: page
title: Research
permalink: /research/
---
## Publications about Kani

<ul class="publication-list">
{%- for pub in site.data.publications.about %}
  <li>
    {% if pub.authors %}{{ pub.authors }}. {% endif %}{{ pub.year }}.
    {% if pub.url %}<a href="{% if pub.url contains '://' %}{{ pub.url }}{% else %}{{ pub.url | relative_url }}{% endif %}">{{ pub.title }}</a>{% else %}{{ pub.title }}{% endif %}.
    <em>{{ pub.venue }}</em>.{% if pub.video %} <a href="{{ pub.video }}">Video of the presentation</a>.{% endif %}{% if pub.note %} {{ pub.note }}{% endif %}
  </li>
{%- endfor %}
</ul>

## Publications using Kani

This is not an exhaustive list.

<ul class="publication-list">
{%- for pub in site.data.publications.using %}
  <li>
    {% if pub.authors %}{{ pub.authors }}. {% endif %}{{ pub.year }}.
    {% if pub.url %}<a href="{% if pub.url contains '://' %}{{ pub.url }}{% else %}{{ pub.url | relative_url }}{% endif %}">{{ pub.title }}</a>{% else %}{{ pub.title }}{% endif %}.
    <em>{{ pub.venue }}</em>.{% if pub.video %} <a href="{{ pub.video }}">Video of the presentation</a>.{% endif %}{% if pub.note %} {{ pub.note }}{% endif %}
  </li>
{%- endfor %}
</ul>

To cite Kani, see the [citation instructions in the repository README](https://github.com/model-checking/kani#citing-kani).
