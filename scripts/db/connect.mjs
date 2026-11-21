// Shared database connection for Node scripts. Reads .env if present (Node 22 built-in, no dotenv).
import { existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import postgres from "postgres";

const envFile = join(dirname(fileURLToPath(import.meta.url)), "../../.env");
if (existsSync(envFile)) process.loadEnvFile(envFile);

// Default: the local Supabase stack from `supabase start`.
export const LOCAL_URL = "postgres://postgres:postgres@127.0.0.1:54322/postgres";

export function connect() {
  const url = process.env.DATABASE_URL || LOCAL_URL;
  const sql = postgres(url, {
    max: 1,
    onnotice: () => {},
    connect_timeout: 15,
  });
  // Never print credentials: show only host/port/db.
  const u = new URL(url);
  return { sql, label: `${u.hostname}:${u.port || 5432}${u.pathname}` };
}
