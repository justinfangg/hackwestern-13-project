// Shared database connection for Node scripts. Reads .env if present (Node 22 built-in, no dotenv).
import { existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import postgres from "postgres";

const envFile = join(dirname(fileURLToPath(import.meta.url)), "../../.env");
if (existsSync(envFile)) process.loadEnvFile(envFile);

export const LOCAL_URL = "postgres://postgres:postgres@localhost:5432/fogofwar";

/** @param {{ tiger?: boolean }} opts */
export function connect({ tiger = false } = {}) {
  const url = tiger ? process.env.TIGER_DATABASE_URL : process.env.DATABASE_URL || LOCAL_URL;
  if (!url) throw new Error("TIGER_DATABASE_URL is not set in .env");
  const sql = postgres(url, {
    max: 1,
    ssl: tiger ? "require" : false,
    onnotice: () => {}, // TimescaleDB is chatty; errors still throw
    connect_timeout: 15,
  });
  // Never print credentials: show only host/port/db.
  const u = new URL(url);
  return { sql, label: `${tiger ? "Tiger Cloud" : "local"} ${u.hostname}:${u.port || 5432}${u.pathname}` };
}
