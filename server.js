/*
 * SignPilot AI - tiny zero-dependency Node server.
 * Local-first e-signature / approval documents for trades.
 * Serves the single-page app and a small JSON API for document
 * creation, sending, signing, and audit trails.
 *
 * Everything works with NO API key and NO network services.
 * Signatures are drawn in the browser and stored locally.
 */
"use strict";

const http = require("http");
const fs = require("fs");
const path = require("path");

const Templates = require("./public/templates.js");

const PORT = Number(process.env.PORT) || 3000;
const ROOT = path.join(__dirname, "public");
const DATA_DIR = path.join(__dirname, "data");
const DATA_FILE = path.join(DATA_DIR, "documents.json");

const MIME = {
  ".html": "text/html; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".js": "application/javascript; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".svg": "image/svg+xml",
  ".ico": "image/x-icon"
};

/* ---------- storage ---------- */
function ensureDataDir() {
  if (!fs.existsSync(DATA_DIR)) fs.mkdirSync(DATA_DIR, { recursive: true });
  if (!fs.existsSync(DATA_FILE)) fs.writeFileSync(DATA_FILE, "[]", "utf8");
}

function readDocs() {
  ensureDataDir();
  try {
    const raw = fs.readFileSync(DATA_FILE, "utf8");
    const arr = JSON.parse(raw);
    return Array.isArray(arr) ? arr : [];
  } catch (e) {
    return [];
  }
}

function writeDocs(docs) {
  ensureDataDir();
  const tmp = DATA_FILE + ".tmp";
  fs.writeFileSync(tmp, JSON.stringify(docs, null, 2), "utf8");
  fs.renameSync(tmp, DATA_FILE);
}

function nextNumber(docs) {
  const year = new Date().getFullYear();
  let n = 0;
  docs.forEach((d) => {
    const m = /^SP-(\d{4})-(\d{4})$/.exec(d.number || "");
    if (m && Number(m[1]) === year) n = Math.max(n, Number(m[2]));
  });
  return "SP-" + year + "-" + String(n + 1).padStart(4, "0");
}

function nowISO() {
  return new Date().toISOString();
}

function audit(doc, event, detail) {
  doc.audit.push({ ts: nowISO(), event, detail: detail || "" });
}

function newId() {
  return (
    Date.now().toString(36) + Math.random().toString(36).slice(2, 8)
  );
}

/* ---------- http helpers ---------- */
function sendJSON(res, code, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(code, { "Content-Type": "application/json; charset=utf-8" });
  res.end(body);
}

function sendText(res, code, text, type) {
  res.writeHead(code, { "Content-Type": type || "text/plain; charset=utf-8" });
  res.end(text);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let chunks = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => {
      const raw = Buffer.concat(chunks).toString("utf8");
      if (!raw) return resolve({});
      try {
        resolve(JSON.parse(raw));
      } catch (e) {
        reject(new Error("invalid JSON body"));
      }
    });
    req.on("error", reject);
  });
}

function serveStatic(req, res, pathname) {
  let rel = decodeURIComponent(pathname);
  if (rel === "/") rel = "/index.html";
  const safe = path.normalize(rel).replace(/^(\.\.[/\\])+/, "");
  const file = path.join(ROOT, safe);
  if (!file.startsWith(ROOT)) return sendText(res, 403, "forbidden");
  fs.readFile(file, (err, data) => {
    if (err) return sendText(res, 404, "not found");
    const ext = path.extname(file).toLowerCase();
    res.writeHead(200, { "Content-Type": MIME[ext] || "application/octet-stream" });
    res.end(data);
  });
}

/* ---------- router ---------- */
async function handle(req, res) {
  const url = new URL(req.url, "http://localhost");
  const p = url.pathname;
  const m = req.method;

  if (m === "GET" && p === "/api/health") {
    return sendJSON(res, 200, { ok: true, service: "signpilot-ai", openai: false });
  }

  if (m === "GET" && p === "/api/templates") {
    const list = Object.values(Templates.TEMPLATES).map((t) => ({
      id: t.id,
      name: t.name,
      blurb: t.blurb,
      fields: t.fields
    }));
    return sendJSON(res, 200, { templates: list });
  }

  // CSV export of the document ledger (signature blobs omitted)
  if (m === "GET" && p === "/api/documents/export.csv") {
    const docs = readDocs();
    const cell = (v) => '"' + String(v == null ? "" : v).replace(/"/g, '""') + '"';
    const signer = (d, role) => {
      const s = d.signatures.find((x) => x.role === role);
      return s ? s.name + " (" + s.signedAt.slice(0, 10) + ")" : "";
    };
    const rows = [
      ["number", "title", "template", "status", "client", "created", "sent", "signed", "clientSigner", "contractorSigner"]
    ].concat(docs.map((d) => [
      d.number, d.title, d.template, d.status, (d.fields || {}).clientName || "",
      (d.createdAt || "").slice(0, 10), (d.sentAt || "").slice(0, 10),
      (d.signedAt || "").slice(0, 10), signer(d, "client"), signer(d, "contractor")
    ]));
    const body = rows.map((r) => r.map(cell).join(",")).join("\r\n");
    res.writeHead(200, {
      "Content-Type": "text/csv; charset=utf-8",
      "Content-Disposition": 'attachment; filename="signpilot-documents.csv"'
    });
    return res.end("\uFEFF" + body);
  }

  // document collection
  if (p === "/api/documents") {
    if (m === "GET") {
      const docs = readDocs().map((d) => ({
        id: d.id, number: d.number, template: d.template, title: d.title,
        status: d.status, createdAt: d.createdAt, sentAt: d.sentAt,
        signedAt: d.signedAt, fields: d.fields || {},
        signatures: d.signatures.map((s) => ({ role: s.role, name: s.name, signedAt: s.signedAt }))
      }));
      return sendJSON(res, 200, { documents: docs });
    }
    if (m === "POST") {
      const body = await readBody(req);
      const errs = Templates.validateFields(body.template, body.fields);
      if (errs.length) return sendJSON(res, 400, { ok: false, errors: errs });
      const docs = readDocs();
      const doc = {
        id: newId(),
        number: nextNumber(docs),
        template: body.template,
        title: body.title || Templates.TEMPLATES[body.template].name,
        fields: body.fields || {},
        status: "draft",
        createdAt: nowISO(),
        sentAt: null,
        signedAt: null,
        signatures: [],
        audit: []
      };
      audit(doc, "created", "Document created as draft.");
      docs.push(doc);
      writeDocs(docs);
      return sendJSON(res, 201, { ok: true, document: doc });
    }
  }

  // single document / sub-resources
  const dm = /^\/api\/documents\/([^/]+)(\/(sign|audit|duplicate))?$/.exec(p);
  if (dm) {
    const id = dm[1];
    const sub = dm[3] || null;
    const docs = readDocs();
    const doc = docs.find((d) => d.id === id);
    if (!doc) return sendJSON(res, 404, { ok: false, error: "document not found" });

    if (m === "GET" && !sub) return sendJSON(res, 200, { document: doc });

    // duplicate any document into a fresh draft (new id + number)
    if (m === "POST" && sub === "duplicate") {
      const copy = JSON.parse(JSON.stringify(doc));
      copy.id = newId();
      copy.number = nextNumber(docs);
      copy.title = doc.title + " (copy)";
      copy.status = "draft";
      copy.sentAt = null;
      copy.signedAt = null;
      copy.signatures = [];
      copy.createdAt = nowISO();
      copy.audit = [];
      audit(copy, "created", "Draft duplicated from " + doc.number + ".");
      docs.push(copy);
      writeDocs(docs);
      return sendJSON(res, 201, { ok: true, document: copy });
    }

    // delete is draft-only: sent/signed documents are records and must stay
    if (m === "DELETE" && !sub) {
      if (doc.status !== "draft") {
        return sendJSON(res, 400, {
          ok: false,
          error: "only draft documents can be deleted (status: " + doc.status + ")"
        });
      }
      const rest = docs.filter((d) => d.id !== id);
      writeDocs(rest);
      return sendJSON(res, 200, { ok: true, deleted: id });
    }

    if (m === "GET" && sub === "audit") {
      return sendJSON(res, 200, { id: doc.id, number: doc.number, audit: doc.audit });
    }

    if (m === "PATCH" && !sub) {
      const body = await readBody(req);
      const to = body.status;
      const okTrans =
        (doc.status === "draft" && to === "sent") ||
        (doc.status === "sent" && to === "draft");
      if (!okTrans) {
        return sendJSON(res, 400, {
          ok: false,
          error: "invalid transition: " + doc.status + " -> " + to
        });
      }
      doc.status = to;
      if (to === "sent") {
        doc.sentAt = nowISO();
        audit(doc, "sent", "Document marked sent — ready for signatures.");
      } else {
        doc.sentAt = null;
        audit(doc, "recalled", "Document returned to draft.");
      }
      writeDocs(docs);
      return sendJSON(res, 200, { ok: true, document: doc });
    }

    if (m === "POST" && sub === "sign") {
      const body = await readBody(req);
      if (doc.status !== "sent") {
        return sendJSON(res, 400, { ok: false, error: "document must be sent before signing" });
      }
      const role = body.role;
      if (role !== "client" && role !== "contractor") {
        return sendJSON(res, 400, { ok: false, error: "role must be client or contractor" });
      }
      const name = String(body.name || "").trim();
      const sig = String(body.signature || "");
      if (!name) return sendJSON(res, 400, { ok: false, error: "signer name required" });
      if (!/^data:image\/png;base64,/.test(sig)) {
        return sendJSON(res, 400, { ok: false, error: "signature must be a PNG data URL" });
      }
      const ts = nowISO();
      const existing = doc.signatures.find((s) => s.role === role);
      const entry = {
        role,
        name,
        signature: sig,
        signedAt: ts,
        note: "Signature captured in this browser (SignPilot AI, local)."
      };
      if (existing) Object.assign(existing, entry);
      else doc.signatures.push(entry);
      audit(doc, "signed", role + " signature captured for " + name + ".");
      const roles = doc.signatures.map((s) => s.role);
      if (roles.includes("client") && roles.includes("contractor") && doc.status !== "signed") {
        doc.status = "signed";
        doc.signedAt = ts;
        audit(doc, "completed", "Both parties signed — document is fully executed.");
      }
      writeDocs(docs);
      return sendJSON(res, 200, { ok: true, document: doc });
    }
  }

  if (p.startsWith("/api/")) return sendJSON(res, 404, { ok: false, error: "unknown endpoint" });
  return serveStatic(req, res, p);
}

const server = http.createServer((req, res) => {
  handle(req, res).catch((e) => {
    sendJSON(res, 500, { ok: false, error: e.message || "server error" });
  });
});

server.listen(PORT, () => {
  console.log("SignPilot AI listening on port " + PORT);
});
