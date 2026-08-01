# monolens docs site

The user documentation at
[monorithm.github.io/monolens](https://monorithm.github.io/monolens/).
[Astro](https://astro.build) + [Starlight](https://starlight.astro.build),
deployed to GitHub Pages by `.github/workflows/website.yml` on every push to
`main` that touches this directory.

Contributor documentation is in [`../docs`](../docs) and is not part of this
site.

## Running it

Yarn 4 through Corepack, which ships with Node:

```bash
corepack enable
yarn install
yarn dev            # localhost:4321/monolens
```

| Command | Does |
| --- | --- |
| `yarn dev` | Dev server with hot reload |
| `yarn build` | Production build into `dist/` |
| `yarn preview` | Serve `dist/` locally, as deployed |

## Writing

Pages live in `src/content/docs/`, one Markdown file per route, grouped into the
`start/`, `guides/` and `reference/` sections the sidebar declares in
`astro.config.mjs`. Adding a page means adding the file *and* its sidebar entry —
Starlight will render an orphan route otherwise.

Every page opens with frontmatter rather than an `# H1`:

```markdown
---
title: "Capture"
description: "One sentence. It is the search result and the social card."
---
```

Two conventions worth keeping:

- **Links between pages are site-absolute** — `/monolens/guides/capture/`, not
  `capture.md`. The site serves from a project-pages base path, so a bare
  relative link resolves against the wrong root.
- **Diagrams are mermaid fences.** `astro-mermaid` is registered *before*
  Starlight in the integrations array, because whichever comes first claims the
  fence.

The version in the sidebar heading is read out of `../pubspec.yaml` at build
time. There is no versioned-docs plugin yet; when 0.4 stops being current, add
[`starlight-versions`](https://starlight-versions.vercel.app) and cut the
snapshot *at* that release, since it freezes whatever the working tree says.
