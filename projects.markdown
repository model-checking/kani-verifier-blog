---
layout: page
title: Projects
permalink: /projects/
---
Projects are major public Kani initiatives. Each page gives the stable context for an
initiative: why it exists, what it aims to do, and where to follow or join the work.
Day-to-day progress (issues, pull requests, milestones) lives on GitHub.

<ul>
{%- for project in site.projects %}
  <li>
    <a href="{{ project.url | relative_url }}">{{ project.title }}</a>
    {%- if project.summary %}: {{ project.summary }}{% endif %}
  </li>
{%- endfor %}
</ul>
