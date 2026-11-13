import { copyFile, glob, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';

// Serve /<page>.html beside /<page>/, so links written either way keep working.
const output = resolve('out');
for await (const file of glob('**/index.html', { cwd: output })) {
  const id = file.split('/').slice(0, -1).join('/');
  if (!id || id === '404' || id === '_not-found') continue;
  const url = `/${id}/`;
  const html = `<!doctype html><html lang="en"><meta charset="utf-8">
<title>Page moved · Gnomon Docs</title><meta name="robots" content="noindex">
<script>location.replace(${JSON.stringify(url)} + location.search + location.hash)</script>
<meta http-equiv="refresh" content="0;url=${url}"><a href="${url}">Open the documentation</a></html>`;
  await writeFile(resolve(output, id + '.html'), html);
}

await copyFile(new URL('../../llms.txt', import.meta.url), resolve(output, 'llms.txt'));
