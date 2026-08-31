// The plan review server.
//
// One file, no dependencies. Neovim starts it, and it serves the design doc
// that flow.planner wrote to disk. You comment on the doc in the browser. When
// you press Replan or Accept, this calls back into the same Neovim through
// --remote-expr, the way ~/.claude/hooks/nvim-follow.sh does.
//
//   node server.js --root <flow state root> [--port 0] [--watch-stdin]
//
// It prints one line on startup:  FLOW_READY <port> <token>
// Every /api route needs that token. It binds to 127.0.0.1 only.

"use strict";

const http = require("http");
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");
const { execFile } = require("child_process");

const args = process.argv.slice(2);
function arg(name, fallback) {
  const i = args.indexOf("--" + name);
  return i >= 0 && args[i + 1] !== undefined ? args[i + 1] : fallback;
}

const ROOT = arg("root", "");
const PORT = Number(arg("port", "0"));
const TOKEN = arg("token", crypto.randomBytes(16).toString("hex"));
const NVIM = process.env.FLOW_NVIM_SERVER || "";
const APP = path.join(__dirname, "app.html");

if (!ROOT) {
  console.error("flow: --root is required");
  process.exit(2);
}

// --- disk -------------------------------------------------------------------

function readJson(file) {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch {
    return null;
  }
}

function writeJson(file, data) {
  try {
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, JSON.stringify(data));
    return true;
  } catch {
    return false;
  }
}

function dirs(where) {
  try {
    return fs
      .readdirSync(where, { withFileTypes: true })
      .filter((e) => e.isDirectory())
      .map((e) => e.name);
  } catch {
    return [];
  }
}

// A plan id is unique across projects, so find it wherever it lives.
function planDir(planId) {
  if (!/^[\w-]+$/.test(planId)) return null;
  for (const project of dirs(ROOT)) {
    const dir = path.join(ROOT, project, planId);
    if (fs.existsSync(path.join(dir, "meta.json"))) return dir;
  }
  return null;
}

function revision(dir, n) {
  const file = path.join(dir, "revisions", String(n).padStart(3, "0") + ".json");
  return readJson(file);
}

function comments(dir) {
  const list = readJson(path.join(dir, "comments.json"));
  return Array.isArray(list) ? list : [];
}

// The whole state one page needs, in one response.
function planPayload(planId, wanted) {
  const dir = planDir(planId);
  if (!dir) return null;
  const meta = readJson(path.join(dir, "meta.json"));
  if (!meta) return null;

  const current = meta.current_revision || 0;
  const n = wanted ? Math.max(1, Math.min(Number(wanted), current)) : current;
  const revisions = [];
  for (let i = 1; i <= current; i += 1) {
    const r = revision(dir, i);
    if (r) revisions.push({ n: i, created: r.created, cost: r.cost });
  }

  return {
    meta,
    revision: n > 0 ? revision(dir, n) : null,
    revisions,
    comments: comments(dir),
    steps: readJson(path.join(dir, "steps.json")) || [],
  };
}

// --- calling Neovim back ----------------------------------------------------

// The same transport the Claude follow hook uses: base64 JSON through
// --remote-expr, so nothing has to be escaped for a shell.
function tellNvim(payload, done) {
  if (!NVIM) {
    done(new Error("no Neovim server address"));
    return;
  }
  const encoded = Buffer.from(JSON.stringify(payload), "utf8").toString("base64");
  const expr = "v:lua.require'flow.bridge'.handle('" + encoded + "')";
  execFile("nvim", ["--server", NVIM, "--remote-expr", expr], { timeout: 10000 }, (err) => {
    done(err || null);
  });
}

// --- http -------------------------------------------------------------------

function send(res, code, body, type) {
  res.writeHead(code, {
    "Content-Type": type || "application/json; charset=utf-8",
    "Cache-Control": "no-store",
  });
  res.end(body);
}

function sendJson(res, code, data) {
  send(res, code, JSON.stringify(data));
}

function readBody(req, done) {
  let raw = "";
  req.on("data", (chunk) => {
    raw += chunk;
    if (raw.length > 1e6) req.destroy();
  });
  req.on("end", () => {
    try {
      done(raw ? JSON.parse(raw) : {});
    } catch {
      done(null);
    }
  });
}

const server = http.createServer((req, res) => {
  let url;
  try {
    url = new URL(req.url, "http://127.0.0.1");
  } catch {
    return send(res, 400, "bad request", "text/plain");
  }
  const parts = url.pathname.split("/").filter(Boolean);

  // The page itself. The token rides in the query string.
  if (req.method === "GET" && parts[0] === "plan" && parts[1]) {
    try {
      return send(res, 200, fs.readFileSync(APP, "utf8"), "text/html; charset=utf-8");
    } catch {
      return send(res, 500, "app.html is missing", "text/plain");
    }
  }

  if (parts[0] !== "api") {
    return send(res, 404, "not found", "text/plain");
  }

  // Everything below touches state, so it needs the token.
  const given = url.searchParams.get("token") || req.headers["x-flow-token"];
  if (given !== TOKEN) {
    return sendJson(res, 403, { error: "bad token" });
  }

  const planId = parts[2];
  if (parts[1] !== "plan" || !planId) {
    return sendJson(res, 404, { error: "not found" });
  }
  const dir = planDir(planId);
  if (!dir) {
    return sendJson(res, 404, { error: "no such plan" });
  }
  const action = parts[3];

  if (req.method === "GET" && !action) {
    return sendJson(res, 200, planPayload(planId, url.searchParams.get("revision")));
  }

  if (req.method === "GET" && action === "revision" && parts[4]) {
    const payload = planPayload(planId, parts[4]);
    return payload ? sendJson(res, 200, payload) : sendJson(res, 404, { error: "no such revision" });
  }

  if (req.method === "POST" && action === "comment") {
    return readBody(req, (body) => {
      if (!body || typeof body.body !== "string" || !body.body.trim()) {
        return sendJson(res, 400, { error: "a comment needs a body" });
      }
      const meta = readJson(path.join(dir, "meta.json")) || {};
      const entry = {
        id: "c" + Date.now().toString(36) + crypto.randomBytes(2).toString("hex"),
        anchor: String(body.anchor || "the document").slice(0, 200),
        quote: String(body.quote || "").slice(0, 2000),
        body: body.body.trim().slice(0, 8000),
        revision: Number(body.revision) || meta.current_revision || 0,
        created: Math.floor(Date.now() / 1000),
        addressed_in: null,
      };
      const list = comments(dir);
      list.push(entry);
      if (!writeJson(path.join(dir, "comments.json"), list)) {
        return sendJson(res, 500, { error: "could not write the comment" });
      }
      return sendJson(res, 200, { comment: entry });
    });
  }

  if (req.method === "DELETE" && action === "comment" && parts[4]) {
    const list = comments(dir);
    const kept = list.filter((c) => c.id !== parts[4]);
    if (kept.length === list.length) {
      return sendJson(res, 404, { error: "no such comment" });
    }
    writeJson(path.join(dir, "comments.json"), kept);
    return sendJson(res, 200, { removed: parts[4] });
  }

  if (req.method === "POST" && (action === "replan" || action === "accept")) {
    return tellNvim({ action, plan_id: planId }, (err) => {
      if (err) {
        return sendJson(res, 502, { error: "Neovim did not answer: " + err.message });
      }
      return sendJson(res, 200, { ok: true, action });
    });
  }

  return sendJson(res, 404, { error: "not found" });
});

server.listen(PORT, "127.0.0.1", () => {
  process.stdout.write("FLOW_READY " + server.address().port + " " + TOKEN + "\n");
});

// Neovim holds a pipe to our stdin, and closing it means Neovim is gone. Do
// not outlive it. This is opt-in, because a shell that starts the server in the
// background hands it a stdin that is already at end of file.
if (args.includes("--watch-stdin")) {
  process.stdin.on("end", () => process.exit(0));
  process.stdin.resume();
}
