// H3 helpers. JSON carries cells as lowercase hex strings; the database stores them as bigint.
import { getResolution, isValidCell, latLngToCell } from "npm:h3-js@4.2.1";

export const REGION_RES = 7;
export const TILE_RES = 11;

export const regionOf = (lat: number, lng: number): string => latLngToCell(lat, lng, REGION_RES);
export const hexToDb = (hex: string): string => BigInt("0x" + hex).toString();
export const dbToHex = (v: string | bigint): string => BigInt(v).toString(16);
export const isTile = (hex: unknown): hex is string =>
  typeof hex === "string" && /^[0-9a-f]{15}$/.test(hex) && isValidCell(hex) && getResolution(hex) === TILE_RES;
