# Monolens contributor docs

Documentation for people changing monolens, not people using it.

User documentation is at [monorithm.github.io/monolens](https://monorithm.github.io/monolens/), built from [`website/`](../website).
That is where the guides, the API reference and the architecture notes live.

## Here

- [contributing.md](contributing.md) -- regenerating the bridge, the checks that must pass, the commit format, and how to add an operation.

## Conventions

One sentence per line, ASCII prose, diagrams as mermaid.
Documents explain *why* a thing is shaped the way it is and *how* to use it; the exact signature of a type belongs in the dartdoc on that type.

Pages under `website/src/content/docs/` carry Starlight frontmatter (`title` and `description`) instead of a leading `#` heading -- Starlight renders the title itself, so a page with both shows it twice.
Cross-links between them are site-absolute (`/monolens/guides/capture/`), because the site serves from a project-pages base path and a bare relative link resolves against the wrong root.
