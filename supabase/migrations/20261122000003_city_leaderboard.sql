-- City leaderboard (2026-11-22): one leaderboard per city, by day / week / month.
-- A city is an `areas` row with kind 'city'. Cities are too big to list every res 11 tile
-- (London is ~188k), so their area_tiles hold coarser res 9 cells (~0.1 km², ~3.8k for London)
-- and a tile counts as "in the city" when its res 9 parent is listed. `cell_res` says which
-- resolution an area's area_tiles use; `total_tiles` is still the number of res 11 tiles.

alter table areas drop constraint areas_kind;
alter table areas add constraint areas_kind check (kind in ('city', 'campus', 'park', 'neighbourhood'));
alter table areas add column cell_res smallint not null default 11
  constraint areas_cell_res check (cell_res between 0 and 11);

-- Parent of an H3 cell at a coarser resolution, with bit operations (no H3 extension on Supabase).
-- An H3 index keeps its resolution in bits 52–55 and one 3-bit digit per resolution below that;
-- the parent sets the resolution and marks the finer digits unused (7). Identity at the cell's own
-- resolution. Checked against h3-js cellToParent.
create function h3_parent(h3 bigint, res int) returns bigint
  language sql immutable strict parallel safe
  set search_path = ''
  as $$ select (h3 & ~(15::bigint << 52)) | (res::bigint << 52) | ((1::bigint << ((15 - res) * 3)) - 1) $$;
revoke execute on function h3_parent(bigint, int) from public, anon, authenticated;

-- Period filters ("this week") scan by time across all players.
create index cleared_tiles_first_cleared_idx on cleared_tiles (first_cleared_at);
create index location_pings_ts_idx on location_pings (ts);
