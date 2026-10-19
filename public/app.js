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

  function fmtTs(ts) {
    return esc(String(ts || "").slice(0, 16).replace("T", " "));
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
      ctx.strokeStyle = "#16382c";
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
      /* Render a typed name onto the pad in a script style, for signers
       * who can't draw (trackpads, accessibility). Counts as a signature. */
      stamp: function (text) {
        /* ctx is already scaled for devicePixelRatio by setup(): draw in
         * 600x200 CSS-pixel space like the pointer handlers do. */
        ctx.clearRect(0, 0, canvas.width, canvas.height);
        ctx.fillStyle = "#16382c";
        ctx.textAlign = "center"; ctx.textBaseline = "middle";
        var size = 64;
        ctx.font = "italic " + size + "px 'Segoe Script','Brush Script MT','Apple Chancery',cursive";
        while (ctx.measureText(text).width > 560 && size > 28) {
          size -= 4;
          ctx.font = "italic " + size + "px 'Segoe Script','Brush Script MT','Apple Chancery',cursive";
        }
        ctx.fillText(text, 300, 105);
        drawn = true;
      },
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

  /* ---------- document paper rendering (shared by list/edit/detail/sign) ---------- */
  function letterhead(d) {
    return '<div class="letterhead"><div class="lh-brand">SignPilot <span>AI</span> · Approval Document</div>' +
      '<div class="lh-num">' + esc(d.number) + "</div></div>";
  }

  function paperHtml(d, opts) {
    opts = opts || {};
    var fields = d.fields || {};
    var paras = T.renderBody(d.template, fields);
    var expiryHtml = "";
    if (d.template === "quote-approval" && d.status !== "signed" && !opts.preview) {
      var info = T.expiryInfo("quote-approval", d.createdAt, fields);
      if (info && info.daysLeft != null) {
        var msg = info.daysLeft < 0
          ? "This quote expired " + (-info.daysLeft) + " days ago (" + info.expiresOn + ")."
          : info.daysLeft === 0
            ? "This quote expires today (" + info.expiresOn + ")."
            : "This quote is valid until " + info.expiresOn + " — " + info.daysLeft + " days left.";
        expiryHtml = '<p class="notice' + (info.daysLeft <= 7 ? " warn" : "") + '">' + esc(msg) + "</p>";
      }
    }
    var declineNote = "";
    if (d.status === "declined") {
      declineNote = '<p class="notice warn"><strong>Declined' +
        (d.declinedAt ? " " + esc(d.declinedAt.slice(0, 10)) : "") + ".</strong>" +
        (d.declineReason ? " Reason: " + esc(d.declineReason) : " No reason given.") +
        " This is a permanent record — duplicate it to start over.</p>";
    }
    var sigs = "";
    if (!opts.preview) {
      sigs = sigBlock(d, "contractor", "Contractor") + sigBlock(d, "client", "Client");
    }
    return letterhead(d) + expiryHtml + declineNote +
      '<p class="lead">' + esc(paras[0]) + "</p>" +
      paras.slice(1).map(function (p) { return "<p>" + esc(p) + "</p>"; }).join("") +
      '<p class="muted">Document ' + esc(d.number) + " · created " + esc((d.createdAt || "").slice(0, 10)) + "</p>" +
      sigs;
  }

  function sigBlock(doc, role, label) {
    var s = doc.signatures.find(function (x) { return x.role === role; });
    if (!s) return '<div class="sig-block pending"><strong>' + label + ":</strong> " +
      '<div class="awaiting">Awaiting signature — signature line is open.</div></div>';
    return '<div class="sig-block"><span class="sealed-mark">SEALED</span><strong>' + label + ":</strong>" +
      '<div class="sig-name">' + esc(s.name) + "</div>" +
      '<div class="muted">signed ' + fmtTs(s.signedAt) + "</div>" +
      (s.hash ? '<div class="muted seal-hash" title="Tamper-evident seal: SHA-256 over the document snapshot and signature bytes. Any change to the document or signature invalidates it.">seal ' + esc(s.hash.slice(0, 16)) + "…</div>" : "") +
      '<img src="' + s.signature + '" alt="signature"></div>';
  }

  /* ---------- list ---------- */
  var allDocs = [];

  function expiryBadge(d) {
    if (d.template !== "quote-approval" || d.status === "signed") return "";
    var info = T.expiryInfo("quote-approval", d.createdAt, d.fields || {});
    if (!info || info.daysLeft == null) return "";
    var cls = info.daysLeft < 0 ? "exp-over" : (info.daysLeft <= 7 ? "exp-soon" : "exp-ok");
    var txt = info.daysLeft < 0 ? "expired " + (-info.daysLeft) + "d ago"
      : info.daysLeft === 0 ? "expires today" : "expires in " + info.daysLeft + "d";
    return '<span class="exp ' + cls + '">' + esc(txt) + "</span>";
  }

  /* Days a sent document has been waiting for signatures. */
  function waitingBadge(d) {
    if (d.status !== "sent" || !d.sentAt) return "";
    var days = Math.max(0, Math.floor((Date.now() - new Date(d.sentAt).getTime()) / 86400000));
    var txt = days === 0 ? "sent today" : "waiting " + days + "d";
    var cls = days >= 7 ? "wait-late" : "wait";
    return '<span class="exp ' + cls + '">' + esc(txt) + "</span>";
  }

  function cardHtml(d) {
    var sigs = d.signatures || [];
    function dot(role, label) {
      var s = sigs.find(function (x) { return x.role === role; });
      var init = s ? esc(s.name.trim().charAt(0).toUpperCase() || "?") : "";
      return '<span class="sigdot' + (s ? " done" : "") + '" title="' + label + ": " +
        (s ? esc(s.name) : "awaiting") + '">' + (s ? init : label.charAt(0)) + "</span>";
    }
    return '<a class="env-row status-' + d.status + '" href="#/doc/' + d.id + '">' +
      '<span class="env-title">' + esc(d.title) +
        '<span class="docnum">' + esc(d.number) + " · " + esc(tplName(d.template)) + "</span></span>" +
      '<span class="sigprog">' + dot("contractor", "Contractor") + dot("client", "Client") +
        '<span class="role">' + sigs.length + "/2 signed</span></span>" +
      '<span class="env-meta"><span class="pill ' + d.status + '">' + d.status + "</span>" +
        expiryBadge(d) + waitingBadge(d) + "</span>" +
      '<span class="env-when">' + esc((d.createdAt || "").slice(0, 10)) + "</span>" +
      '<span class="chev" aria-hidden="true">›</span></a>';
  }

  function tplName(tid) {
    var t = T.TEMPLATES[tid];
    return t ? t.name : tid;
  }

  function needsAttention(d) {
    if (d.status === "declined") return true;
    if (d.status === "sent" && d.sentAt) {
      var days = Math.floor((Date.now() - new Date(d.sentAt).getTime()) / 86400000);
      if (days >= 7) return true;
    }
    return false;
  }

  var tabFilter = "";
  document.querySelectorAll(".seg-btn").forEach(function (b) {
    b.addEventListener("click", function () {
      setTabFilter(b.getAttribute("data-f"));
    });
  });

  function setTabFilter(f) {
    document.querySelectorAll(".seg-btn").forEach(function (x) {
      x.classList.toggle("active", x.getAttribute("data-f") === f);
    });
    tabFilter = f;
    applyListFilter();
  }

  /* The stat strip doubles as filter shortcuts. */
  document.querySelectorAll(".stat").forEach(function (s) {
    s.addEventListener("click", function () { setTabFilter(s.getAttribute("data-f")); });
  });

  function countBy(docs, fn) {
    return docs.filter(fn).length;
  }

  function applyListFilter() {
    var q = document.getElementById("doc-search").value.trim().toLowerCase();
    var counts = { all: allDocs.length, attention: 0, draft: 0, sent: 0, signed: 0 };
    allDocs.forEach(function (d) {
      if (needsAttention(d)) counts.attention++;
      if (counts[d.status] != null) counts[d.status]++;
    });
    ["all", "attention", "draft", "sent", "signed"].forEach(function (k) {
      var e = document.getElementById("cnt-" + k);
      if (e) e.textContent = counts[k];
    });
    document.getElementById("stat-attention").textContent = counts.attention;
    document.getElementById("stat-sent").textContent = counts.sent;
    document.getElementById("stat-signed").textContent = counts.signed;
    var list = allDocs.filter(function (d) {
      if (tabFilter === "attention" && !needsAttention(d)) return false;
      if (tabFilter && tabFilter !== "attention" && d.status !== tabFilter) return false;
      if (!q) return true;
      var hay = (d.title + " " + d.number + " " + ((d.fields || {}).clientName || "") + " " + d.template).toLowerCase();
      return hay.indexOf(q) !== -1;
    });
    var el = document.getElementById("doc-list");
    if (!allDocs.length) {
      el.innerHTML = '<p class="empty-note">No documents yet. <a href="#/new">Prepare your first approval</a>.</p>';
    } else if (!list.length) {
      el.innerHTML = '<p class="empty-note">No documents match this view.</p>';
    } else {
      el.innerHTML = list.map(cardHtml).join("");
    }
  }

  function renderList() {
    show("view-list");
    api("/api/documents").then(function (j) {
      allDocs = j.documents;
      applyListFilter();
    }).catch(function (e) {
      document.getElementById("doc-list").innerHTML = '<p class="empty-note">Error: ' + esc(e.message) + "</p>";
    });
  }

  document.getElementById("doc-search").addEventListener("input", applyListFilter);

  /* ---------- editor: prepare the document (with live preview) ---------- */
  function fieldInput(fd, values) {
    values = values || {};
    var v = values[fd.key] != null ? values[fd.key] : (fd.def != null ? fd.def : "");
    var val = fd.type === "date" || fd.type === "textarea" ? "" : ' value="' + esc(v) + '"';
    var ph = fd.placeholder ? ' placeholder="' + esc(fd.placeholder) + '"' : "";
    var req = fd.required ? " required" : "";
    if (fd.type === "textarea") {
      return '<label>' + esc(fd.label) + '<textarea data-key="' + fd.key + '"' + ph + req + ">" + esc(v) + "</textarea></label>";
    }
    if (fd.type === "date") {
      return '<label>' + esc(fd.label) + '<input type="date" data-key="' + fd.key + '" value="' + esc(v || T.todayISO()) + '"' + req + "></label>";
    }
    return '<label>' + esc(fd.label) + '<input type="' + fd.type + '" data-key="' + fd.key + '"' + val + ph + req + "></label>";
  }

  var selectedTemplate = "quote-approval";

  function collectFields(containerSel) {
    var fields = {};
    document.querySelectorAll(containerSel + " [data-key]").forEach(function (el) {
      fields[el.getAttribute("data-key")] = el.value;
    });
    return fields;
  }

  function previewDoc(templateId, fields, title) {
    return {
      template: templateId,
      fields: fields,
      title: title,
      number: "SP-····-····",
      createdAt: new Date().toISOString(),
      status: "draft",
      signatures: []
    };
  }

  function updatePreview() {
    var title = document.getElementById("f-title").value.trim() ||
      T.TEMPLATES[selectedTemplate].name + " — preview";
    var fields = collectFields("#template-fields");
    var t = T.TEMPLATES[selectedTemplate];
    // keep template-defined placeholder values for untouched date fields etc.
    document.getElementById("edit-preview").innerHTML =
      '<div class="letterhead"><div class="lh-brand">SignPilot <span>AI</span> · Approval Document</div>' +
      '<div class="lh-num">SP-····-····</div></div>' +
      (function () {
        var paras = T.renderBody(selectedTemplate, fields);
        return '<p class="lead">' + esc(paras[0]) + "</p>" +
          paras.slice(1).map(function (p) { return "<p>" + esc(p) + "</p>"; }).join("") +
          '<p class="muted">Live preview — ' + esc(t.name) + "</p>";
      })();
    void title;
  }

  function renderEdit() {
    show("view-edit");
    var gal = document.getElementById("tpl-gallery");
    gal.innerHTML = Object.values(T.TEMPLATES).map(function (t) {
      return '<button type="button" role="radio" aria-checked="' + (t.id === selectedTemplate) +
        '" class="tpl-card' + (t.id === selectedTemplate ? " selected" : "") + '" data-t="' + t.id + '">' +
        "<h3>" + esc(t.name) + "</h3><p>" + esc(t.blurb) + "</p></button>";
    }).join("");
    function drawFields() {
      var t = T.TEMPLATES[selectedTemplate];
      document.getElementById("template-blurb").textContent = t.blurb;
      document.getElementById("template-fields").innerHTML = t.fields.map(function (fd) {
        return fieldInput(fd);
      }).join("");
      gal.querySelectorAll(".tpl-card").forEach(function (c) {
        var on = c.getAttribute("data-t") === selectedTemplate;
        c.classList.toggle("selected", on);
        c.setAttribute("aria-checked", on);
      });
      updatePreview();
    }
    gal.querySelectorAll(".tpl-card").forEach(function (c) {
      c.addEventListener("click", function () {
        selectedTemplate = c.getAttribute("data-t");
        drawFields();
      });
    });
    drawFields();
    document.getElementById("edit-msg").textContent = "";
  }

  document.getElementById("template-fields").addEventListener("input", updatePreview);
  document.getElementById("f-title").addEventListener("input", updatePreview);

  document.getElementById("btn-save-doc").addEventListener("click", function () {
    var tid = selectedTemplate;
    var fields = collectFields("#template-fields");
    var title = document.getElementById("f-title").value.trim() ||
      T.TEMPLATES[tid].name + " — " + (fields.clientName || "untitled");
    api("/api/documents", { method: "POST", body: { template: tid, title: title, fields: fields } })
      .then(function (j) { location.hash = "#/doc/" + j.document.id; })
      .catch(function (e) { document.getElementById("edit-msg").textContent = "Error: " + e.message; });
  });

  /* ---------- detail ---------- */
  function renderSignProgress(d) {
    var sigs = d.signatures || [];
    var rows = ["contractor", "client"].map(function (role) {
      var s = sigs.find(function (x) { return x.role === role; });
      var label = role === "contractor" ? "Contractor" : "Client";
      var init = s ? esc(s.name.trim().charAt(0).toUpperCase() || "?") : label.charAt(0);
      return '<div class="prog-row"><span class="avatar' + (s ? "" : " pending") + '">' + init + "</span>" +
        '<span><span class="prog-who">' + label + "</span>" +
        '<span class="prog-sub">' + (s
          ? esc(s.name) + "<br>signed " + fmtTs(s.signedAt) +
            (s.hash ? "<br>seal " + esc(s.hash.slice(0, 12)) + "…" : "")
          : "awaiting signature") + "</span></span>" +
        (s ? '<span class="prog-check" aria-label="signed">✓</span>' : "") + "</div>";
    }).join("");
    document.getElementById("sign-progress").innerHTML = rows;
  }

  function renderCertificate(d) {
    var sec = document.getElementById("cert-section");
    if (d.status !== "signed") { sec.classList.add("hidden"); return; }
    sec.classList.remove("hidden");
    document.getElementById("cert-title").textContent = d.title;
    var sigs = d.signatures || [];
    document.getElementById("cert-meta").innerHTML =
      "<span><strong>Document</strong> " + esc(d.number) + "</span>" +
      "<span><strong>Template</strong> " + esc(tplName(d.template)) + "</span>" +
      "<span><strong>Executed</strong> " + fmtTs(d.signedAt) + "</span>";
    document.getElementById("cert-events").innerHTML = sigs.map(function (s) {
      var label = s.role === "contractor" ? "Contractor" : "Client";
      return '<div class="cert-event"><span class="avatar">' +
        esc(s.name.trim().charAt(0).toUpperCase() || "?") + "</span>" +
        "<span><strong>" + esc(s.name) + "</strong> <span class=\"muted\">(" + label + ")</span><br>" +
        '<span class="muted">signed ' + fmtTs(s.signedAt) + "</span></span>" +
        '<span class="prog-check" aria-label="signed">✓</span></div>';
    }).join("");
    document.getElementById("cert-seals").innerHTML = sigs.map(function (s) {
      return "seal <span class=\"seal-hash\">" + esc((s.hash || "").slice(0, 24)) + "…</span> (" + esc(s.role) + ")";
    }).join("<br>");
  }

  document.getElementById("btn-print-cert").addEventListener("click", function () {
    window.print();
  });

  var editDoc = null;

  function renderDoc(id) {
    show("view-doc");
    document.getElementById("edit-fields-panel").classList.add("hidden");
    api("/api/documents/" + id).then(function (j) {
      var d = j.document;
      editDoc = d;
      document.getElementById("doc-title").textContent = d.title;
      var pill = document.getElementById("doc-status");
      pill.className = "pill " + d.status;
      pill.textContent = d.status;
      renderSignProgress(d);
      document.getElementById("doc-body").innerHTML = paperHtml(d);
      renderCertificate(d);
      var actions = document.getElementById("doc-actions");
      actions.innerHTML = "";
      function btn(label, cls, fn) {
        var b = document.createElement("button");
        b.className = "btn " + cls; b.textContent = label;
        b.addEventListener("click", fn);
        actions.appendChild(b);
      }
      if (d.status === "draft") {
        btn("Correct fields", "ghost", function () {
          var p = document.getElementById("edit-fields-panel");
          p.classList.remove("hidden");
          var t = T.TEMPLATES[d.template];
          document.getElementById("edit-fields").innerHTML = t.fields.map(function (fd) {
            return fieldInput(fd, d.fields || {});
          }).join("");
          document.getElementById("edit-fields-msg").textContent = "";
          p.scrollIntoView({ behavior: "smooth", block: "start" });
        });
        btn("Mark as sent", "primary", function () {
          api("/api/documents/" + id, { method: "PATCH", body: { status: "sent" } })
            .then(function () { renderDoc(id); })
            .catch(function (e) { alert("Error: " + e.message); });
        });
        btn("Delete draft", "ghost danger", function () {
          if (!confirm("Delete draft " + d.number + "? This cannot be undone.")) return;
          api("/api/documents/" + id, { method: "DELETE" })
            .then(function () { location.hash = "#/"; })
            .catch(function (e) { alert("Error: " + e.message); });
        });
      }
      if (d.status === "sent") {
        btn("Open signing view", "primary", function () { location.hash = "#/sign/" + id; });
        btn("Record reminder sent", "ghost", function () {
          api("/api/documents/" + id + "/nudge", { method: "POST", body: { via: "contractor note" } })
            .then(function () { renderDoc(id); })
            .catch(function (e) { alert("Error: " + e.message); });
        });
        btn("Recall to draft", "ghost", function () {
          api("/api/documents/" + id, { method: "PATCH", body: { status: "draft" } })
            .then(function () { renderDoc(id); })
            .catch(function (e) { alert("Error: " + e.message); });
        });
      }
      btn("Duplicate", "ghost", function () {
        api("/api/documents/" + id + "/duplicate", { method: "POST" })
          .then(function (r) { location.hash = "#/doc/" + r.document.id; })
          .catch(function (e) { alert("Error: " + e.message); });
      });
      document.getElementById("btn-verify").onclick = function () {
        api("/api/documents/" + id + "/verify").then(function (v) {
          var box = document.getElementById("verify-box");
          var rows = v.seals.map(function (s) {
            return '<li class="' + (s.valid ? "seal-ok" : "seal-bad") + '">' +
              esc(s.role) + " — " + esc(s.name) + ": " +
              (s.valid ? "seal intact" : "SEAL BROKEN — document or signature changed after signing") +
              "</li>";
          }).join("");
          box.innerHTML = "<strong>" + (v.valid ? "All seals intact." : "TAMPER DETECTED.") + "</strong><ul>" + rows + "</ul>";
          box.className = "verify-box " + (v.valid ? "ok" : "bad");
          box.classList.remove("hidden");
        }).catch(function (e) { alert("Error: " + e.message); });
      };
      document.getElementById("seal-card").style.display =
        (d.signatures && d.signatures.length) ? "" : "none";
      var back = document.createElement("a");
      back.className = "btn ghost"; back.href = "#/"; back.textContent = "Back to documents";
      actions.appendChild(back);

      var sendBox = document.getElementById("send-box");
      if (d.status === "sent") {
        sendBox.classList.remove("hidden");
        document.getElementById("sign-link").value =
          location.origin + location.pathname + "#/sign/" + id;
      } else sendBox.classList.add("hidden");

      // Trades-pipeline link: documents created by quotely-ai carry
      // quotelyQuoteId / quotelyPurpose in their fields.
      var qlBox = document.getElementById("quote-link-box");
      var qlId = d.fields && d.fields.quotelyQuoteId;
      if (qlId) {
        qlBox.classList.remove("hidden");
        var purpose = (d.fields.quotelyPurpose || "approval").replace(/-/g, " ");
        document.getElementById("quote-link-text").textContent =
          "From Quotely " + (d.fields.quotelyQuoteNumber || "") + " (" + purpose + "). " +
          "Signing or declining this document updates the quote's pipeline status automatically.";
      } else qlBox.classList.add("hidden");

      document.getElementById("pdf-box").classList.toggle("hidden", d.status !== "signed");

      api("/api/documents/" + id + "/audit").then(function (a) {
        document.getElementById("doc-audit").innerHTML = a.audit.map(function (e) {
          return "<li><time>" + esc(e.ts.slice(0, 16).replace("T", " ")) + "</time><strong>" +
            esc(e.event) + "</strong> — " + esc(e.detail) + "</li>";
        }).join("");
      }).catch(function (e) {
        document.getElementById("doc-audit").innerHTML =
          '<li class="muted">Audit trail unavailable: ' + esc(e.message) + "</li>";
      });

      document.getElementById("btn-pdf").onclick = function () {
        exportPdf(d, document.getElementById("pdf-box"));
      };
    }).catch(function (e) {
      document.getElementById("doc-title").textContent = "Error: " + e.message;
    });
  }

  /* Draft field correction (prepare step). */
  document.getElementById("btn-save-fields").addEventListener("click", function () {
    if (!editDoc) return;
    var msg = document.getElementById("edit-fields-msg");
    var fields = {};
    // keep pipeline/link fields that are not part of the template form
    Object.keys(editDoc.fields || {}).forEach(function (k) {
      var isTpl = T.TEMPLATES[editDoc.template].fields.some(function (fd) { return fd.key === k; });
      if (!isTpl) fields[k] = editDoc.fields[k];
    });
    document.querySelectorAll("#edit-fields [data-key]").forEach(function (el) {
      fields[el.getAttribute("data-key")] = el.value;
    });
    api("/api/documents/" + editDoc.id, { method: "PATCH", body: { fields: fields } })
      .then(function () {
        msg.textContent = "Saved — the document paper now shows the corrected values.";
        renderDoc(editDoc.id);
      })
      .catch(function (e) { msg.textContent = "Error: " + e.message; });
  });
  document.getElementById("btn-cancel-fields").addEventListener("click", function () {
    document.getElementById("edit-fields-panel").classList.add("hidden");
  });

  document.getElementById("btn-copy-link").addEventListener("click", function () {
    var i = document.getElementById("sign-link");
    i.select();
    function legacy() {
      try { document.execCommand("copy"); }
      catch (e) { alert("Copy failed — select and copy the link manually."); }
    }
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(i.value).catch(legacy);
    } else legacy();
  });

  /* ---------- signing ceremony ---------- */
  function setSteps(review, sign, done) {
    // each: "done" | "current" | "" (pending)
    document.querySelectorAll("#ceremony-steps .step").forEach(function (s) {
      var n = Number(s.getAttribute("data-s"));
      var state = n === 1 ? review : n === 2 ? sign : done;
      s.classList.toggle("done", state === "done");
      s.classList.toggle("current", state === "current");
      s.querySelector(".stepnum").textContent = state === "done" ? "✓" : String(n);
    });
  }

  function banner(kind, text) {
    var b = document.getElementById("ceremony-banner");
    b.className = "ceremony-banner " + kind;
    b.innerHTML = text;
  }

  var ceremonyDoc = null;

  function renderSign(id) {
    show("view-sign");
    ceremonyDoc = null;
    pad.clear();
    document.getElementById("sign-name").value = "";
    document.getElementById("sign-typed").value = "";
    document.getElementById("sign-msg").textContent = "";
    document.getElementById("consent-check").checked = false;
    document.getElementById("adopted-panel").classList.add("hidden");
    document.getElementById("completion-panel").classList.add("hidden");
    document.getElementById("consent-card").style.display = "";
    document.getElementById("sign-desk").style.display = "";
    setSteps("done", "current", "");
    api("/api/documents/" + id).then(function (j) {
      var d = j.document;
      ceremonyDoc = d;
      document.getElementById("sign-title").textContent = d.title;
      document.getElementById("sign-body").innerHTML = paperHtml(d);
      var deskOk = d.status === "sent";
      document.getElementById("sign-desk").style.display = deskOk ? "" : "none";
      document.getElementById("consent-card").style.display = deskOk ? "" : "none";
      if (!deskOk) {
        banner("warn", "This document is <strong>" + esc(d.status) + "</strong> — it must be sent before it can be signed.");
        setSteps("done", "", "");
      } else {
        banner("info", "<strong>Step 2 — adopt your signature.</strong> Review the document above, consent to electronic signing, then draw or type your signature on the pad.");
        // pre-select the role that hasn't signed yet (guided, Dropbox-Sign style)
        var roles = (d.signatures || []).map(function (s) { return s.role; });
        if (roles.indexOf("client") === -1) document.getElementById("sign-role").value = "client";
        else document.getElementById("sign-role").value = "contractor";
      }
      document.getElementById("btn-adopt").onclick = function () {
        var msg = document.getElementById("sign-msg");
        var name = document.getElementById("sign-name").value.trim();
        var role = document.getElementById("sign-role").value;
        if (!name) { msg.textContent = "Please enter your printed name."; return; }
        if (!document.getElementById("consent-check").checked) {
          msg.textContent = "Please check the electronic signature consent box first.";
          return;
        }
        if (pad.isEmpty()) { msg.textContent = "Please draw your signature on the pad first."; return; }
        msg.textContent = "";
        var panel = document.getElementById("adopted-panel");
        document.getElementById("adopted-img").src = pad.toDataURL();
        document.getElementById("adopted-name").textContent = name;
        document.getElementById("adopted-role").textContent =
          "Signing as " + (role === "client" ? "Client" : "Contractor") + " · " + new Date().toLocaleString();
        panel.classList.remove("hidden");
        panel.scrollIntoView({ behavior: "smooth", block: "center" });
      };
      document.getElementById("btn-adopt-redraw").onclick = function () {
        pad.clear();
        document.getElementById("adopted-panel").classList.add("hidden");
        document.getElementById("sign-desk").scrollIntoView({ behavior: "smooth", block: "center" });
      };
      document.getElementById("btn-adopt-confirm").onclick = function () {
        var name = document.getElementById("sign-name").value.trim();
        var role = document.getElementById("sign-role").value;
        var msg = document.getElementById("adopt-msg");
        msg.textContent = "Recording signature…";
        api("/api/documents/" + id + "/sign", {
          method: "POST",
          body: { role: role, name: name, signature: pad.toDataURL() }
        }).then(function (r) {
          ceremonyDoc = r.document;
          if (r.document.status === "signed") showCompletion(r.document);
          else {
            document.getElementById("adopted-panel").classList.add("hidden");
            document.getElementById("sign-desk").style.display = "none";
            document.getElementById("consent-card").style.display = "none";
            banner("info", "<strong>Signature recorded.</strong> " + esc(name) + " (" + esc(role) +
              ") has signed — the document completes when the other party signs too.");
            setSteps("done", "done", "");
          }
        }).catch(function (e) { msg.textContent = "Error: " + e.message; });
      };
      document.getElementById("btn-decline").onclick = function () {
        var msg = document.getElementById("sign-msg");
        if (!confirm("Decline to sign this document? This closes it as declined — the contractor will be notified in the audit trail.")) return;
        var reason = prompt("Optional: why are you declining? (recorded in the audit trail)") || "";
        api("/api/documents/" + id + "/decline", { method: "POST", body: { reason: reason } })
          .then(function () {
            msg.textContent = "Document declined. The contractor has a permanent record with your reason.";
            banner("warn", "<strong>Declined.</strong> This document is now a permanent declined record.");
            setSteps("done", "", "");
            document.getElementById("sign-desk").style.display = "none";
            document.getElementById("consent-card").style.display = "none";
          })
          .catch(function (e) { msg.textContent = "Error: " + e.message; });
      };
      document.getElementById("btn-completion-pdf").onclick = function () {
        if (ceremonyDoc) exportPdf(ceremonyDoc, document.getElementById("completion-panel"));
      };
      document.getElementById("btn-completion-doc").href = "#/doc/" + id;
    }).catch(function (e) {
      banner("warn", "Error: " + esc(e.message));
    });
  }

  function showCompletion(d) {
    setSteps("done", "done", "current");
    banner("success", "<strong>Fully executed.</strong> Both parties have signed — this document is complete.");
    document.getElementById("adopted-panel").classList.add("hidden");
    document.getElementById("sign-desk").style.display = "none";
    document.getElementById("consent-card").style.display = "none";
    var p = document.getElementById("completion-panel");
    p.classList.remove("hidden");
    var sigs = d.signatures || [];
    document.getElementById("completion-text").textContent =
      sigs.map(function (s) { return s.name + " (" + s.role + ")"; }).join(" and ") +
      " signed " + d.title + " on " + String(d.signedAt || "").slice(0, 10) + ".";
    document.getElementById("completion-seals").innerHTML = sigs.map(function (s) {
      return '<div class="completion-seal"><span class="seal-ring" aria-hidden="true">✓</span>' +
        "<span><strong>" + esc(s.name) + "</strong><br>" +
        '<span class="muted">seal ' + esc((s.hash || "").slice(0, 16)) + "…</span></span></div>";
    }).join("");
    p.scrollIntoView({ behavior: "smooth", block: "center" });
  }

  document.getElementById("btn-clear-sig").addEventListener("click", function () { pad.clear(); });
  document.getElementById("btn-stamp-sig").addEventListener("click", function () {
    var t = document.getElementById("sign-typed").value.trim() ||
      document.getElementById("sign-name").value.trim();
    if (!t) {
      document.getElementById("sign-msg").textContent = "Type your name above first.";
      return;
    }
    pad.stamp(t);
    document.getElementById("sign-msg").textContent = "Typed signature applied — you can still draw over it.";
  });

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

  function exportPdf(d, container) {
    var msg = document.createElement("p");
    msg.className = "muted"; msg.textContent = "Generating PDF…";
    container.appendChild(msg);
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
          if (s.hash) para("Seal: " + s.hash, { size: 8 });
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
