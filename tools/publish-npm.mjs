// Publish the tested tarballs. A maintainer can bootstrap a new name, then rerun the job safely.
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

for (const file of process.argv.slice(2)) {
  const { name, version } = JSON.parse(execFileSync('tar', ['-xOzf', file, 'package/package.json']));
  const response = await fetch(`https://registry.npmjs.org/${encodeURIComponent(name)}/${version}`);
  if (response.ok) {
    const { dist } = await response.json();
    const integrity = 'sha512-' + createHash('sha512').update(readFileSync(file)).digest('base64');
    if (dist.integrity !== integrity) throw new Error(`${name}@${version} already exists with different contents`);
    console.log(`${name}@${version} is already published and matches the release`);
    continue;
  }
  if (response.status !== 404) throw new Error(`Registry returned ${response.status} for ${name}@${version}`);
  const args = ['publish', resolve(file), '--access', 'public'];
  if (process.env.GITHUB_ACTIONS) args.push('--provenance');
  execFileSync('npm', args, { stdio: 'inherit' });
}
