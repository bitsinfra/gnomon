// Drizzle (and Kysely, any query builder on node-postgres): a pool whose connections start on a
// branch, from gnomon.connection_options. Pass its result to drizzle(pool).
import type { Gnomon } from "./index.ts";

export async function branchPoolConfig(g: Gnomon, base: Record<string, unknown>, branch: string): Promise<Record<string, unknown>> {
  return { ...base, options: await g.branches.options(branch) };
}
