// The SDKs, the bindings and the Action each keep their README as the source.
export const externalPages = {
  'sdk/ts/README.md': 'sdks/typescript',
  'sdk/spec/SPEC.md': 'sdks/specification',
  'integrations/python/README.md': 'sdks/python',
  'integrations/node/README.md': 'bindings/node',
  'integrations/ruby/README.md': 'bindings/ruby',
  'integrations/go/README.md': 'bindings/go',
  'integrations/java/README.md': 'bindings/java',
  'integrations/elixir/README.md': 'bindings/elixir',
  'integrations/dotnet/README.md': 'bindings/dotnet',
  'integrations/laravel/README.md': 'bindings/php',
  'action/README.md': 'github-action',
  'dbt/gnomon_dbt/README.md': 'dbt',
  'monitoring/README.md': 'monitoring',
  'examples/README.md': 'examples',
  'src/c/README.md': 'c-module',
};

export function pageId(source) {
  if (externalPages[source]) return externalPages[source];
  return source.replace(/^docs\//, '').replace(/\.mdx?$/, '');
}

export const sidebar = [
  { label: 'Getting started', items: [
    { slug: 'index', label: 'Introduction' }, 'installation', 'tutorial', 'concepts', 'examples',
  ] },
  { label: 'Agents', items: [
    'agents', { slug: 'mcp', label: 'The MCP server' }, 'testing',
  ] },
  { label: 'SDKs', items: [
    { slug: 'sdk', label: 'Runs and the SDKs' },
    { slug: 'sdks/typescript', label: 'TypeScript' }, { slug: 'sdks/python', label: 'Python' },
    { slug: 'bindings/node', label: 'Node' }, { slug: 'bindings/go', label: 'Go' },
    { slug: 'bindings/ruby', label: 'Ruby' }, { slug: 'bindings/java', label: 'Java' },
    { slug: 'bindings/elixir', label: 'Elixir' }, { slug: 'bindings/dotnet', label: '.NET' },
    { slug: 'bindings/php', label: 'PHP and Laravel' },
  ] },
  { label: 'Working on a branch', items: [
    'branches', 'schema-changes', 'review', 'merges', { slug: 'github-action', label: 'GitHub Action' },
  ] },
  { label: 'History', items: [
    'history', 'feed', { slug: 'dbt', label: 'dbt' },
  ] },
  { label: 'Reference', collapsed: true, items: [
    { slug: 'sql-reference', label: 'SQL' }, { slug: 'cli', label: 'CLI' }, 'errors',
    { slug: 'sdks/specification', label: 'SDK specification' },
  ] },
  { label: 'Operations', collapsed: true, items: [
    'operations', 'security', { slug: 'c-module', label: 'The C module' }, 'monitoring',
    { slug: 'benchmarks', label: 'Performance' },
  ] },
];
