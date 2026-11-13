import type { Metadata } from 'next';
import type { ReactNode } from 'react';
import { RootProvider } from 'fumadocs-ui/provider/next';
import './globals.css';

export const metadata: Metadata = {
  title: { default: 'Gnomon Docs', template: '%s | Gnomon Docs' },
  description: 'Git for Postgres data, built for agents: branches, history, merges and undo inside PostgreSQL.',
  icons: { icon: '/gnomon.svg' },
};

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="en" suppressHydrationWarning>
      <body className="flex min-h-screen flex-col">
        <RootProvider search={{ options: { type: 'static', api: '/search-index.json' } }}>
          {children}
        </RootProvider>
      </body>
    </html>
  );
}
