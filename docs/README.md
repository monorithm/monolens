# Monolens contributor docs

Documentation for people changing monolens, not people using it.

User documentation is at [monorithm.github.io/monodocs/monolens/latest](https://monorithm.github.io/monodocs/monolens/latest/), built from [monodocs](https://github.com/monorithm/monodocs).
That is where the guides, the API reference and the architecture notes live, alongside monowave's.
It moved out of this repository so the two packages could share one site and be versioned independently; `redirect/` keeps the old URLs working, including the one baked into monolens 0.4.0's pubspec.

## Here

- [contributing.md](contributing.md) -- regenerating the bridge, the checks that must pass, the commit format, and how to add an operation.

## Conventions

One sentence per line, ASCII prose, diagrams as mermaid.
Documents explain *why* a thing is shaped the way it is and *how* to use it; the exact signature of a type belongs in the dartdoc on that type.

The conventions for writing those pages -- Starlight frontmatter instead of a leading `#` heading, relative cross-links, how a version is frozen -- now live in [monodocs's README](https://github.com/monorithm/monodocs#writing).
