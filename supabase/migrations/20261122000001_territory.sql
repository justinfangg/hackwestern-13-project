-- Territory leaderboards: named areas (campus, parks, neighbourhoods) and their H3 res 11 tiles.
-- Areas are seeded from supabase/seed/areas.json by scripts/db/seed-areas.mjs.

create table areas (
  id           text primary key,                    -- slug, e.g. 'western-campus'
  name         text not null,
  kind         text not null constraint areas_kind check (kind in ('campus', 'park', 'neighbourhood')),
  boundary     extensions.geography(MultiPolygon, 4326) not null,
  -- Number of res 11 tiles whose centre is inside the boundary (the denominator for % explored).
  total_tiles  integer not null constraint areas_total_tiles check (total_tiles > 0),
  source       text
);
create index areas_boundary_gist on areas using gist (boundary);

-- Precomputed res 11 tiles per area, so % explored is a plain join with cleared_tiles.
create table area_tiles (
  area_id  text   not null references areas (id) on delete cascade,
  h3       bigint not null,
  primary key (area_id, h3)
);
create index area_tiles_h3_idx on area_tiles (h3);

-- Time and distance explored are sums over the pings inside an area's boundary.
create index location_pings_location_gist on location_pings using gist (location);

-- Same lock-down as every other table: only Edge Functions read these.
alter table areas      enable row level security;
alter table area_tiles enable row level security;
revoke all on areas, area_tiles from anon, authenticated;
