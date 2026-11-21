#!/usr/bin/env node
// Applies db/migrations/NNN_name.sql in order and records each one in schema_migrations.
//
//   npm run db:migrate          -> DATABASE_URL (default: the local Docker database)
//   npm run db:migrate:tiger    -> TIGER_DATABASE_URL (Tiger Cloud, SSL required)
//
// Each file runs in its own transaction. A file whose first line is `-- migrate:no-transaction`
// runs outside one (needed for e.g. CALL refresh_continuous_aggregate).
// Applied files are checksummed: editing one afterwards is an error. Add a new migration instead
// (or, locally only, `npm run db:reset`).
import { createHash } from "node:crypto";
import { readdirSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { connect } from "./connect.mjs";

const dir = join(dirname(fileURLToPath(import.meta.url)), "../../db/migrations");
const tiger = process.argv.includes("--tiger");
const { sql, label } = connect({ tiger });

try {
  console.log(`Migrating ${label}`);
  await sql`create table if not exists schema_migrations (
    name text primary key, checksum text not null, applied_at timestamptz not null default now())`;
  // Stop two runs (e.g. two teammates on Tiger) from applying the same migration at once.
  await sql`select pg_advisory_lock(hashtext('fogofwar_migrations'))`;

  const applied = new Map((await sql`select name, checksum from schema_migrations`).map((r) => [r.name, r.checksum]));
  const files = readdirSync(dir).filter((f) => /^\d{3}_[\w-]+\.sql$/.test(f)).sort();
  let ran = 0;

  for (const file of files) {
    const text = readFileSync(join(dir, file), "utf8");
    const checksum = createHash("sha256").update(text.replace(/\r\n/g, "\n")).digest("hex");
    if (applied.has(file)) {
      if (applied.get(file) !== checksum) {
        throw new Error(`${file} changed after it was applied. Add a new migration instead (locally: npm run db:reset).`);
      }
      continue;
    }
    const t0 = Date.now();
    if (/^--\s*migrate:no-transaction/.test(text)) {
      await sql.unsafe(text).simple();
      await sql`insert into schema_migrations (name, checksum) values (${file}, ${checksum})`;
    } else {
      await sql.begin(async (tx) => {
        await tx.unsafe(text).simple();
        await tx`insert into schema_migrations (name, checksum) values (${file}, ${checksum})`;
      });
    }
    console.log(`  applied ${file} (${Date.now() - t0} ms)`);
    ran++;
  }
  console.log(ran ? `Done: ${ran} migration(s) applied.` : "Up to date: nothing to apply.");
} catch (err) {
  console.error(`Migration failed: ${err.message}`);
  process.exitCode = 1;
} finally {
  await sql.end();
}
