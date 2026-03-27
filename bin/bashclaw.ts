#!/usr/bin/env node
/**
 * bashclaw — TypeScript thin entry point
 *
 * Preflight checks for required tools, then delegates to bashclaw.sh.
 */

import { execFileSync } from "child_process";
import { existsSync } from "fs";
import { resolve, dirname } from "path";

const REQUIRED_TOOLS = [
  { name: "bash", check: "bash --version" },
  { name: "jq", check: "jq --version" },
  { name: "sqlite3", check: "sqlite3 --version" },
  { name: "git", check: "git --version" },
];

function checkTool(name: string, check: string): boolean {
  try {
    execFileSync("bash", ["-c", check], { stdio: "ignore" });
    return true;
  } catch {
    return false;
  }
}

function main(): void {
  // Preflight: check required tools
  const missing: string[] = [];
  for (const tool of REQUIRED_TOOLS) {
    if (!checkTool(tool.name, tool.check)) {
      missing.push(tool.name);
    }
  }

  if (missing.length > 0) {
    console.error(
      `ERROR: Missing required tools: ${missing.join(", ")}`
    );
    console.error("Install them before using BashClaw.");
    process.exit(1);
  }

  // Find bashclaw.sh relative to this script
  const scriptDir = dirname(resolve(__filename));
  const bashclawSh = resolve(scriptDir, "..", "bashclaw.sh");

  if (!existsSync(bashclawSh)) {
    console.error(`ERROR: bashclaw.sh not found at ${bashclawSh}`);
    process.exit(1);
  }

  // Forward all args to bashclaw.sh
  const args = process.argv.slice(2);

  try {
    execFileSync("bash", [bashclawSh, ...args], {
      stdio: "inherit",
      env: { ...process.env },
    });
  } catch (err: any) {
    process.exit(err.status || 1);
  }
}

main();
