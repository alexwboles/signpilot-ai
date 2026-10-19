/* Test stub: fake quotely-ai callback receiver for signpilot-ai tests. NOT shipped. */
"use strict";
const http = require("http");
const port = Number(process.argv[2] || 3497);
const calls = [];
const server = http.createServer((req, res) => {
  const u = new URL(req.url, "http://x");
  let body = "";
  req.on("data", c => { body += c; });
  req.on("end", () => {
    res.setHeader("Content-Type", "application/json");
    const send = (code, obj) => { res.writeHead(code); res.end(JSON.stringify(obj)); };
    const m = /^\/api\/quotes\/([^/]+)\/signpilot-callback$/.exec(u.pathname);
    if (req.method === "POST" && m) {
      let j = {};
      try { j = JSON.parse(body || "{}"); } catch (e) { return send(400, { error: "bad json" }); }
      calls.push({ quoteId: m[1], body: j });
      return send(200, { ok: true, quote: m[1], purpose: j.purpose, status: j.status });
    }
    if (req.method === "GET" && u.pathname === "/stub/calls") {
      return send(200, { calls });
    }
    return send(404, {});
  });
});
server.listen(port, () => console.log("stub quotely-callback on " + port));
