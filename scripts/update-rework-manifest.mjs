#!/usr/bin/env node

import fs from "node:fs/promises";
import path from "node:path";

function parseArgs(argv) {
  const args = {};
  for (let i = 0; i < argv.length; i += 1) {
    const token = argv[i];
    if (!token.startsWith("--")) continue;
    const key = token.slice(2);
    const value = argv[i + 1];
    if (!value || value.startsWith("--")) throw new Error(`Missing value for --${key}`);
    args[key] = value;
    i += 1;
  }
  return args;
}

const args = parseArgs(process.argv.slice(2));
for (const key of ["job", "slide", "version", "status", "reason"]) {
  if (!args[key]) throw new Error(`--${key} is required`);
}

const jobRoot = path.resolve(args.job);
const manifestPath = path.join(jobRoot, "04_rework", "manifest.json");
const slide = Number.parseInt(args.slide, 10);
const version = Number.parseInt(args.version, 10);
if (!Number.isInteger(slide) || !Number.isInteger(version)) throw new Error("slide and version must be integers");

const manifest = JSON.parse(await fs.readFile(manifestPath, "utf8"));
const entry = manifest.slides.find((item) => item.slide === slide);
if (!entry) throw new Error(`Slide ${slide} is not in the required rework manifest`);

const slideId = String(slide).padStart(4, "0");
const versionId = String(version).padStart(3, "0");
const existingIndex = entry.versions.findIndex((item) => item.version === version);
const existingVersion = existingIndex >= 0 ? entry.versions[existingIndex] : null;
const versionEntry = {
  ...(existingVersion || {}),
  version,
  path: `04_rework/slide-${slideId}/v${versionId}.png`,
  sourcePath: `04_rework/slide-${slideId}/v${versionId}-source.png`,
  status: args.status,
  reason: args.reason,
};
if (args["evidence-locks"]) {
  versionEntry.evidenceLocks = JSON.parse(args["evidence-locks"]);
} else if (args["evidence-locks-base64"]) {
  versionEntry.evidenceLocks = JSON.parse(Buffer.from(args["evidence-locks-base64"], "base64").toString("utf8"));
}

if (existingIndex >= 0) entry.versions[existingIndex] = versionEntry;
else entry.versions.push(versionEntry);
entry.versions.sort((a, b) => a.version - b.version);
entry.currentVersion = version;
entry.status = args.status;
if (!entry.reviewStatus || !existingVersion || entry.reviewStatus === "rejected") {
  entry.reviewStatus = "pending";
  entry.reviewReason = "";
  entry.reviewedAt = null;
  entry.needsNewVersion = false;
}

await fs.writeFile(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`, "utf8");
console.log(JSON.stringify({ manifestPath, slide, version, status: args.status }, null, 2));
