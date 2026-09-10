// Shared spec resolution — domain-free mechanics, used by core (verify) and
// packs (keeper). Maps onchain specHash -> local spec file by keccak256 of
// the file bytes (trailing newlines stripped, same as
// `cast keccak "$(cat specs/N.json)"`). Filenames are NOT reliable keys:
// job ids recycle across deployments, hashes don't.
import { readFileSync, readdirSync } from "fs";
import { dirname, join } from "path";
import { fileURLToPath } from "url";
import { keccak256 } from "viem";

const here = dirname(fileURLToPath(import.meta.url));
export const SPECS_DIR = join(here, "..", "..", "..", "specs");

export function loadLocalSpecs() {
  const out = {};
  let files = [];
  try {
    files = readdirSync(SPECS_DIR).filter((f) => f.endsWith(".json") && f !== "schema.json");
  } catch {
    return out;
  }
  for (const f of files) {
    try {
      const raw = readFileSync(join(SPECS_DIR, f), "utf8").replace(/\n+$/, "");
      out[keccak256(Buffer.from(raw, "utf8")).toLowerCase()] = {
        id: f.replace(/\.json$/, ""),
        spec: JSON.parse(raw),
      };
    } catch { /* skip unreadable spec files */ }
  }
  return out;
}

export function readSpecFile(jobId) {
  try {
    return JSON.parse(readFileSync(join(SPECS_DIR, `${jobId}.json`), "utf8"));
  } catch {
    return null;
  }
}
