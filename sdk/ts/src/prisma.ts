// Prisma qualifies every name with its schema, so a branch is a datasource URL whose schema is
// the branch's routing schema (and whose options put the session on the branch).
import type { Gnomon } from "./index.ts";

export async function prismaBranchUrl(g: Gnomon, databaseUrl: string, branch: string): Promise<string> {
  const opts = await g.branches.options(branch);
  const schema = (/search_path=([^, ]+)/.exec(opts) ?? [])[1] ?? "public";
  const u = new URL(databaseUrl);
  u.searchParams.set("schema", schema.replace(/"/g, ""));
  u.searchParams.set("options", opts);
  return u.toString();
}
