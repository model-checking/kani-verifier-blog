---
layout: page
title: Blog
permalink: /blog/
---
Anything and everything about Kani: new features, case studies, verification efforts, and more.
Subscribe via the [Atom feed]({{ "/feed.xml" | relative_url }}).

{%- assign posts_by_year = site.posts | group_by_exp: "post", "post.date | date: '%Y'" %}
{% for year in posts_by_year %}
## {{ year.name }}

<ul class="post-list">
{%- for post in year.items %}
  <li>
    <span class="post-meta">{{ post.date | date: "%b %-d" }}</span>
    <a href="{{ post.url | relative_url }}">{{ post.title | escape }}</a>
  </li>
{%- endfor %}
</ul>
{% endfor %}
