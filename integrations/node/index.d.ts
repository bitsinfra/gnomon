import type { Client, Pool, PoolClient } from 'pg';
export interface BranchOpts { cModule?: boolean; schemas?: string[]; asOf?: string; scratch?: boolean }
export function routingSchema(schema?: string, opts?: { scratch?: boolean }): string;
export function branchOptions(branch: string, opts?: BranchOpts): string;
export function branchUrl(url: string, branch: string, opts?: BranchOpts): string;
export function prismaBranchUrl(url: string, branch: string, opts?: { cModule?: boolean; schema?: string; asOf?: string; scratch?: boolean }): string;
export function withBranch<T>(poolOrClient: Pool | Client, branch: string, fn: (c: PoolClient | Client) => Promise<T>, opts?: { asOf?: string }): Promise<T>;
export function use(client: Client | PoolClient, branch?: string, asOf?: string | null): Promise<string>;
export function createBranch(client: Client | PoolClient, name: string, opts?: { parent?: string; scratch?: boolean; at?: string | null }): Promise<number>;
export function createScratch(client: Client | PoolClient, prefix?: string, parent?: string): Promise<string>;
export function dropBranch(client: Client | PoolClient, name: string, cascade?: boolean): Promise<void>;
export function diff(client: Client | PoolClient, a: string, b?: string | null): Promise<Array<{ table: string; key: unknown; kind: string; col: string | null; old: unknown; new: unknown }>>;
export function merge(client: Client | PoolClient, source: string, target?: string | null): Promise<{ id: number; status: string; stats: unknown }>;
export function drizzleOnBranch<D>(pool: Pool, drizzle: (c: PoolClient, config?: unknown) => D, config?: unknown): <T>(branch: string, fn: (db: D) => Promise<T>) => Promise<T>;
export function testBranch(makeClient: () => Client, opts?: { prefix?: string; parent?: string; keep?: boolean }): { client: Client | null; branch: string | null; setup(): Promise<void>; teardown(): Promise<void> };

/** The `options` the database computes for a branch (gnomon.connection_options): knows the
 * branch's kind, a confined role's mask profile and the branch's schema version. */
export function connectionOptions(client: { query(sql: string, params?: unknown[]): Promise<{ rows: any[] }> }, branch: string, opts?: { cModule?: boolean }): Promise<string>;
