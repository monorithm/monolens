// @ts-check
import { readFileSync } from 'node:fs';
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';
import mermaid from 'astro-mermaid';

// Read from the pubspec rather than restating it here, because two places to
// update is one place to forget.
const packageVersion =
  /^version:\s*(\S+)/m.exec(readFileSync('../pubspec.yaml', 'utf8'))?.[1] ??
  '0.0.0';

export default defineConfig({
  site: 'https://monorithm.github.io',
  // Project Pages serve under /<repo>. Without this every internal link and
  // asset resolves against the domain root and 404s.
  base: '/monolens',
  trailingSlash: 'always',
  integrations: [
    // Must precede Starlight: it rewrites ```mermaid fences before Starlight's
    // code renderer claims them. Two pages carry diagrams that would otherwise
    // ship as plain code blocks.
    mermaid({
      theme: 'dark',
      autoTheme: true,
      mermaidConfig: {
        flowchart: { curve: 'basis', padding: 18 },
        themeVariables: {
          fontFamily: "'Inter Variable', system-ui, sans-serif",
        },
      },
    }),
    starlight({
      title: 'monolens',
      description:
        'Headless camera capture and on-device media editing for Flutter — ' +
        'crop, rotate, trim, blur, annotate. No ffmpeg, no widgets.',
      customCss: ['./src/styles/theme.css'],
      // No starlight-versions yet: nothing has been left behind to freeze. The
      // first snapshot gets cut when 0.4 stops being current, and it has to be
      // cut *at* that release -- the plugin snapshots whatever the working tree
      // says, so one taken three commits into 0.5 is wrong in a way nothing
      // detects.
      social: [
        {
          icon: 'github',
          label: 'GitHub',
          href: 'https://github.com/monorithm/monolens',
        },
      ],
      editLink: {
        baseUrl: 'https://github.com/monorithm/monolens/edit/main/website/',
      },
      lastUpdated: true,
      pagination: true,
      expressiveCode: {
        themes: ['github-dark-default', 'github-light'],
      },
      tableOfContents: { minHeadingLevel: 2, maxHeadingLevel: 3 },
      head: [
        {
          tag: 'meta',
          attrs: { name: 'theme-color', content: '#121016' },
        },
      ],
      sidebar: [
        {
          label: `v${packageVersion}`,
          items: [
            { label: 'What is monolens?', slug: 'start/what-is-monolens' },
            { label: 'Getting started', slug: 'start/getting-started' },
          ],
        },
        {
          label: 'Guides',
          items: [
            { label: 'Capture', slug: 'guides/capture' },
            { label: 'Editing', slug: 'guides/editing' },
            { label: 'Annotations', slug: 'guides/annotations' },
            { label: 'Building an editor', slug: 'guides/building-an-editor' },
            { label: 'Testing', slug: 'guides/testing' },
          ],
        },
        {
          label: 'Reference',
          items: [
            { label: 'API', slug: 'reference/api' },
            { label: 'Platform notes', slug: 'reference/platforms' },
            { label: 'Architecture', slug: 'reference/architecture' },
          ],
        },
      ],
    }),
  ],
});
