/* SignPilot AI front-end. No build step, no API keys. */
(function () {
  "use strict";
  var T = window.SignPilotTemplates;

  function api(path, opts) {
    opts = opts || {};
    return fetch(path, {
      method: opts.method || "GET",
      headers: { "Content-Type": "application/json" },
      body: opts.body ? JSON.stringify(opts.body) : undefined
    }).then(function (r) {
      return r.json().then(function (j) {
        if (!r.ok) throw new Error((j && (j.error || (j.errors || []).join("; "))) || "request failed");
        return j;
      });
    });
  }

  function esc(s) {
    return String(s == null ? "" : s).replace(/[&<>"']/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c];
    });
  }

  function show(id) {
    ["view-list", "view-edit", "view-doc", "view-sign"].forEach(function (v) {
      document.getElementById(v).classList.toggle("hidden", v !== id);
    });
  }

  /* ---------- signature pad (hand-rolled, no libraries) ---------- */
  function makePad(canvas) {
    var ctx = canvas.getContext("2d");
    var drawing = false, drawn = false, last = null;
    function pos(e) {
      var r = canvas.getBoundingClientRect();
      var x = (e.clientX - r.left) * (canvas.width / r.width);
      var y = (e.clientY - r.top) * (canvas.height / r.height);
      return { x: x, y: y };
    }
    function setup() {
      var dpr = window.devicePixelRatio || 1;
      var w = 600, h = 200;
      canvas.width = w * dpr; canvas.height = h * dpr;
      ctx.scale(dpr, dpr);
      ctx.lineWidth = 2.5; ctx.lineCap = "round"; ctx.lineJoin = "round";
      ctx.strokeStyle = "#111827";
    }
    setup();
    canvas.addEventListener("pointerdown", function (e) {
      drawing = true; drawn = true; last = pos(e);
      canvas.setPointerCapture(e.pointerId);
      e.preventDefault();
    });
    canvas.addEventListener("pointermove", function (e) {
      if (!drawing) return;
      var p = pos(e);
      ctx.beginPath(); ctx.moveTo(last.x, last.y); ctx.lineTo(p.x, p.y); ctx.stroke();
      last = p;
      e.preventDefault();
    });
    function stop() { drawing = false; last = null; }
    canvas.addEventListener("pointerup", stop);
    canvas.addEventListener("pointercancel", stop);
    return {
      clear: function () { ctx.clearRect(0, 0, canvas.width, canvas.height); drawn = false; },
      isEmpty: function () { return !drawn; },
      toDataURL: function () {
        var c = document.createElement("canvas");
        c.width = 600; c.height = 200;
        var c2 = c.getContext("2d");
        c2.fillStyle = "#ffffff"; c2.fillRect(0, 0, 600, 200);
        c2.drawImage(canvas, 0, 0, 600, 200);
        return c.toDataURL("image/png");
      }
    };
  }
  var pad = makePad(document.getElementById("sigpad"));

  /* ---------- list ---------- */
  function renderList() {
    show("view-list");
    api("/api/documents").then(function (j) {
      var el = document.getElementById("doc-list");
      if (!j.documents.length) {
        el.innerHTML = '<p class="muted">No documents yet. <a href="#/new">Create your first approval</a>.</p>';
        return;
      }
      el.innerHTML = j.documents.map(function (d) {
        return '<div class="card"><h3><a href="#/doc/' + d.id + '">' + esc(d.title) + "</a></h3>" +
          '<div class="muted">' + esc(d.number) + " · " + esc(d.id && d.template) + "</div>" +
          '<div style="margin-top:10px"><span class="pill ' + d.status + '">' + d.status + "</span></div>" +
          '<div class="muted" style="margin-top:6px;font-size:.82rem">created ' + esc(d.createdAt.slice(0, 10)) + "</div></div>";
      }).join("");
    }).catch(function (e) {
      document.getElementById("doc-list").innerHTML = '<p class="muted">Error: ' + esc(e.message) + "</p>";
    });
  }

  /* ---------- editor ---------- */
  function fieldInput(fd) {
    var val = fd.def ? ' value="' + esc(fd.def) + '"' : "";
    var ph = fd.placeholder ? ' placeholder="' + esc(fd.placeholder) + '"' : "";
    var req = fd.required ? " required" : "";
    if (fd.type === "textarea") {
      return '<label>' + esc(fd.label) + '<textarea data-key="' + fd.key + '"' + ph + req + "></textarea></label>";
    }
    if (fd.type === "date") {
      return '<label>' + esc(fd.label) + '<input type="date" data-key="' + fd.key + '" value="' + T.todayISO() + '"' + req + "></label>";
    }
    return '<label>' + esc(fd.label) + '<input type="' + fd.type + '" data-key="' + fd.key + '"' + val + ph + req + "></label>";
  }

  function renderEdit() {
    show("view-edit");
    var sel = document.getElementById("f-template");
    sel.innerHTML = Object.values(T.TEMPLATES).map(function (t) {
      return '<option value="' + t.id + '">' + esc(t.name) + "</option>";
    }).join("");
    function drawFields() {
      var t = T.TEMPLATES[sel.value];
      document.getElementById("template-blurb").textContent = t.blurb;
      document.getElementById("template-fields").innerHTML = t.fields.map(fieldInput).join("");
    }
    sel.onchange = drawFields;
    drawFields();
    document.getElementById("edit-msg").textContent = "";
  }

  document.getElementById("btn-save-doc").addEventListener("click", function () {
    var tid = document.getElementById("f-template").value;
    var fields = {};
    document.querySelectorAll("#template-fields [data-key]").forEach(function (el) {
      fields[el.getAttribute("data-key")] = el.value;
    });
    var title = document.getElementById("f-title").value.trim() ||
      T.TEMPLATES[tid].name + " — " + (fields.clientName || "untitled");
    api("/api/documents", { method: "POST", body: { template: tid, title: title, fields: fields } })
      .then(function (j) { location.hash = "#/doc/" + j.document.id; })
      .catch(function (e) { document.getElementById("edit-msg").textContent = "Error: " + e.message; });
  });

  /* ---------- detail ---------- */
  function sigBlock(doc, role, label) {
    var s = doc.signatures.find(function (x) { return x.role === role; });
    if (!s) return '<div class="sig-block"><strong>' + label + ":</strong> <span class='muted'>not yet signed</span></div>";
    return '<div class="sig-block"><strong>' + label + ":</strong> " + esc(s.name) +
      ' <span class="muted">(' + esc(s.signedAt.slice(0, 16).replace("T", " ")) + ")</span><br>" +
      '<img src="' + s.signature + '" alt="signature"></div>';
  }

  function renderDoc(id) {
    show("view-doc");
    api("/api/documents/" + id).then(function (j) {
      var d = j.document;
      document.getElementById("doc-title").textContent = d.title;
      var pill = document.getElementById("doc-status");
      pill.className = "pill " + d.status;
      pill.textContent = d.status;
      var paras = T.renderBody(d.template, d.fields);
      document.getElementById("doc-body").innerHTML =
        '<p class="lead">' + esc(paras[0]) + "</p>" +
        paras.slice(1).map(function (p) { return "<p>" + esc(p) + "</p>"; }).join("") +
        '<p class="muted">Document ' + esc(d.number) + " · created " + esc(d.createdAt.slice(0, 10)) + "</p>" +
        sigBlock(d, "contractor", "Contractor") + sigBlock(d, "client", "Client");

      var actions = document.getElementById("doc-actions");
      actions.innerHTML = "";
      function btn(label, cls, fn) {
        var b = document.createElement("button");
        b.className = "btn " + cls; b.textContent = label;
        b.addEventListener("click", fn);
        actions.appendChild(b);
      }
      if (d.status === "draft") {
        btn("Mark as sent", "primary", function () {
          api("/api/documents/" + id, { method: "PATCH", body: { status: "sent" } })
            .then(function () { renderDoc(id); });
        });
      }
      if (d.status === "sent") {
        btn("Open signing view", "primary", function () { location.hash = "#/sign/" + id; });
        btn("Recall to draft", "ghost", function () {
          api("/api/documents/" + id, { method: "PATCH", body: { status: "draft" } })
            .then(function () { renderDoc(id); });
        });
      }
      var back = document.createElement("a");
      back.className = "btn ghost"; back.href = "#/"; back.textContent = "Back to documents";
      actions.appendChild(back);

      var sendBox = document.getElementById("send-box");
      if (d.status === "sent") {
        sendBox.classList.remove("hidden");
        document.getElementById("sign-link").value =
          location.origin + location.pathname + "#/sign/" + id;
      } else sendBox.classList.add("hidden");

      document.getElementById("pdf-box").classList.toggle("hidden", d.status !== "signed");

      api("/api/documents/" + id + "/audit").then(function (a) {
        document.getElementById("doc-audit").innerHTML = a.audit.map(function (e) {
          return "<li><time>" + esc(e.ts.slice(0, 16).replace("T", " ")) + "</time><strong>" +
            esc(e.event) + "</strong> — " + esc(e.detail) + "</li>";
        }).join("");
      });

      document.getElementById("btn-pdf").onclick = function () { exportPdf(d); };
    }).catch(function (e) {
      document.getElementById("doc-title").textContent = "Error: " + e.message;
    });
  }

  document.getElementById("btn-copy-link").addEventListener("click", function () {
    var i = document.getElementById("sign-link");
    i.select();
    if (navigator.clipboard) navigator.clipboard.writeText(i.value);
    else document.execCommand("copy");
  });

  /* ---------- signing ---------- */
  function renderSign(id) {
    show("view-sign");
    pad.clear();
    document.getElementById("sign-name").value = "";
    document.getElementById("sign-msg").textContent = "";
    api("/api/documents/" + id).then(function (j) {
      var d = j.document;
      if (d.status !== "sent") {
        document.getElementById("sign-msg").textContent =
          "This document is '" + d.status + "' — it must be sent before signing.";
      }
      document.getElementById("sign-title").textContent = d.title;
      var paras = T.renderBody(d.template, d.fields);
      document.getElementById("sign-body").innerHTML =
        '<p class="lead">' + esc(paras[0]) + "</p>" +
        paras.slice(1).map(function (p) { return "<p>" + esc(p) + "</p>"; }).join("");
      document.getElementById("btn-sign").onclick = function () {
        var name = document.getElementById("sign-name").value.trim();
        var role = document.getElementById("sign-role").value;
        var msg = document.getElementById("sign-msg");
        if (!name) { msg.textContent = "Please enter your printed name."; return; }
        if (pad.isEmpty()) { msg.textContent = "Please draw your signature first."; return; }
        api("/api/documents/" + id + "/sign", {
          method: "POST",
          body: { role: role, name: name, signature: pad.toDataURL() }
        }).then(function (r) {
          msg.textContent = "Signed! " +
            (r.document.status === "signed" ? "Both parties have signed — document complete." : "Signature recorded.");
          setTimeout(function () { location.hash = "#/doc/" + id; }, 1200);
        }).catch(function (e) { msg.textContent = "Error: " + e.message; });
      };
    }).catch(function (e) {
      document.getElementById("sign-msg").textContent = "Error: " + e.message;
    });
  }

  document.getElementById("btn-clear-sig").addEventListener("click", function () { pad.clear(); });

  /* ---------- signed PDF export (pdf-lib, MIT, vendored locally) ---------- */
  function wrapText(text, font, size, maxWidth) {
    var words = String(text).split(/\s+/), lines = [], line = "";
    words.forEach(function (w) {
      var t = line ? line + " " + w : w;
      if (font.widthOfTextAtSize(t, size) > maxWidth && line) { lines.push(line); line = w; }
      else line = t;
    });
    if (line) lines.push(line);
    return lines;
  }

  function exportPdf(d) {
    var msg = document.createElement("p");
    msg.className = "muted"; msg.textContent = "Generating PDF…";
    document.getElementById("pdf-box").appendChild(msg);
    var lib = window.PDFLib;
    if (!lib) { msg.textContent = "PDF library failed to load."; return; }
    (async function () {
      try {
        var PDFDocument = lib.PDFDocument, StandardFonts = lib.StandardFonts, rgb = lib.rgb;
        var pdf = await PDFDocument.create();
        var font = await pdf.embedFont(StandardFonts.Helvetica);
        var bold = await pdf.embedFont(StandardFonts.HelveticaBold);
        var W = 612, H = 792, M = 56;
        var page = pdf.addPage([W, H]);
        var y = H - M;
        function need(h) {
          if (y - h < M) { page = pdf.addPage([W, H]); y = H - M; }
        }
        function para(text, opts) {
          opts = opts || {};
          var size = opts.size || 11, f = opts.bold ? bold : font;
          var lines = wrapText(text, f, size, W - 2 * M);
          lines.forEach(function (ln) {
            need(size + 4);
            page.drawText(ln, { x: M, y: y, size: size, font: f, color: rgb(0.13, 0.15, 0.18) });
            y -= size + 4;
          });
          y -= 8;
        }
        para("SignPilot AI — " + d.title, { size: 18, bold: true });
        para("Document " + d.number + " · status: " + d.status.toUpperCase(), { size: 10 });
        y -= 6;
        T.renderBody(d.template, d.fields).forEach(function (p, i) {
          para(p, i === 0 ? { size: 14, bold: true } : {});
        });
        y -= 10;
        for (var si = 0; si < d.signatures.length; si++) {
          var s = d.signatures[si];
          need(150);
          para((s.role === "client" ? "Client" : "Contractor") + ": " + s.name +
            " — signed " + s.signedAt.slice(0, 16).replace("T", " "), { bold: true });
          try {
            var b64 = s.signature.replace(/^data:image\/png;base64,/, "");
            var img = await pdf.embedPng(b64);
            var iw = 220, ih = iw * (img.height / img.width);
            need(ih + 10);
            page.drawImage(img, { x: M, y: y - ih, width: iw, height: ih });
            y -= ih + 16;
          } catch (e) { para("[signature image could not be embedded]", { size: 9 }); }
        }
        y -= 6;
        para("Audit trail", { size: 13, bold: true });
        d.audit.forEach(function (e) {
          para(e.ts.slice(0, 16).replace("T", " ") + " — " + e.event + ": " + e.detail, { size: 9 });
        });
        para("Signatures captured locally in the signer's browser via SignPilot AI.", { size: 9 });
        var bytes = await pdf.save();
        var blob = new Blob([bytes], { type: "application/pdf" });
        var a = document.createElement("a");
        a.href = URL.createObjectURL(blob);
        a.download = d.number + "-signed.pdf";
        document.body.appendChild(a); a.click();
        setTimeout(function () { URL.revokeObjectURL(a.href); a.remove(); }, 500);
        msg.textContent = "PDF downloaded.";
      } catch (e) {
        msg.textContent = "PDF failed: " + e.message;
      }
    })();
  }

  /* ---------- router ---------- */
  function route() {
    var h = location.hash || "#/";
    var m;
    if (h === "#/" || h === "") renderList();
    else if (h === "#/new") renderEdit();
    else if ((m = /^#\/doc\/(.+)$/.exec(h))) renderDoc(m[1]);
    else if ((m = /^#\/sign\/(.+)$/.exec(h))) renderSign(m[1]);
    else renderList();
  }
  window.addEventListener("hashchange", route);
  route();
})();
