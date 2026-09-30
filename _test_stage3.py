import os
import sqlite3
import tempfile
from datetime import date

from app import create_app

TODAY = date.today().isoformat()
FAILURES = []


def check(name, condition, extra=""):
    status = "PASS" if condition else "FAIL"
    print(f"[{status}] {name}" + ("" if condition else f"  -> {extra}"))
    if not condition:
        FAILURES.append(name)


def rows(db_path, sql, *params):
    con = sqlite3.connect(db_path)
    con.row_factory = sqlite3.Row
    try:
        return [dict(r) for r in con.execute(sql, params).fetchall()]
    finally:
        con.close()


def one(db_path, sql, *params):
    r = rows(db_path, sql, *params)
    return r[0] if r else None


tmpdir = tempfile.mkdtemp(prefix="stage3-test-")
DB = os.path.join(tmpdir, "test.db")
app = create_app({"DATABASE": DB, "TESTING": True})
client = app.test_client()

print("=== 1-4. RECEIVE MACHINE (one place: provider, batch, date, brand, model, serial, probes, printer) ===")

r = client.get("/receive")
html = r.get_data(as_text=True)
check("receive page opens", r.status_code == 200)
check("arrival date defaults to today", f'value="{TODAY}"' in html)

r = client.post("/receive", data={
    "provider_name": "ABC Supplier",
    "batch_code": "T",
    "arrival_date": "2026-09-25",
    "brand_name": "GE",
    "model": "Voluson E8",
    "serial_number": "SN-VOL-001",
    "machine_id": "1T",
    "probe_model": ["C1-5", "ML6-15", "RIC5-9"],
    "probe_serial": ["ABC123", "ABC456", "ABC789"],
    "printer_model_name": "UP-D898MD",
    "notes": "",
}, follow_redirects=False)
check("receive POST redirects to saved screen", r.status_code == 302 and "saved=" in r.headers["Location"],
      r.headers.get("Location", ""))
saved_url = r.headers["Location"]

m1 = one(DB, "SELECT * FROM machines WHERE machine_id = '1T'")
check("machine 1T created", m1 is not None)
check("machine status/location", m1 and m1["status"] == "In Stock" and m1["current_location"] == "Company")
check("machine has batch + vendor + brand + date",
      m1 and m1["batch_id"] and m1["vendor_id"] and m1["brand_id"] and m1["acquisition_date"] == "2026-09-25")
M1 = m1["id"]

probes1 = rows(DB, "SELECT * FROM probes WHERE assigned_machine_id = ? ORDER BY internal_id", M1)
check("3 probes linked to machine", len(probes1) == 3, str(len(probes1)))
check("probes are individual records with own IDs + serials",
      all(p["internal_id"] and p["serial_number"] for p in probes1))
check("probe serials correct", {p["serial_number"] for p in probes1} == {"ABC123", "ABC456", "ABC789"})
check("probes status With Machine", all(p["status"] == "With Machine" for p in probes1))

prn1 = one(DB, "SELECT * FROM printers WHERE assigned_machine_id = ?", M1)
check("printer unit created and assigned", prn1 is not None and prn1["name_model"] == "UP-D898MD")
check("printer status With Machine", prn1 and prn1["status"] == "With Machine")

recv = rows(DB, "SELECT * FROM movements WHERE machine_id = ? AND movement_type = 'Received'", M1)
check("machine has Received history", len(recv) == 1 and recv[0]["movement_date"] == "2026-09-25")
pre_recv = rows(DB, "SELECT * FROM movements WHERE probe_id IS NOT NULL AND movement_type = 'Received'")
check("every probe has Received history", len(pre_recv) == 3, str(len(pre_recv)))
prn_recv = rows(DB, "SELECT * FROM movements WHERE printer_id IS NOT NULL AND movement_type = 'Received'")
check("printer has Received history", len(prn_recv) >= 1)

print("=== smart defaults after save ===")
r = client.get(saved_url)
html = r.get_data(as_text=True)
check("saved banner shown", "saved successfully" in html and "Add another machine to Batch T" in html)
check("provider remembered", 'value="ABC Supplier"' in html)
check("batch remembered", 'value="T"' in html)
check("brand remembered", 'value="GE"' in html)
check("model remembered", 'value="Voluson E8"' in html)
check("arrival date remembered", 'value="2026-09-25"' in html)
check("machine serial cleared", 'id="serial_number"' in html and 'value="SN-VOL-001"' not in html)
check("machine ID suggestion advanced to 2T", 'id="machine_id" name="machine_id" maxlength="20"\n               value="2T"' in html
      or ('value="2T"' in html and 'id="machine_id"' in html), "no 2T suggestion")
check("probe rows cleared", "ABC123" not in html)
check("printer not preselected for next machine",
      'name="printer_catalog_id">\n            <option value="">No printer with this machine</option>' in html
      or 'selected' not in html.split('name="printer_catalog_id"')[1].split("</select>")[0])

r = client.get("/receive?resume=%d" % M1)
check("resume screen ready for next machine", "Ready for the next machine in Batch T" in r.get_data(as_text=True))

print("=== duplicate protection ===")
before = one(DB, "SELECT COUNT(*) AS n FROM machines")["n"]
r = client.post("/receive", data={
    "provider_name": "ABC Supplier", "batch_code": "T", "arrival_date": "2026-09-25",
    "brand_name": "GE", "model": "Voluson E8", "serial_number": "SN-OTHER",
    "machine_id": "1T", "probe_model": [""], "probe_serial": [""],
})
html = r.get_data(as_text=True)
check("duplicate machine ID rejected", r.status_code == 200 and "Machine ID 1T already exists" in html)
check("entered values kept after error", 'value="SN-OTHER"' in html)

r = client.post("/receive", data={
    "provider_name": "ABC Supplier", "batch_code": "T", "arrival_date": "2026-09-25",
    "brand_name": "GE", "model": "Voluson E8", "serial_number": "SN-VOL-001",
    "machine_id": "2T", "probe_model": [""], "probe_serial": [""],
})
check("duplicate machine serial rejected", "already exists" in r.get_data(as_text=True))

r = client.post("/receive", data={
    "provider_name": "ABC Supplier", "batch_code": "T", "arrival_date": "2026-09-25",
    "brand_name": "GE", "model": "Voluson E8", "serial_number": "SN-DUP-PROBE",
    "machine_id": "2T", "probe_model": ["C1-5"], "probe_serial": ["ABC123"],
})
html = r.get_data(as_text=True)
check("duplicate probe serial rejected with location",
      "Probe serial ABC123 already exists" in html and "Machine 1T" in html)
check("no machine created by failed posts", one(DB, "SELECT COUNT(*) AS n FROM machines")["n"] == before)

print("=== 5. OPEN MACHINE ===")
r = client.get("/machines/%d" % M1)
html = r.get_data(as_text=True)
check("machine detail opens", r.status_code == 200)
for token in ["Machine 1T", "GE", "Voluson E8", "SN-VOL-001", "ABC Supplier", "2026-09-25",
              "C1-5", "ABC123", "ML6-15", "ABC456", "RIC5-9", "ABC789", "UP-D898MD", "Received"]:
    check(f"detail shows {token}", token in html)

print("=== 6. SEND MACHINE + ACCESSORIES TO WORKSHOP ===")
r = client.get("/machines/%d/send?type=workshop" % M1)
html = r.get_data(as_text=True)
check("send screen opens", r.status_code == 200)
check("machine pre-checked", 'value="machine"' in html and 'checked' in html)
for p in probes1:
    check(f"probe {p['serial_number']} listed", p["serial_number"] in html)
check("printer listed", "UP-D898MD" in html)

items = ["machine"] + [f"probe:{p['id']}" for p in probes1] + [f"printer:{prn1['id']}"]
r = client.post("/machines/%d/send" % M1, data={
    "destination_type": "workshop", "destination": "Smart Workshop",
    "movement_date": TODAY, "reason": "Service", "notes": "full set",
    "item": items,
}, follow_redirects=True)
check("send succeeds", r.status_code == 200)
m = one(DB, "SELECT * FROM machines WHERE id = ?", M1)
check("machine now With Workshop", m["status"] == "With Workshop" and m["current_location"] == "Workshop")
for p in probes1:
    row = one(DB, "SELECT * FROM probes WHERE id = ?", p["id"])
    check(f"probe {p['serial_number']} sent too", row["status"] == "With Workshop" and row["current_location"] == "Workshop")
prn = one(DB, "SELECT * FROM printers WHERE id = ?", prn1["id"])
check("printer sent too", prn["status"] == "With Workshop")
sent = rows(DB, "SELECT * FROM movements WHERE movement_type = 'Send to Workshop' AND machine_id IS NOT NULL OR (movement_type='Send to Workshop' AND probe_id IS NOT NULL) OR (movement_type='Send to Workshop' AND printer_id IS NOT NULL)")
check("5 send movement rows (machine + 3 probes + printer)", len(sent) == 5, str(len(sent)))
group = sent[0]["group_ref"]
check("send rows share one group_ref", group and all(s["group_ref"] == group for s in sent))

print("=== 7. RETURN (originally sent shown, warning when incomplete) ===")
r = client.get("/machines/%d/return" % M1)
html = r.get_data(as_text=True)
check("return screen opens", r.status_code == 200)
check("originally sent section", "Originally sent" in html)
check("destination remembered", "Smart Workshop" in html)
for token in ["Machine 1T", "ABC123", "ABC456", "ABC789", "UP-D898MD"]:
    check(f"originally sent shows {token}", token in html)

keep_back = f"probe:{probes1[1]['id']}"
return_all = ["machine", f"probe:{probes1[0]['id']}", f"probe:{probes1[2]['id']}", f"printer:{prn1['id']}"]
r = client.post("/machines/%d/return" % M1, data={
    "movement_date": TODAY, "reason": "Fixed", "notes": "", "item": return_all,
}, follow_redirects=True)
html = r.get_data(as_text=True)
check("partial return warns", "1 item has not been returned" in html, html[:0])
m = one(DB, "SELECT * FROM machines WHERE id = ?", M1)
check("machine back In Stock", m["status"] == "In Stock" and m["current_location"] == "Company")
left = one(DB, "SELECT * FROM probes WHERE id = ?", probes1[1]["id"])
check("unchecked probe stayed at workshop", left["status"] == "With Workshop")
ret = rows(DB, "SELECT * FROM movements WHERE movement_type = 'Return'")
check("return movements recorded", len(ret) == 4, str(len(ret)))
check("return linked to original send group", all(r_["related_group_ref"] == group for r_ in ret))

r = client.post("/machines/%d/return" % M1, data={
    "movement_date": TODAY, "reason": "", "notes": "last one", "item": [keep_back],
}, follow_redirects=True)
left = one(DB, "SELECT * FROM probes WHERE id = ?", probes1[1]["id"])
check("last probe returned", left["status"] == "With Machine")
check("full return success message", "returned to the company" in r.get_data(as_text=True))

print("=== 8. SELL MACHINE WITH ACCESSORIES ===")
r = client.get("/machines/%d/sell" % M1)
html = r.get_data(as_text=True)
check("sell screen opens", r.status_code == 200)
for token in ["Machine 1T", "ABC123", "ABC456", "ABC789", "UP-D898MD"]:
    check(f"sell screen prelists {token}", token in html)
items = ["machine"] + [f"probe:{p['id']}" for p in probes1] + [f"printer:{prn1['id']}"]
r = client.post("/machines/%d/sell" % M1, data={
    "customer_name": "City Hospital", "sale_date": TODAY, "price": "5000",
    "invoice_reference": "INV-1", "notes": "", "item": items,
})
check("sale redirects to sale detail", r.status_code == 302 and "/sales/" in r.headers["Location"])
sale_url = r.headers["Location"]
m = one(DB, "SELECT * FROM machines WHERE id = ?", M1)
check("machine Sold", m["status"] == "Sold")
for p in probes1:
    row = one(DB, "SELECT * FROM probes WHERE id = ?", p["id"])
    check(f"probe {p['serial_number']} Sold + detached",
          row["status"] == "Sold" and row["assigned_machine_id"] is None)
prn = one(DB, "SELECT * FROM printers WHERE id = ?", prn1["id"])
check("printer Sold + detached", prn["status"] == "Sold" and prn["assigned_machine_id"] is None)
sale_items = rows(DB, "SELECT * FROM sale_items WHERE sale_id = (SELECT MAX(id) FROM sales)")
check("sale has machine + 3 probes + printer", len(sale_items) == 5, str(len(sale_items)))
check("machine is main item", any(si["is_main_item"] == 1 and si["item_type"] == "machine" for si in sale_items))
cust = one(DB, "SELECT * FROM customers WHERE name = 'City Hospital'")
check("customer created/linked", cust is not None)
r = client.get(sale_url)
check("sale detail opens", r.status_code == 200)

r = client.get("/machines/%d" % M1)
html = r.get_data(as_text=True)
check("sold machine detail shows sale", "Sold on" in html or "Sale" in html)
check("sold machine no longer lists attached probes as active set",
      'Attached probes' not in html or 'No probes attached' in html)

print("=== 9. RECEIVE SECOND MACHINE (defaults + printer unit reuse) ===")
printer_models = client.get("/api/printer-models").get_json()
model_id = [p for p in printer_models if p["name_model"] == "UP-D898MD"][0]["id"]
con = sqlite3.connect(DB)
con.execute(
    """INSERT INTO printers (internal_id, catalog_product_id, name_model, quantity, status, current_location)
       VALUES ('PRT-00500', ?, 'UP-D898MD', 1, 'Available', 'Company')""",
    (model_id,),
)
con.commit()
free_id = con.execute("SELECT id FROM printers WHERE status='Available' LIMIT 1").fetchone()[0]
con.close()

r = client.get("/receive")
html = r.get_data(as_text=True)
check("second visit keeps provider", 'value="ABC Supplier"' in html)
check("second visit keeps batch", 'value="T"' in html)
check("second visit keeps brand/model", 'value="GE"' in html and 'value="Voluson E8"' in html)

r = client.post("/receive", data={
    "provider_name": "ABC Supplier", "batch_code": "T", "arrival_date": "2026-09-25",
    "brand_name": "GE", "model": "Voluson E8", "serial_number": "SN-VOL-002",
    "machine_id": "2T", "probe_model": ["C1-5"], "probe_serial": ["XYZ111"],
    "printer_catalog_id": str(model_id),
})
check("second machine saved", r.status_code == 302)
m2 = one(DB, "SELECT * FROM machines WHERE machine_id = '2T'")
check("machine 2T created", m2 is not None)
M2 = m2["id"]
reused = one(DB, "SELECT * FROM printers WHERE id = ?", free_id)
check("available printer unit reused (not duplicated)",
      reused["status"] == "With Machine" and reused["assigned_machine_id"] == M2)
total_units = one(DB, "SELECT COUNT(*) AS n FROM printers WHERE name_model = 'UP-D898MD'")["n"]
check("printer unit count unchanged", total_units == 2, str(total_units))
kept = one(DB, "SELECT * FROM printers WHERE id = ?", prn1["id"])
check("sold printer untouched by reuse", kept["status"] == "Sold")

print("=== 10. SELL ONE PROBE SEPARATELY ===")
probe2 = one(DB, "SELECT * FROM probes WHERE assigned_machine_id = ? AND serial_number = 'XYZ111'", M2)
r = client.get("/probes/%d/sell" % probe2["id"])
check("probe sell screen opens", r.status_code == 200 and "XYZ111" in r.get_data(as_text=True))
r = client.post("/probes/%d/sell" % probe2["id"], data={
    "customer_name": "Clinic Two", "sale_date": TODAY, "price": "700",
    "item": f"probe:{probe2['id']}",
})
check("probe sale recorded", r.status_code == 302)
p2 = one(DB, "SELECT * FROM probes WHERE id = ?", probe2["id"])
check("probe Sold", p2["status"] == "Sold")
check("probe detached from machine", p2["assigned_machine_id"] is None)
m2 = one(DB, "SELECT * FROM machines WHERE id = ?", M2)
check("machine 2T still In Stock", m2["status"] == "In Stock")
r = client.get("/machines/%d" % M2)
html = r.get_data(as_text=True)
check("machine 2T no longer shows XYZ111 as attached", "XYZ111" not in html)
check("probe still has its own record + history", client.get("/probes/%d" % probe2["id"]).status_code == 200)

print("=== history integrity ===")
hist1 = [h["movement_type"] for h in rows(DB, "SELECT * FROM movements WHERE machine_id = ? ORDER BY id", M1)]
check("machine 1 history order", hist1 == ["Received", "Send to Workshop", "Return", "Sale"], str(hist1))
hist_probe = [h["movement_type"] for h in rows(DB, "SELECT * FROM movements WHERE probe_id = ? ORDER BY id", probes1[0]["id"])]
check("probe history order", hist_probe == ["Received", "Send to Workshop", "Return", "Sale"], str(hist_probe))
hist_left = [h["movement_type"] for h in rows(DB, "SELECT * FROM movements WHERE probe_id = ? ORDER BY id", probes1[1]["id"])]
check("left-behind probe history", hist_left == ["Received", "Send to Workshop", "Return", "Sale"], str(hist_left))
left_moves = rows(DB, "SELECT * FROM movements WHERE probe_id = ? AND movement_type = 'Return'", probes1[1]["id"])
check("left-behind probe returned in second return",
      len(left_moves) == 1 and left_moves[0]["notes"] == "last one")

print("=== dealer path (send + return) ===")
prn2 = one(DB, "SELECT * FROM printers WHERE assigned_machine_id = ?", M2)
r = client.post("/machines/%d/send" % M2, data={
    "destination_type": "dealer", "destination": "Trade Dealer",
    "movement_date": TODAY, "reason": "", "notes": "",
    "item": ["machine", f"printer:{prn2['id']}"],
}, follow_redirects=True)
m2 = one(DB, "SELECT * FROM machines WHERE id = ?", M2)
check("machine 2T With Dealer", m2["status"] == "With Dealer" and m2["current_location"] == "Dealer")
r = client.post("/machines/%d/return" % M2, data={
    "movement_date": TODAY, "reason": "", "notes": "",
    "item": ["machine", f"printer:{prn2['id']}"],
}, follow_redirects=True)
m2 = one(DB, "SELECT * FROM machines WHERE id = ?", M2)
check("machine 2T returned from dealer", m2["status"] == "In Stock")
hist2 = [h["movement_type"] for h in rows(DB, "SELECT * FROM movements WHERE machine_id = ? ORDER BY id", M2)]
check("machine 2 history", hist2 == ["Received", "Send to Dealer", "Return"], str(hist2))

print("=== copy previous setup ===")
r = client.get("/receive?copy=%d" % M2)
html = r.get_data(as_text=True)
check("copy screen opens", r.status_code == 200)
check("copy keeps brand/model/provider/batch",
      'value="GE"' in html and 'value="Voluson E8"' in html and 'value="ABC Supplier"' in html)
check("copy carries probe model without serial", "C1-5" in html and "XYZ111" not in html)
check("copy does not reuse machine serial", "SN-VOL-002" not in html)

print("=== all pages still render ===")
for page in ["/", "/receive", "/machines", "/machines/%d" % M1, "/machines/%d" % M2,
             "/probes", "/probes/%d" % probe2["id"], "/printers", "/parts", "/batches",
             "/catalogue", "/customers", "/vendors", "/sales", f"/machines/{M1}/edit",
             "/api/printer-models", "/api/probe-serial-check?serial=ABC123",
             "/api/machine-id-suggestion?batch_code=T"]:
    rr = client.get(page)
    check(f"GET {page}", rr.status_code == 200, str(rr.status_code))

print()
if FAILURES:
    print(f"{len(FAILURES)} FAILURES:")
    for f in FAILURES:
        print("  -", f)
    raise SystemExit(1)
print("ALL STAGE 3 WORKFLOW TESTS PASSED")
