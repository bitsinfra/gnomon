import type { ReactNode } from 'react';
import { DocsLayout } from 'fumadocs-ui/layouts/docs';
import { tree } from '../../lib/source';

export default function GuideLayout({ children }: { children: ReactNode }) {
  return (
    <DocsLayout
      tree={tree}
      nav={{ url: '/', title: <><img src="/gnomon.svg" width="22" height="22" alt="" /> Gnomon Docs</> }}
      githubUrl="https://github.com/bitsinfra/gnomon"
    >
      {children}
    </DocsLayout>
  );
}
