// Stage 3 workflow interactions.
// - Auto machine-ID suggestion from the selected batch (e.g. batch T -> 5T)
// - Smart defaults on the Receive Inventory screen
// - Repeatable probe rows + duplicate serial warnings
// - Send / Return checklist helpers

(function () {
    "use strict";

    function fetchJSON(url) {
        return fetch(url).then(function (r) { return r.ok ? r.json() : null; });
    }

    function todayISO() {
        var d = new Date();
        return d.getFullYear() + "-" +
            String(d.getMonth() + 1).padStart(2, "0") + "-" +
            String(d.getDate()).padStart(2, "0");
    }

    // ── Machine ID suggestion ─────────────────────────────────────────────
    var machineIdInput = document.getElementById("machine_id");
    var batchSelect = document.getElementById("batch_id");
    var batchCodeInput = document.getElementById("batch_code");
    var arrivalInput = document.getElementById("arrival_date");

    if (machineIdInput) {
        machineIdInput.dataset.userTyped = "0";
        machineIdInput.dataset.suggested = machineIdInput.value || "";
        machineIdInput.addEventListener("input", function () {
            machineIdInput.dataset.userTyped =
                machineIdInput.value !== machineIdInput.dataset.suggested ? "1" : "0";
        });
    }

    function suggestMachineId() {
        if (!machineIdInput || machineIdInput.dataset.userTyped === "1") return;
        var url = null;
        if (batchSelect && batchSelect.value) {
            url = "/api/machine-id-suggestion?batch_id=" + encodeURIComponent(batchSelect.value);
        } else if (batchCodeInput && batchCodeInput.value.trim()) {
            url = "/api/machine-id-suggestion?batch_code=" + encodeURIComponent(batchCodeInput.value.trim());
        }
        if (!url) return;
        fetchJSON(url)
            .then(function (data) {
                if (data && data.machine_id && machineIdInput.dataset.userTyped !== "1") {
                    machineIdInput.value = data.machine_id;
                    machineIdInput.dataset.suggested = data.machine_id;
                }
            })
            .catch(function () { /* offline / ignore */ });
    }

    if (batchSelect) {
        batchSelect.addEventListener("change", suggestMachineId);
        if (batchSelect.value) suggestMachineId();
    }

    // ── Receive Inventory screen ──────────────────────────────────────────
    var receiveForm = document.getElementById("receive-form");
    if (receiveForm) {
        var batchDates = {};
        try {
            batchDates = JSON.parse(receiveForm.getAttribute("data-batch-dates") || "{}");
        } catch (e) { batchDates = {}; }

        if (arrivalInput) {
            arrivalInput.dataset.touched = "0";
            arrivalInput.addEventListener("input", function () {
                arrivalInput.dataset.touched = "1";
            });
        }

        function onBatchCodeChange() {
            if (!batchCodeInput) return;
            var code = batchCodeInput.value.trim();
            if (code && batchDates[code] && arrivalInput && arrivalInput.dataset.touched !== "1") {
                arrivalInput.value = batchDates[code];
            }
            suggestMachineId();
        }
        if (batchCodeInput) batchCodeInput.addEventListener("change", onBatchCodeChange);

        var addProvider = document.getElementById("add-provider");
        if (addProvider) {
            addProvider.addEventListener("click", function () {
                var field = document.getElementById("provider_name");
                field.value = "";
                field.focus();
            });
        }
        var addBatch = document.getElementById("add-batch");
        if (addBatch) {
            addBatch.addEventListener("click", function () {
                batchCodeInput.value = "";
                if (arrivalInput && arrivalInput.dataset.touched !== "1") {
                    arrivalInput.value = todayISO();
                }
                if (machineIdInput) {
                    machineIdInput.dataset.userTyped = "0";
                    machineIdInput.value = "";
                }
                batchCodeInput.focus();
            });
        }

        // Probe rows
        var probeRows = document.getElementById("probe-rows");
        var addProbeBtn = document.getElementById("add-probe");
        var serialWarning = document.getElementById("serial-warning");

        function makeProbeRow(model, serial) {
            var row = document.createElement("div");
            row.className = "probe-row";
            row.innerHTML =
                '<input type="text" class="probe-model" name="probe_model" list="probe-model-list" ' +
                'autocomplete="off" placeholder="Probe model (e.g. C1-5)">' +
                '<input type="text" class="probe-serial" name="probe_serial" placeholder="Probe serial number">' +
                '<button type="button" class="btn btn-ghost btn-small remove-probe" title="Remove row">×</button>';
            row.querySelector(".probe-model").value = model || "";
            row.querySelector(".probe-serial").value = serial || "";
            return row;
        }

        if (addProbeBtn && probeRows) {
            addProbeBtn.addEventListener("click", function () {
                var row = makeProbeRow("", "");
                probeRows.appendChild(row);
                row.querySelector(".probe-model").focus();
            });
        }
        if (probeRows) {
            probeRows.addEventListener("click", function (event) {
                var btn = event.target.closest(".remove-probe");
                if (!btn) return;
                var rows = probeRows.querySelectorAll(".probe-row");
                var row = btn.closest(".probe-row");
                if (rows.length > 1) {
                    row.remove();
                } else {
                    row.querySelector(".probe-model").value = "";
                    row.querySelector(".probe-serial").value = "";
                }
            });
            probeRows.addEventListener("change", function (event) {
                if (!event.target.classList.contains("probe-serial")) return;
                var serial = event.target.value.trim();
                if (!serial || !serialWarning) {
                    if (serialWarning) serialWarning.hidden = true;
                    return;
                }
                fetchJSON("/api/probe-serial-check?serial=" + encodeURIComponent(serial))
                    .then(function (data) {
                        if (data && data.exists) {
                            serialWarning.hidden = false;
                            serialWarning.textContent =
                                "This probe serial number already exists. " +
                                data.internal_id + " is " + data.where + ".";
                        } else {
                            serialWarning.hidden = true;
                        }
                    })
                    .catch(function () { /* offline / ignore */ });
            });
        }

        if (/[?&]resume=/.test(window.location.search)) {
            var serialField = document.getElementById("serial_number");
            if (serialField) serialField.focus();
        }
    }

    // ── Send screen: workshop / dealer destination switch ─────────────────
    var destRadios = document.querySelectorAll('input[name="destination_type"]');
    if (destRadios.length) {
        Array.prototype.forEach.call(destRadios, function (radio) {
            radio.addEventListener("change", function () {
                var input = document.getElementById("destination");
                if (!input) return;
                input.setAttribute("list", radio.value === "dealer" ? "dealer-list" : "workshop-list");
                var label = document.getElementById("dest-label");
                if (label) label.textContent = radio.value === "dealer" ? "Dealer" : "Workshop";
                input.value = "";
                input.focus();
            });
        });
    }

    // ── Return screen: "N items have not been returned" warning ───────────
    var returnChecklist = document.getElementById("return-checklist");
    var missingWarning = document.getElementById("missing-warning");
    if (returnChecklist && missingWarning) {
        var updateMissing = function () {
            var boxes = returnChecklist.querySelectorAll('input[type="checkbox"]:not([disabled])');
            var total = boxes.length;
            var checked = 0;
            Array.prototype.forEach.call(boxes, function (box) { if (box.checked) checked += 1; });
            var missing = total - checked;
            if (total > 0 && missing > 0) {
                missingWarning.hidden = false;
                missingWarning.textContent = missing + " item" + (missing > 1 ? "s have" : " has") +
                    " not been returned.";
            } else {
                missingWarning.hidden = true;
            }
        };
        returnChecklist.addEventListener("change", updateMissing);
        updateMissing();
    }

    // ── Catalogue-backed datalist for the machine model field ─────────────
    // Only fills an EMPTY datalist, so server-rendered lists are kept.
    var modelInput = document.getElementById("model");
    if (modelInput) {
        var listId = modelInput.getAttribute("list");
        var datalist = listId ? document.getElementById(listId) : null;
        if (datalist && datalist.options.length === 0) {
            fetchJSON("/api/catalog-products?category=Machine")
                .then(function (rows) {
                    if (!rows || datalist.options.length) return;
                    rows.forEach(function (row) {
                        var opt = document.createElement("option");
                        opt.value = row.brand_name ? row.brand_name + " " + row.name_model : row.name_model;
                        datalist.appendChild(opt);
                    });
                })
                .catch(function () { /* offline / ignore */ });
        }
    }
    // ── Stage 4: quick-add workshop/dealer without leaving the screen ────
    Array.prototype.forEach.call(document.querySelectorAll(".js-add-partner"), function (btn) {
        btn.addEventListener("click", function () {
            var modal = document.getElementById("modal-" + btn.dataset.kind);
            if (modal) {
                modal.hidden = false;
                var field = modal.querySelector("input[name='name']");
                if (field) field.focus();
            }
        });
    });

    Array.prototype.forEach.call(document.querySelectorAll(".modal-backdrop"), function (backdrop) {
        backdrop.addEventListener("click", function (event) {
            if (event.target === backdrop) backdrop.hidden = true;
        });
        var close = backdrop.querySelector(".js-close-modal");
        if (close) {
            close.addEventListener("click", function () { backdrop.hidden = true; });
        }
        var form = backdrop.querySelector("form");
        if (!form) return;
        form.addEventListener("submit", function (event) {
            event.preventDefault();
            var kind = form.dataset.kind;
            var payload = {};
            new FormData(form).forEach(function (value, key) { payload[key] = value; });
            var error = form.querySelector(".modal-error");
            fetch(form.dataset.endpoint, {
                method: "POST",
                headers: { "Content-Type": "application/json" },
                body: JSON.stringify(payload)
            })
                .then(function (r) {
                    return r.json().then(function (body) { return { ok: r.ok, body: body }; });
                })
                .then(function (res) {
                    if (!res.ok) {
                        if (error) {
                            error.hidden = false;
                            error.textContent = (res.body && res.body.error) || "Could not save.";
                        }
                        return;
                    }
                    var list = document.getElementById(kind + "-list");
                    if (list) {
                        var option = document.createElement("option");
                        option.value = res.body.name;
                        list.appendChild(option);
                    }
                    var destination = document.getElementById("destination");
                    if (destination) destination.value = res.body.name;
                    backdrop.hidden = true;
                    form.reset();
                    if (error) error.hidden = true;
                })
                .catch(function () {
                    if (error) {
                        error.hidden = false;
                        error.textContent = "Could not reach the server.";
                    }
                });
        });
    });
    // ── Sidebar: Full Inventory dropdown ─────────────────────────────────
    Array.prototype.forEach.call(document.querySelectorAll(".nav-caret"), function (caret) {
        caret.addEventListener("click", function () {
            var dd = caret.closest(".nav-dropdown");
            if (!dd) return;
            var open = dd.classList.toggle("open");
            caret.setAttribute("aria-expanded", open ? "true" : "false");
            try { localStorage.setItem("nav-inventory-open", open ? "1" : "0"); } catch (e) { /* ignore */ }
        });
    });
    try {
        if (localStorage.getItem("nav-inventory-open") === "1") {
            Array.prototype.forEach.call(document.querySelectorAll(".nav-dropdown"), function (dd) {
                dd.classList.add("open");
                var c = dd.querySelector(".nav-caret");
                if (c) c.setAttribute("aria-expanded", "true");
            });
        }
    } catch (e) { /* ignore */ }
})();
