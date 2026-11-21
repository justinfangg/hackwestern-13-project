-- 001: extensions.
-- Tiger Cloud ships TimescaleDB preinstalled; PostGIS is available and just needs enabling.
-- The local Docker image (timescale/timescaledb-ha) has both.

create extension if not exists timescaledb;
create extension if not exists postgis;

-- H3 is NOT done in the database: Edge Functions and scripts compute cells with h3-js and
-- store them as bigint. This keeps us independent of whether Tiger Cloud offers the h3 extension.
