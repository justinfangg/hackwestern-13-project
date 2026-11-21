-- Extensions. Supabase installs extensions into the `extensions` schema, which is on the
-- default search_path, so types like geography(Point, 4326) resolve without a prefix.
create schema if not exists extensions;
create extension if not exists postgis with schema extensions;

-- H3 is NOT done in the database: Edge Functions compute cells with h3-js and store them as
-- bigint. JSON carries them as lowercase hex strings (docs/api.md).
