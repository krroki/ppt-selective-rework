import http from "node:http";
import fs from "node:fs";
import fsp from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const currentDir = path.dirname(fileURLToPath(import.meta.url));
const publicDir = path.join(currentDir, "public");

function readArg(name, fallback = undefined) {
  const index = process.argv.indexOf(name);
  return index >= 0 && process.argv[index + 1] ? process.argv[index + 1] : fallback;
}

const jobArg = readArg("--job");
const port = Number(readArg("--port", "4173"));
const shutdownToken = process.env.PPT_REVIEW_SHUTDOWN_TOKEN || "";
const ownerPid = Number(process.env.PPT_REVIEW_OWNER_PID || "0");
let ownerWatch = null;
let shuttingDown = false;

if (!jobArg) {
  console.error("Usage: node app/server.mjs --job <job-root> [--port 4173]");
  process.exit(2);
}

const jobRoot = path.resolve(jobArg);
const decisionsPath = path.join(jobRoot, "02_triage", "decisions.json");
const stylePath = path.join(jobRoot, "03_style", "approved-style.json");
const projectPath = path.join(jobRoot, "project.json");
const slidesPath = path.join(jobRoot, "01_inventory", "slides.json");
const palettePath = path.join(jobRoot, "03_style", "palette-candidates.json");
const criteriaPath = path.join(jobRoot, "02_triage", "criteria.json");
const autoAuditPath = path.join(jobRoot, "02_triage", "auto-audit.json");
const reworkManifestPath = path.join(jobRoot, "04_rework", "manifest.json");

async function readJson(filePath, fallback = null) {
  try {
    return JSON.parse(await fsp.readFile(filePath, "utf8"));
  } catch (error) {
    if (error.code === "ENOENT") return fallback;
    throw error;
  }
}

async function writeJsonAtomic(filePath, value) {
  const tempPath = `${filePath}.tmp`;
  await fsp.writeFile(tempPath, `${JSON.stringify(value, null, 2)}\n`, "utf8");
  await fsp.rename(tempPath, filePath);
}

function sendJson(response, status, value) {
  const body = JSON.stringify(value);
  response.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "content-length": Buffer.byteLength(body),
    "cache-control": "no-store",
  });
  response.end(body);
}

function sendText(response, status, value) {
  response.writeHead(status, { "content-type": "text/plain; charset=utf-8" });
  response.end(value);
}

async function readBody(request) {
  const chunks = [];
  let length = 0;
  for await (const chunk of request) {
    length += chunk.length;
    if (length > 1_000_000) throw httpError(413, "Request body is too large");
    chunks.push(chunk);
  }
  if (!chunks.length) return {};
  try {
    return JSON.parse(Buffer.concat(chunks).toString("utf8"));
  } catch (error) {
    if (error instanceof SyntaxError) throw httpError(400, "Request body must be valid JSON");
    throw error;
  }
}

function contentType(filePath) {
  const extension = path.extname(filePath).toLowerCase();
  return {
    ".html": "text/html; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".js": "text/javascript; charset=utf-8",
    ".json": "application/json; charset=utf-8",
    ".png": "image/png",
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".svg": "image/svg+xml",
  }[extension] || "application/octet-stream";
}

function streamFile(response, filePath) {
  if (!fs.existsSync(filePath) || !fs.statSync(filePath).isFile()) {
    sendText(response, 404, "Not found");
    return;
  }
  response.writeHead(200, {
    "content-type": contentType(filePath),
    "cache-control": filePath.includes("01_inventory") ? "public, max-age=3600" : "no-cache",
  });
  fs.createReadStream(filePath).pipe(response);
}

async function bootstrap() {
  const [project, inventory, decisions, palette, style, rubric, autoAudit, reworkManifest] = await Promise.all([
    readJson(projectPath),
    readJson(slidesPath),
    readJson(decisionsPath),
    readJson(palettePath, { candidates: [] }),
    readJson(stylePath, null),
    readJson(criteriaPath, null),
    readJson(autoAuditPath, { slides: [] }),
    readJson(reworkManifestPath, { requiredSlides: [], slides: [] }),
  ]);

  const decisionBySlide = new Map(decisions.slides.map((item) => [item.slide, item]));
  const auditBySlide = new Map((autoAudit?.slides || []).map((item) => [item.slide, item]));
  const reworkBySlide = new Map((reworkManifest?.slides || []).map((item) => [item.slide, item]));
  const slides = inventory.slides.map((slide) => ({
    ...slide,
    ...(decisionBySlide.get(slide.slide) || {
      status: slide.suggestion || "uncertain",
      reason: "",
      source: "auto_heuristic",
      autoStatus: slide.suggestion || "uncertain",
      autoReason: "",
      autoSource: "auto_heuristic",
    }),
    criteria: Array.isArray(auditBySlide.get(slide.slide)?.criteria)
      ? auditBySlide.get(slide.slide).criteria
      : [],
    rework: reworkBySlide.get(slide.slide) || null,
  }));
  return { project, slides, palette, style, rubric, rework: reworkManifest, finalizedAt: decisions.finalizedAt };
}

async function updateReworkReview(slideNumber, versionNumber, patch) {
  const allowedStatuses = new Set(["approved", "rejected"]);
  const reviewStatus = String(patch.status || "");
  const reviewReason = String(patch.reason || "").trim().slice(0, 1000);
  if (!allowedStatuses.has(reviewStatus)) throw httpError(400, "Invalid rework review status");
  if (reviewStatus === "rejected" && !reviewReason) {
    throw httpError(400, "반려 사유를 입력하세요.");
  }

  const manifest = await readJson(reworkManifestPath);
  const slide = manifest?.slides?.find((item) => item.slide === slideNumber);
  if (!slide) throw httpError(404, "Unknown rework slide");
  if (slide.currentVersion !== versionNumber) throw httpError(409, "현재 버전만 승인 또는 반려할 수 있습니다.");
  const version = slide.versions?.find((item) => item.version === versionNumber);
  if (!version) throw httpError(404, "Unknown rework version");
  if (version.status === "internal_rejected") throw httpError(409, "내부 검수에서 제외된 버전입니다.");
  if (version.reviewStatus === "approved" && reviewStatus !== "approved") {
    throw httpError(409, "승인된 버전은 명시적으로 재개방하기 전까지 변경할 수 없습니다.");
  }

  const reviewedAt = new Date().toISOString();
  version.reviewStatus = reviewStatus;
  version.reviewReason = reviewReason;
  version.reviewedAt = reviewedAt;
  version.reviewSource = "human";
  slide.reviewStatus = reviewStatus;
  slide.reviewReason = reviewReason;
  slide.reviewedAt = reviewedAt;
  slide.needsNewVersion = reviewStatus === "rejected";
  manifest.updatedAt = reviewedAt;
  await writeJsonAtomic(reworkManifestPath, manifest);
  return { slide, version };
}

function httpError(statusCode, message) {
  const error = new Error(message);
  error.statusCode = statusCode;
  return error;
}

function validateReworkCriteria(value) {
  if (!Array.isArray(value)) {
    throw httpError(400, "reworkCriteria must be an array");
  }
  if (value.length > 100) {
    throw httpError(422, "reworkCriteria must contain 100 items or fewer");
  }

  const seenIds = new Set();
  return value.map((item, index) => {
    const itemPath = `reworkCriteria[${index}]`;
    if (!item || typeof item !== "object" || Array.isArray(item)) {
      throw httpError(422, `${itemPath} must be an object`);
    }

    const id = typeof item.id === "string" ? item.id.trim() : "";
    const label = typeof item.label === "string" ? item.label.trim() : "";
    const description = typeof item.description === "string" ? item.description.trim() : "";

    if (!id) throw httpError(422, `${itemPath}.id is required`);
    if (id.length > 80) throw httpError(422, `${itemPath}.id must be 80 characters or fewer`);
    if (!/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(id)) {
      throw httpError(422, `${itemPath}.id must use only letters, numbers, dots, underscores, and hyphens`);
    }
    if (seenIds.has(id)) throw httpError(422, `${itemPath}.id duplicates "${id}"`);
    seenIds.add(id);

    if (!label) throw httpError(422, `${itemPath}.label is required`);
    if (label.length > 200) throw httpError(422, `${itemPath}.label must be 200 characters or fewer`);
    if (!description) throw httpError(422, `${itemPath}.description is required`);
    if (description.length > 2000) {
      throw httpError(422, `${itemPath}.description must be 2000 characters or fewer`);
    }

    return { id, label, description };
  });
}

async function updateReworkCriteria(body) {
  if (!body || typeof body !== "object" || Array.isArray(body)) {
    throw httpError(400, "Request body must be an object");
  }
  if (!Object.hasOwn(body, "reworkCriteria")) {
    throw httpError(400, "Request body must include reworkCriteria");
  }

  const reworkCriteria = validateReworkCriteria(body.reworkCriteria);
  const rubric = await readJson(criteriaPath, null);
  if (!rubric) throw httpError(404, "Job criteria SSOT was not found");
  if (!rubric.reworkContract || typeof rubric.reworkContract !== "object" || Array.isArray(rubric.reworkContract)) {
    throw httpError(409, "Job criteria SSOT does not contain a reworkContract object");
  }

  rubric.reworkContract.criteria = reworkCriteria;
  rubric.reworkContract.updatedAt = new Date().toISOString();
  await writeJsonAtomic(criteriaPath, rubric);
  return rubric;
}

async function updateSlide(slideNumber, patch) {
  const allowedStatuses = new Set(["unreviewed", "keep", "rework", "uncertain"]);
  if (patch.status !== undefined && !allowedStatuses.has(patch.status)) {
    throw new Error("Invalid status");
  }
  const decisions = await readJson(decisionsPath);
  const item = decisions.slides.find((slide) => slide.slide === slideNumber);
  if (!item) throw new Error("Unknown slide");
  if (patch.status !== undefined) item.status = patch.status;
  if (patch.reason !== undefined) item.reason = String(patch.reason).slice(0, 1000);
  item.source = "human";
  item.updatedAt = new Date().toISOString();
  decisions.finalizedAt = null;
  await writeJsonAtomic(decisionsPath, decisions);
  return item;
}

async function applySuggestions(slideNumbers) {
  const requested = new Set(slideNumbers.map(Number));
  const decisions = await readJson(decisionsPath);
  for (const item of decisions.slides) {
    if (requested.has(item.slide) && item.status === "unreviewed") {
      item.status = item.autoStatus || item.suggestion;
      item.reason = item.autoReason || "";
      item.source = item.autoSource || "auto_heuristic";
      item.updatedAt = new Date().toISOString();
    }
  }
  decisions.finalizedAt = null;
  await writeJsonAtomic(decisionsPath, decisions);
  return decisions;
}

async function finalizeTriage() {
  const decisions = await readJson(decisionsPath);
  const unreviewed = decisions.slides.filter((slide) => slide.status === "unreviewed");
  if (unreviewed.length) {
    return { ok: false, unreviewed: unreviewed.map((slide) => slide.slide) };
  }
  decisions.finalizedAt = new Date().toISOString();
  await writeJsonAtomic(decisionsPath, decisions);
  const project = await readJson(projectPath);
  project.phase = "style";
  project.triageFinalizedAt = decisions.finalizedAt;
  await writeJsonAtomic(projectPath, project);
  return { ok: true, finalizedAt: decisions.finalizedAt };
}

const server = http.createServer(async (request, response) => {
  try {
    const url = new URL(request.url, `http://${request.headers.host || "127.0.0.1"}`);

    if (request.method === "GET" && url.pathname === "/api/bootstrap") {
      sendJson(response, 200, await bootstrap());
      return;
    }

    if (request.method === "PUT" && url.pathname === "/api/criteria") {
      const rubric = await updateReworkCriteria(await readBody(request));
      sendJson(response, 200, { rubric });
      return;
    }

    const slideMatch = url.pathname.match(/^\/api\/slides\/(\d+)$/);
    if (request.method === "PATCH" && slideMatch) {
      sendJson(response, 200, await updateSlide(Number(slideMatch[1]), await readBody(request)));
      return;
    }

    if (request.method === "POST" && url.pathname === "/api/triage/apply-suggestions") {
      const body = await readBody(request);
      const decisions = await applySuggestions(Array.isArray(body.slides) ? body.slides : []);
      sendJson(response, 200, { ok: true, decisions });
      return;
    }

    if (request.method === "POST" && url.pathname === "/api/triage/finalize") {
      const result = await finalizeTriage();
      sendJson(response, result.ok ? 200 : 409, result);
      return;
    }

    const reworkReviewMatch = url.pathname.match(/^\/api\/rework\/slides\/(\d+)\/versions\/(\d+)\/review$/);
    if (request.method === "POST" && reworkReviewMatch) {
      const result = await updateReworkReview(
        Number(reworkReviewMatch[1]),
        Number(reworkReviewMatch[2]),
        await readBody(request),
      );
      sendJson(response, 200, result);
      return;
    }

    if (request.method === "POST" && url.pathname === "/api/style") {
      const body = await readBody(request);
      const hex = String(body.primary || "").toUpperCase();
      if (!/^#[0-9A-F]{6}$/.test(hex)) throw new Error("Primary color must be a 6-digit hex value");
      const style = {
        schemaVersion: 1,
        primary: hex,
        background: String(body.background || "#FFFFFF").toUpperCase(),
        text: String(body.text || "#17212B").toUpperCase(),
        muted: String(body.muted || "#667085").toUpperCase(),
        confirmed: Boolean(body.confirmed),
        updatedAt: new Date().toISOString(),
      };
      await writeJsonAtomic(stylePath, style);
      sendJson(response, 200, style);
      return;
    }

    if (request.method === "POST" && url.pathname === "/api/_shutdown") {
      if (!shutdownToken || request.headers["x-shutdown-token"] !== shutdownToken) {
        sendText(response, 404, "Not found");
        return;
      }
      sendJson(response, 200, { ok: true });
      setImmediate(() => shutdown("authenticated-request"));
      return;
    }

    if (request.method === "GET" && url.pathname.startsWith("/job/")) {
      const relative = decodeURIComponent(url.pathname.slice("/job/".length));
      const resolved = path.resolve(jobRoot, relative);
      if (!resolved.startsWith(`${jobRoot}${path.sep}`)) {
        sendText(response, 403, "Forbidden");
        return;
      }
      streamFile(response, resolved);
      return;
    }

    const relativePublic = url.pathname === "/" ? "index.html" : url.pathname.slice(1);
    const publicPath = path.resolve(publicDir, relativePublic);
    if (!publicPath.startsWith(`${publicDir}${path.sep}`) && publicPath !== path.join(publicDir, "index.html")) {
      sendText(response, 403, "Forbidden");
      return;
    }
    streamFile(response, publicPath);
  } catch (error) {
    const statusCode = Number.isInteger(error.statusCode) ? error.statusCode : 500;
    if (statusCode >= 500) console.error(error);
    sendJson(response, statusCode, { error: error.message });
  }
});

server.listen(port, "127.0.0.1", () => {
  console.log(`StartedPID=${process.pid}; Role=ppt-review-server; Lifecycle=resident; ReuseUntil=launcher-window-close-or-QA-complete; ShutdownTrigger=owner-exit-or-SIGINT`);
  console.log(`PPT review dashboard: http://127.0.0.1:${port}`);
  console.log(`Job: ${jobRoot}`);
  if (ownerPid > 0) {
    ownerWatch = setInterval(() => {
      try {
        process.kill(ownerPid, 0);
      } catch {
        shutdown("owner-exited");
      }
    }, 1000);
    ownerWatch.unref();
  }
});

function shutdown(signal) {
  if (shuttingDown) return;
  shuttingDown = true;
  if (ownerWatch) clearInterval(ownerWatch);
  console.log(`\nStopping review dashboard (${signal})...`);
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(1), 3000).unref();
}

process.on("SIGINT", () => shutdown("SIGINT"));
process.on("SIGTERM", () => shutdown("SIGTERM"));
