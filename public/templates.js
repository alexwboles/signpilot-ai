/* SignPilot AI document templates.
 * UMD module: required by server.js (Node) and loaded in the browser.
 * All template copy is hand-written for this project.
 */
(function (root, factory) {
  if (typeof module !== "undefined" && module.exports) {
    module.exports = factory();
  } else {
    root.SignPilotTemplates = factory();
  }
})(typeof self !== "undefined" ? self : this, function () {
  "use strict";

  var TEMPLATES = {
    "quote-approval": {
      id: "quote-approval",
      name: "Quote Approval",
      blurb: "Client approves a quote's scope and total before work begins.",
      fields: [
        { key: "clientName", label: "Client name", type: "text", required: true },
        { key: "quoteNumber", label: "Quote number", type: "text", placeholder: "Q-2026-0001" },
        { key: "workDescription", label: "Work description", type: "textarea", required: true },
        { key: "total", label: "Total amount ($)", type: "number", required: true },
        { key: "validDays", label: "Quote valid for (days)", type: "number", def: "30" },
        { key: "notes", label: "Notes (optional)", type: "textarea" }
      ]
    },
    "change-order": {
      id: "change-order",
      name: "Change Order",
      blurb: "Both parties agree a scope change and its cost impact, in writing.",
      fields: [
        { key: "clientName", label: "Client name", type: "text", required: true },
        { key: "projectRef", label: "Project reference", type: "text", placeholder: "Q-2026-0001" },
        { key: "changeDescription", label: "Change requested", type: "textarea", required: true },
        { key: "costDelta", label: "Cost impact ($) — negative for a credit", type: "number", required: true },
        { key: "newTotal", label: "New project total ($) (optional)", type: "number" },
        { key: "notes", label: "Notes (optional)", type: "textarea" }
      ]
    },
    "completion": {
      id: "completion",
      name: "Work Completion Sign-off",
      blurb: "Client confirms the work is complete to their satisfaction.",
      fields: [
        { key: "clientName", label: "Client name", type: "text", required: true },
        { key: "projectRef", label: "Project reference", type: "text", placeholder: "Q-2026-0001" },
        { key: "workSummary", label: "Work completed", type: "textarea", required: true },
        { key: "completionDate", label: "Completion date", type: "date" },
        { key: "warrantyNote", label: "Warranty note (optional)", type: "textarea", placeholder: "e.g. 1-year workmanship warranty" }
      ]
    }
  };

  function money(n) {
    var v = Number(n);
    if (!isFinite(v)) return "$0.00";
    return "$" + v.toFixed(2).replace(/\B(?=(\d{3})+(?!\d))/g, ",");
  }

  function todayISO() {
    return new Date().toISOString().slice(0, 10);
  }

  /* Render the printable body paragraphs for a document. */
  function renderBody(templateId, f) {
    f = f || {};
    var t = TEMPLATES[templateId];
    if (!t) return ["Unknown template."];
    if (templateId === "quote-approval") {
      var paras = [
        "QUOTE APPROVAL" + (f.quoteNumber ? " — " + f.quoteNumber : ""),
        "Client: " + (f.clientName || ""),
        "Scope of work: " + (f.workDescription || ""),
        "Total: " + money(f.total) + " — this quote is valid for " +
          (f.validDays || "30") + " days from the date below.",
        "By signing below, the client approves the scope and total above and " +
          "authorizes the contractor to schedule the work. A deposit may be " +
          "required before scheduling."
      ];
      if (f.notes) paras.splice(4, 0, "Notes: " + f.notes);
      return paras;
    }
    if (templateId === "change-order") {
      var delta = Number(f.costDelta);
      var paras2 = [
        "CHANGE ORDER" + (f.projectRef ? " — " + f.projectRef : ""),
        "Client: " + (f.clientName || ""),
        "Change requested: " + (f.changeDescription || ""),
        "Cost impact: " + (delta < 0 ? "credit of " + money(-delta) : money(delta)) +
          (f.newTotal ? " — new project total: " + money(f.newTotal) : ""),
        "By signing below, both parties agree the change above becomes part of " +
          "the project scope at the stated cost impact."
      ];
      if (f.notes) paras2.splice(4, 0, "Notes: " + f.notes);
      return paras2;
    }
    // completion
    var paras3 = [
      "WORK COMPLETION SIGN-OFF" + (f.projectRef ? " — " + f.projectRef : ""),
      "Client: " + (f.clientName || ""),
      "Work completed: " + (f.workSummary || ""),
      "Completion date: " + (f.completionDate || todayISO())
    ];
    if (f.warrantyNote) paras3.push("Warranty: " + f.warrantyNote);
    paras3.push(
      "By signing below, the client confirms the work described above is " +
      "complete to their satisfaction."
    );
    return paras3;
  }

  function validateFields(templateId, fields) {
    var t = TEMPLATES[templateId];
    if (!t) return ["Unknown template: " + templateId];
    var errs = [];
    t.fields.forEach(function (fd) {
      var v = fields ? fields[fd.key] : undefined;
      if (fd.required && (v === undefined || v === null || String(v).trim() === "")) {
        errs.push("Missing required field: " + fd.label);
      }
      if (fd.type === "number" && v !== undefined && v !== "" && !isFinite(Number(v))) {
        errs.push("Not a number: " + fd.label);
      }
    });
    return errs;
  }

  return {
    TEMPLATES: TEMPLATES,
    renderBody: renderBody,
    validateFields: validateFields,
    todayISO: todayISO
  };
});
