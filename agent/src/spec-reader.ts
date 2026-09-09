import { readFileSync, readdirSync } from "fs";
import { join } from "path";

export interface JobSpec {
  title: string;
  description: string;
  requirements: string[];
  deliverables: string[];
  payment: string;
  deadline: string;
  context: string;
}

const SPECS_DIR = join(import.meta.dirname, "..", "..", "specs");

export function readSpec(jobId: string): JobSpec | null {
  try {
    const raw = readFileSync(join(SPECS_DIR, `${jobId}.json`), "utf-8");
    return JSON.parse(raw) as JobSpec;
  } catch {
    return null;
  }
}

export function listSpecs(): { id: string; spec: JobSpec }[] {
  try {
    return readdirSync(SPECS_DIR)
      .filter((f) => f.endsWith(".json"))
      .map((f) => ({
        id: f.replace(".json", ""),
        spec: JSON.parse(readFileSync(join(SPECS_DIR, f), "utf-8")) as JobSpec,
      }));
  } catch {
    return [];
  }
}
