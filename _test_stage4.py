import os
import re
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


def metric(html, label):
    m = re.search(
        r'metric-label">' + re.escape(label) + r'</span><strong>([\d,]+)</strong>', html
    )
    return m.group(1) if m else None


def last_ref():
    r = one(DB, "SELECT reference FROM movements ORDER BY id DESC LIMIT 1")
    return r["reference"] if r else None


REF_N = [0]


def want_ref():
    REF_N[0] += 1
    return f"MOV-{REF_N[0]:05d}"


tmpdir = tempfile.mkdtemp(prefix="stage4-test-")
DB = os.path.join(tmpdir, "test.db")
app = create_app({"DATABASE": DB, "TESTING": True})
client = app.test_client()

# ═══════════════════════════════════════════════════════════════════════════
print("=== setup: receive machine 3T (2 probes + printer) ===")
r = client.get("/receive")
check("receive page opens", r.status_code == 200)

r = client.post("/receive", data={
    "provider_name": "Delta Supply", "batch_code": "B4", "arrival_date": TODAY,
    "brand_name": "Philips", "model": "EPIQ 70", "serial_number": "SN-S4-001",
    "machine_id": "3T",
    "probe_model": ["C1-5", "ML6-15"], "probe_serial": ["S4A", "S4B"],
    "printer_model_name": "ZT411", "notes": "",
})
check("machine 3T received", r.status_code == 302)
m3 = one(DB, "SELECT * FROM machines WHERE machine_id = '3T'")
check("machine 3T exists", m3 is not None)
M3 = m3["id"]
probes = rows(DB, "SELECT * FROM probes WHERE assigned_machine_id = ? ORDER BY internal_id", M3)
check("2 probes created", len(probes) == 2, str(len(probes)))
P1, P2 = probes[0], probes[1]
prn = one(DB, "SELECT * FROM printers WHERE assigned_machine_id = ?", M3)
check("printer created", prn is not None and prn["name_model"] == "ZT411")
PRN = prn["id"]

recv_ref = one(DB, "SELECT reference FROM movements WHERE group_ref = ?", f"rcv-3T")["reference"]
check("receive got MOV-00001", recv_ref == want_ref(), str(recv_ref))
recv_rows = rows(DB, "SELECT reference FROM movements WHERE group_ref = ?", "rcv-3T")
check("all receive rows share the reference",
      len(recv_rows) == 4 and all(r_["reference"] == "MOV-00001" for r_ in recv_rows))

# ═══════════════════════════════════════════════════════════════════════════
print("=== workshop / dealer management ===")
r = client.post("/workshops/new", data={
    "name": "Alpha Workshop", "city": "Lahore", "contact": "Mr Khan",
    "phone": "0300", "address": "", "notes": "",
})
check("workshop created via form", r.status_code == 302)
alpha = one(DB, "SELECT * FROM workshops WHERE name = 'Alpha Workshop'")
check("alpha workshop row + city", alpha is not None and alpha["city"] == "Lahore")

r = client.post("/workshops/new", data={"name": "alpha workshop"})
html = r.get_data(as_text=True)
check("duplicate workshop name rejected", r.status_code == 200 and "already exists" in html)

r = client.post("/api/workshops", json={"name": "Beta Workshop", "city": "Karachi"})
data = r.get_json()
check("quick-add workshop API", r.status_code == 200 and data.get("existing") is False and data.get("id"))
beta_id = data["id"]
r = client.post("/api/workshops", json={"name": "Beta Workshop"})
check("quick-add duplicate returns existing", r.get_json().get("existing") is True)
r = client.post("/api/workshops", json={"name": "  "})
check("quick-add empty name rejected", r.status_code == 400 and "required" in r.get_json()["error"])

r = client.post("/api/dealers", json={"name": "Gamma Dealer", "city": "Sialkot"})
data = r.get_json()
check("quick-add dealer API", r.status_code == 200 and data.get("existing") is False)
gamma_id = data["id"]

r = client.get("/workshops")
html = r.get_data(as_text=True)
check("workshops list opens", r.status_code == 200)
check("workshops list shows both", "Alpha Workshop" in html and "Beta Workshop" in html)
check("workshops list shows city", "Lahore" in html)
r = client.get("/workshops?search=beta")
html = r.get_data(as_text=True)
check("workshop search filters", "Beta Workshop" in html and "Alpha Workshop" not in html)
r = client.get("/dealers")
check("dealers list shows Gamma", r.status_code == 200 and "Gamma Dealer" in r.get_data(as_text=True))
r = client.post(f"/workshops/{alpha['id']}/toggle")
check("workshop deactivate toggle", one(DB, "SELECT is_archived FROM workshops WHERE id = ?", alpha["id"])["is_archived"] == 1)
client.post(f"/workshops/{alpha['id']}/toggle")
check("workshop activate toggle", one(DB, "SELECT is_archived FROM workshops WHERE id = ?", alpha["id"])["is_archived"] == 0)

# ═══════════════════════════════════════════════════════════════════════════
print("=== TEST 1: full movement (machine + probes + printer to workshop) ===")
r = client.get("/movements")
check("movement centre opens", r.status_code == 200 and "Send to Workshop" in r.get_data(as_text=True))

r = client.get(f"/machines/{M3}/send?type=workshop")
html = r.get_data(as_text=True)
check("send screen opens", r.status_code == 200)
check("send screen lists set", "S4A" in html and "S4B" in html and "ZT411" in html)
check("send screen offers workshops", "Alpha Workshop" in html and "Beta Workshop" in html)
check("send date defaults to today", f'value="{TODAY}"' in html)
check("quick-add buttons present", 'js-add-partner' in html and 'id="modal-workshop"' in html)

items = ["machine", f"probe:{P1['id']}", f"probe:{P2['id']}", f"printer:{PRN}"]
r = client.post(f"/machines/{M3}/send", data={
    "destination_type": "workshop", "destination": "Alpha Workshop",
    "movement_date": TODAY, "reason": "Service", "notes": "full set",
    "item": items,
}, follow_redirects=True)
html = r.get_data(as_text=True)
check("send succeeds", r.status_code == 200)
check("send flash names destination + reference",
      "4 item(s) sent to Alpha Workshop" in html and "Movement MOV-00002 recorded" in html, html[:0])
check("send reference number", last_ref() == want_ref(), str(last_ref()))

m3 = one(DB, "SELECT * FROM machines WHERE id = ?", M3)
check("machine With Workshop", m3["status"] == "With Workshop" and m3["current_location"] == "Workshop")
for p, serial in ((P1, "S4A"), (P2, "S4B")):
    row = one(DB, "SELECT * FROM probes WHERE id = ?", p["id"])
    check(f"probe {serial} sent with machine",
          row["status"] == "With Workshop" and row["current_location"] == "Workshop")
prow = one(DB, "SELECT * FROM printers WHERE id = ?", PRN)
check("printer sent with machine", prow["status"] == "With Workshop")

send_rows = rows(DB, "SELECT * FROM movements WHERE movement_type = 'Send to Workshop' AND reference = 'MOV-00002'")
check("4 movement rows in one group", len(send_rows) == 4, str(len(send_rows)))
check("send group uniform", len({r_["group_ref"] for r_ in send_rows}) == 1)
G1 = send_rows[0]["group_ref"]
check("send rows carry workshop + destination",
      all(r_["workshop_id"] == alpha["id"] and r_["to_location"] == "Alpha Workshop" for r_ in send_rows))
check("send rows share reference", all(r_["reference"] == "MOV-00002" for r_ in send_rows))

r = client.get(f"/machines/{M3}")
html = r.get_data(as_text=True)
check("machine detail shows send in timeline",
      "Sent to Workshop" in html and "Alpha Workshop" in html and "MOV-00002" in html)
check("machine detail offers return from workshop", "Return from Workshop" in html)
check("machine detail collapses set into one event", "Items:" in html and "Machine + 2 probes + printer" in html)

r = client.get("/away")
html = r.get_data(as_text=True)
check("away screen opens", r.status_code == 200)
check("away shows 4 items", "4 items away" in html, html[:0])
for token in ["Machine 3T", "Alpha Workshop", "MOV-00002"]:
    check(f"away shows {token}", token in html)
check("away shows days away", re.search(r"Days away", html) is not None)
r = client.get("/away?type=machine")
html = r.get_data(as_text=True)
check("away type filter machine", "Machine 3T" in html and "S4A" not in html)
r = client.get("/away?workshop=Beta%20Workshop")
check("away workshop filter empties", "Nothing is away" in r.get_data(as_text=True))
r = client.get(f"/away?search=3T")
check("away search filter", "Machine 3T" in r.get_data(as_text=True))

r = client.get("/")
html = r.get_data(as_text=True)
check("dashboard opens", r.status_code == 200)
check("dashboard away total", "4 items currently away" in html, html[:0])
check("dashboard machine workshop count", metric(html, "At workshop") == "1", str(metric(html, "At workshop")))
check("dashboard shows active movement row", "Alpha Workshop" in html and "MOV-00002" in html)

# ═══════════════════════════════════════════════════════════════════════════
print("=== TEST 2: return with a missing probe ===")
r = client.get(f"/machines/{M3}/return")
html = r.get_data(as_text=True)
check("return screen opens", r.status_code == 200)
check("originally sent section", "Originally sent" in html)
check("destination + original reference shown",
      "Alpha Workshop" in html and "MOV-00002" in html)
for token in ["3T", "S4A", "S4B", "ZT411"]:
    check(f"originally sent lists {token}", token in html)

r = client.post(f"/machines/{M3}/return", data={
    "movement_date": TODAY, "reason": "Fixed", "notes": "",
    "item": ["machine", f"probe:{P1['id']}", f"printer:{PRN}"],
}, follow_redirects=True)
html = r.get_data(as_text=True)
check("partial return warns about missing probe", "1 item has not been returned" in html, html[:0])
check("partial return reference", last_ref() == want_ref(), str(last_ref()))

m3 = one(DB, "SELECT * FROM machines WHERE id = ?", M3)
check("machine back In Stock", m3["status"] == "In Stock" and m3["current_location"] == "Company")
p1 = one(DB, "SELECT * FROM probes WHERE id = ?", P1["id"])
p2 = one(DB, "SELECT * FROM probes WHERE id = ?", P2["id"])
check("returned probe back with machine", p1["status"] == "With Machine")
check("missing probe stayed at workshop", p2["status"] == "With Workshop" and p2["current_location"] == "Workshop")
prw = one(DB, "SELECT * FROM printers WHERE id = ?", PRN)
check("printer back with machine", prw["status"] == "With Machine")

rets = rows(DB, "SELECT * FROM movements WHERE reference = 'MOV-00003'")
check("3 return rows recorded", len(rets) == 3, str(len(rets)))
check("returns link to original send", all(r_["related_group_ref"] == G1 for r_ in rets))
check("return group uniform", len({r_["group_ref"] for r_ in rets}) == 1)

r = client.get(f"/machines/{M3}/return")
html = r.get_data(as_text=True)
check("return still allowed for straggler probe", r.status_code == 200 and "S4B" in html)
check("machine not listed as out", "returned to the company" not in html)

r = client.post(f"/machines/{M3}/return", data={
    "movement_date": TODAY, "reason": "", "notes": "last one",
    "item": [f"probe:{P2['id']}"],
}, follow_redirects=True)
html = r.get_data(as_text=True)
check("straggler probe returned", "returned to the company" in html, html[:0])
check("second return reference", last_ref() == want_ref(), str(last_ref()))
p2 = one(DB, "SELECT * FROM probes WHERE id = ?", P2["id"])
check("probe back with machine", p2["status"] == "With Machine")

r = client.get("/away")
check("away empty again", "Nothing is away" in r.get_data(as_text=True))

# ═══════════════════════════════════════════════════════════════════════════
print("=== TEST 3: separate probe movement ===")
r = client.post(f"/probes/{P1['id']}/send", data={
    "destination_type": "workshop", "destination": "Beta Workshop",
    "movement_date": TODAY, "reason": "calibration", "notes": "",
}, follow_redirects=True)
html = r.get_data(as_text=True)
check("probe send succeeds", "sent to Beta Workshop" in html, html[:0])
check("probe send reference", last_ref() == want_ref(), str(last_ref()))

p1 = one(DB, "SELECT * FROM probes WHERE id = ?", P1["id"])
check("probe away at Beta", p1["status"] == "With Workshop" and p1["current_location"] == "Workshop")
m3 = one(DB, "SELECT * FROM machines WHERE id = ?", M3)
check("machine untouched", m3["status"] == "In Stock")

r = client.get(f"/probes/{P1['id']}")
html = r.get_data(as_text=True)
check("probe timeline shows send", "Sent to Workshop" in html and "Beta Workshop" in html and "MOV-00005" in html)
check("probe detail shows away destination", "Beta Workshop" in html)
check("probe detail offers return", "Return from" in html)

r = client.get("/away?type=probe")
html = r.get_data(as_text=True)
check("away probe filter shows probe only", "S4A" in html and "Machine 3T" not in html)
r = client.get("/away?workshop=Alpha%20Workshop")
check("away alpha filter empty", "Nothing is away" in r.get_data(as_text=True))

# ═══════════════════════════════════════════════════════════════════════════
print("=== TEST 4: dealer flow + wrong-origin return blocked ===")
r = client.get(f"/machines/{M3}/send?type=dealer")
html = r.get_data(as_text=True)
check("send screen marks stray probe as away", "Currently away — Beta Workshop" in html, html[:0])

r = client.post(f"/machines/{M3}/send", data={
    "destination_type": "dealer", "destination": "Gamma Dealer",
    "movement_date": TODAY, "reason": "", "notes": "",
    "item": ["machine"],
}, follow_redirects=True)
html = r.get_data(as_text=True)
check("dealer send keeps set behind",
      "1 item(s) sent to Gamma Dealer" in html and "2 item(s) stayed behind" in html, html[:0])
check("dealer send reference", last_ref() == want_ref(), str(last_ref()))
m3 = one(DB, "SELECT * FROM machines WHERE id = ?", M3)
check("machine With Dealer", m3["status"] == "With Dealer" and m3["current_location"] == "Dealer")
dealer_send = one(DB, "SELECT * FROM movements WHERE reference = 'MOV-00006'")
check("dealer recorded on movement", dealer_send["dealer_id"] == gamma_id and dealer_send["to_location"] == "Gamma Dealer")

r = client.get(f"/machines/{M3}/return")
html = r.get_data(as_text=True)
check("return screen shows dealer destination", "Gamma Dealer" in html)

r = client.post(f"/machines/{M3}/return", data={
    "movement_date": TODAY, "reason": "", "notes": "",
    "item": ["machine", f"probe:{P1['id']}"],
})
html = r.get_data(as_text=True)
check("wrong-origin return blocked",
      r.status_code == 200 and "cannot be returned from Gamma Dealer" in html, html[:0])
m3 = one(DB, "SELECT * FROM machines WHERE id = ?", M3)
p1 = one(DB, "SELECT * FROM probes WHERE id = ?", P1["id"])
check("nothing changed by blocked return",
      m3["status"] == "With Dealer" and p1["status"] == "With Workshop")
check("blocked return consumed no reference", last_ref() == "MOV-00006")

r = client.post(f"/machines/{M3}/return", data={
    "movement_date": TODAY, "reason": "sold demo", "notes": "",
    "item": ["machine"],
}, follow_redirects=True)
html = r.get_data(as_text=True)
check("dealer return succeeds", "1 item returned to the company" in html, html[:0])
check("dealer return reference", last_ref() == want_ref(), str(last_ref()))
m3 = one(DB, "SELECT * FROM machines WHERE id = ?", M3)
check("machine back from dealer", m3["status"] == "In Stock")
p2 = one(DB, "SELECT * FROM probes WHERE id = ?", P2["id"])
prw = one(DB, "SELECT * FROM printers WHERE id = ?", PRN)
check("set stayed at company during dealer trip",
      p2["status"] == "With Machine" and prw["status"] == "With Machine")

# ═══════════════════════════════════════════════════════════════════════════
print("=== TEST 5: separate probe sale (guarded while away, clean when back) ===")
before_sales = one(DB, "SELECT COUNT(*) AS n FROM sales")["n"]
r = client.post(f"/probes/{P1['id']}/sell", data={
    "customer_name": "Clinic Four", "sale_date": TODAY, "price": "700",
    "item": f"probe:{P1['id']}",
})
html = r.get_data(as_text=True)
check("sale of away probe blocked",
      r.status_code == 200 and "is currently with Beta Workshop. Return it before selling." in html, html[:0])
p1 = one(DB, "SELECT * FROM probes WHERE id = ?", P1["id"])
check("probe still away after blocked sale", p1["status"] == "With Workshop")
check("no sale recorded", one(DB, "SELECT COUNT(*) AS n FROM sales")["n"] == before_sales)

r = client.post(f"/probes/{P1['id']}/return", data={
    "movement_date": TODAY, "reason": "", "notes": "",
}, follow_redirects=True)
check("probe return succeeds", "returned to the company" in r.get_data(as_text=True))
check("probe return reference", last_ref() == want_ref(), str(last_ref()))
p1 = one(DB, "SELECT * FROM probes WHERE id = ?", P1["id"])
check("probe back", p1["status"] == "With Machine")

r = client.post(f"/probes/{P1['id']}/sell", data={
    "customer_name": "Clinic Four", "sale_date": TODAY, "price": "700",
    "item": f"probe:{P1['id']}",
})
check("probe sale succeeds now", r.status_code == 302 and "/sales/" in r.headers["Location"])
p1 = one(DB, "SELECT * FROM probes WHERE id = ?", P1["id"])
check("probe sold + detached", p1["status"] == "Sold" and p1["assigned_machine_id"] is None)
sale_row = one(DB, "SELECT * FROM movements WHERE movement_type = 'Sale' ORDER BY id DESC LIMIT 1")
check("sale carries reference", sale_row["reference"] == want_ref(), str(sale_row["reference"]))
check("sale group uniform reference",
      one(DB, "SELECT COUNT(DISTINCT reference) AS n FROM movements WHERE group_ref = ?",
          sale_row["group_ref"])["n"] == 1)
r = client.get(f"/machines/{M3}")
check("sold probe leaves the set", "S4A" not in r.get_data(as_text=True))

# ═══════════════════════════════════════════════════════════════════════════
print("=== TEST 6: invalid actions + reversal ===")
r = client.get(f"/probes/{P1['id']}/send", follow_redirects=True)
check("send of sold probe blocked", "is sold and cannot be sent" in r.get_data(as_text=True))

r = client.post(f"/probes/{P2['id']}/return", data={"movement_date": TODAY}, follow_redirects=True)
check("return of in-stock probe blocked", "is not currently away" in r.get_data(as_text=True))

r = client.post(f"/machines/{M3}/send", data={
    "destination_type": "workshop", "destination": "Alpha Workshop",
    "movement_date": TODAY, "reason": "", "notes": "",
    "item": ["machine", f"probe:{P2['id']}", f"printer:{PRN}"],
}, follow_redirects=True)
check("second workshop send succeeds", "3 item(s) sent to Alpha Workshop" in r.get_data(as_text=True))
check("second send reference", last_ref() == want_ref(), str(last_ref()))
G2 = one(DB, "SELECT group_ref FROM movements WHERE reference = 'MOV-00010'")["group_ref"]

before_sales = one(DB, "SELECT COUNT(*) AS n FROM sales")["n"]
r = client.post(f"/machines/{M3}/sell", data={
    "customer_name": "City Hospital", "sale_date": TODAY, "price": "9000",
    "item": "machine",
})
html = r.get_data(as_text=True)
check("sale of machine blocked while away",
      r.status_code == 200 and "is currently with Alpha Workshop. Return it before selling." in html, html[:0])
m3 = one(DB, "SELECT * FROM machines WHERE id = ?", M3)
check("machine still away after blocked sale", m3["status"] == "With Workshop")
check("no sale rows added", one(DB, "SELECT COUNT(*) AS n FROM sales")["n"] == before_sales)

r = client.post(f"/movements/{G2}/reverse", data={"next": f"/machines/{M3}"}, follow_redirects=True)
html = r.get_data(as_text=True)
check("reversal succeeds", "was reversed" in html and "the original history stays visible" in html, html[:0])
check("reversal reference", last_ref() == want_ref(), str(last_ref()))
m3 = one(DB, "SELECT * FROM machines WHERE id = ?", M3)
p2 = one(DB, "SELECT * FROM probes WHERE id = ?", P2["id"])
prw = one(DB, "SELECT * FROM printers WHERE id = ?", PRN)
check("reversal restores machine", m3["status"] == "In Stock" and m3["current_location"] == "Company")
check("reversal restores probe", p2["status"] == "With Machine")
check("reversal restores printer", prw["status"] == "With Machine")
kept = rows(DB, "SELECT * FROM movements WHERE group_ref = ?", G2)
check("original history kept", len(kept) == 3 and all(r_["movement_type"] == "Send to Workshop" for r_ in kept))
check("originals marked reversed", all(r_["reversed_by_ref"] for r_ in kept))
rev_rows = rows(DB, "SELECT * FROM movements WHERE reference = 'MOV-00011'")
check("correction rows recorded", len(rev_rows) == 3 and all(r_["movement_type"] == "Reversal" for r_ in rev_rows))
check("correction links back", all(r_["related_group_ref"] == G2 for r_ in rev_rows))

r = client.get(f"/machines/{M3}")
html = r.get_data(as_text=True)
check("timeline shows correction", "Movement reversed (correction)" in html)
check("timeline shows reversed-by badge", "Reversed by MOV-00011" in html)

r = client.post(f"/movements/{G2}/reverse", data={"next": "/"}, follow_redirects=True)
check("double reversal blocked", "already been reversed" in r.get_data(as_text=True))

sale_group = one(DB, "SELECT group_ref FROM movements WHERE movement_type = 'Sale' ORDER BY id DESC LIMIT 1")["group_ref"]
r = client.post(f"/movements/{sale_group}/reverse", data={"next": "/"}, follow_redirects=True)
html = r.get_data(as_text=True)
check("sale movement not reversible", "cannot be reversed" in html, html[:0])

r = client.post("/movements/no-such-group/reverse", data={"next": "/"}, follow_redirects=True)
check("unknown movement handled", "Movement not found" in r.get_data(as_text=True))

r = client.post(f"/movements/does-not-exist/reverse", data={"next": "https://evil.example/steal"})
loc = r.headers.get("Location", "")
check("open redirect refused", r.status_code == 302 and "evil.example" not in loc, loc)

r = client.post(f"/machines/{M3}/send", data={
    "destination_type": "workshop", "destination": "Alpha Workshop",
    "movement_date": TODAY, "reason": "", "notes": "",
    "item": ["machine", f"probe:{P2['id']}", f"printer:{PRN}"],
}, follow_redirects=True)
check("third send succeeds", last_ref() == want_ref(), str(last_ref()))
G4 = one(DB, "SELECT group_ref FROM movements WHERE reference = 'MOV-00012'")["group_ref"]
r = client.post(f"/machines/{M3}/return", data={
    "movement_date": TODAY, "reason": "", "notes": "",
    "item": ["machine", f"probe:{P2['id']}", f"printer:{PRN}"],
}, follow_redirects=True)
check("return after third send", "3 items returned to the company" in r.get_data(as_text=True), r.get_data(as_text=True)[:0])
check("return after third send reference", last_ref() == want_ref(), str(last_ref()))

r = client.post(f"/movements/{G4}/reverse", data={"next": f"/machines/{M3}"}, follow_redirects=True)
html = r.get_data(as_text=True)
check("stale reversal blocked", "can no longer be reversed" in html, html[:0])
m3 = one(DB, "SELECT * FROM machines WHERE id = ?", M3)
check("stale reversal changed nothing", m3["status"] == "In Stock")

# ═══════════════════════════════════════════════════════════════════════════
print("=== references, search, screens ===")
refs = rows(DB, """SELECT group_ref, MIN(id) AS first_id, reference
                   FROM movements WHERE reference IS NOT NULL
                   GROUP BY group_ref ORDER BY first_id""")
nums = [int(g["reference"].split("-")[1]) for g in refs]
check("references follow MOV-0000N format",
      all(re.fullmatch(r"MOV-\d{5}", g["reference"]) for g in refs))
check("references strictly sequential, no gaps", nums == list(range(1, len(nums) + 1)), str(nums))
check("one reference per action group",
      len({g["group_ref"] for g in refs}) == len({g["reference"] for g in refs}))

r = client.get("/search?q=MOV-00002")
html = r.get_data(as_text=True)
check("search by reference finds movement", r.status_code == 200 and "MOV-00002" in html and "Movements" in html)
r = client.get("/search?q=Alpha%20Workshop")
check("search finds workshop", "Alpha Workshop" in r.get_data(as_text=True))
r = client.get("/search?q=Gamma%20Dealer")
check("search finds dealer", "Gamma Dealer" in r.get_data(as_text=True))
r = client.get("/search?q=3T")
check("search finds machine", "Machine 3T" in r.get_data(as_text=True) or "3T" in r.get_data(as_text=True))
r = client.get("/search?q=S4B")
check("search finds probe", "S4B" in r.get_data(as_text=True))

for page in ["/", "/movements", "/movements/send", "/movements/return",
             "/movements/send-probe", "/movements/send-printer",
             "/away", "/workshops", "/dealers", "/workshops/new", "/dealers/new",
             f"/machines/{M3}", f"/machines/{M3}/send?type=dealer",
             f"/probes/{P2['id']}", f"/probes/{P2['id']}/send?type=workshop",
             f"/printers/{PRN}", "/search?q=MOV-00001"]:
    rr = client.get(page)
    check(f"GET {page}", rr.status_code == 200, str(rr.status_code))

print("=== db integrity ===")
check("no orphan movement → machine",
      one(DB, """SELECT COUNT(*) AS n FROM movements m
                 LEFT JOIN machines x ON x.id = m.machine_id
                 WHERE m.machine_id IS NOT NULL AND x.id IS NULL""")["n"] == 0)
check("no orphan movement → probe",
      one(DB, """SELECT COUNT(*) AS n FROM movements m
                 LEFT JOIN probes x ON x.id = m.probe_id
                 WHERE m.probe_id IS NOT NULL AND x.id IS NULL""")["n"] == 0)
check("no orphan movement → printer",
      one(DB, """SELECT COUNT(*) AS n FROM movements m
                 LEFT JOIN printers x ON x.id = m.printer_id
                 WHERE m.printer_id IS NOT NULL AND x.id IS NULL""")["n"] == 0)
check("no orphan movement → workshop/dealer",
      one(DB, """SELECT COUNT(*) AS n FROM movements m
                 LEFT JOIN workshops w ON w.id = m.workshop_id
                 LEFT JOIN dealers d ON d.id = m.dealer_id
                 WHERE (m.workshop_id IS NOT NULL AND w.id IS NULL)
                    OR (m.dealer_id IS NOT NULL AND d.id IS NULL)""")["n"] == 0)
check("no orphan assigned machine",
      one(DB, """SELECT
                 (SELECT COUNT(*) FROM probes p LEFT JOIN machines m ON m.id = p.assigned_machine_id
                  WHERE p.assigned_machine_id IS NOT NULL AND m.id IS NULL) +
                 (SELECT COUNT(*) FROM printers p LEFT JOIN machines m ON m.id = p.assigned_machine_id
                  WHERE p.assigned_machine_id IS NOT NULL AND m.id IS NULL) AS n""")["n"] == 0)
check("sold items never stay attached",
      one(DB, """SELECT
                 (SELECT COUNT(*) FROM probes WHERE status = 'Sold' AND assigned_machine_id IS NOT NULL) +
                 (SELECT COUNT(*) FROM printers WHERE status = 'Sold' AND assigned_machine_id IS NOT NULL) AS n""")["n"] == 0)
check("no duplicate movement rows in a group",
      one(DB, """SELECT COUNT(*) AS n FROM (
                 SELECT movement_type, machine_id, probe_id, printer_id, group_ref
                 FROM movements WHERE group_ref IS NOT NULL
                 GROUP BY movement_type, machine_id, probe_id, printer_id, group_ref
                 HAVING COUNT(*) > 1)""")["n"] == 0)
check("machine status matches location",
      one(DB, """SELECT COUNT(*) AS n FROM machines
                 WHERE (status = 'With Workshop' AND current_location != 'Workshop')
                    OR (status = 'With Dealer' AND current_location != 'Dealer')
                    OR (status = 'In Stock' AND current_location != 'Company')""")["n"] == 0)
check("probe/printer status matches location",
      one(DB, """SELECT
                 (SELECT COUNT(*) FROM probes
                  WHERE (status = 'With Workshop' AND current_location != 'Workshop')
                     OR (status = 'With Dealer' AND current_location != 'Dealer')
                     OR (status = 'Available' AND current_location != 'Company')
                     OR (status = 'With Machine' AND current_location != 'Company')) +
                 (SELECT COUNT(*) FROM printers
                  WHERE (status = 'With Workshop' AND current_location != 'Workshop')
                     OR (status = 'With Dealer' AND current_location != 'Dealer')
                     OR (status = 'Available' AND current_location != 'Company')
                     OR (status = 'With Machine' AND current_location != 'Company')) AS n""")["n"] == 0)
check("out items always have a send movement",
      one(DB, """SELECT
                 (SELECT COUNT(*) FROM machines x WHERE x.status IN ('With Workshop','With Dealer')
                  AND NOT EXISTS (SELECT 1 FROM movements m WHERE m.machine_id = x.id
                                  AND m.movement_type IN ('Send to Workshop','Send to Dealer'))) +
                 (SELECT COUNT(*) FROM probes x WHERE x.status IN ('With Workshop','With Dealer')
                  AND NOT EXISTS (SELECT 1 FROM movements m WHERE m.probe_id = x.id
                                  AND m.movement_type IN ('Send to Workshop','Send to Dealer'))) +
                 (SELECT COUNT(*) FROM printers x WHERE x.status IN ('With Workshop','With Dealer')
                  AND NOT EXISTS (SELECT 1 FROM movements m WHERE m.printer_id = x.id
                                  AND m.movement_type IN ('Send to Workshop','Send to Dealer'))) AS n""")["n"] == 0)
check("reversed_by_ref points at a real group",
      one(DB, """SELECT COUNT(*) AS n FROM movements m
                 WHERE m.reversed_by_ref IS NOT NULL
                   AND NOT EXISTS (SELECT 1 FROM movements x WHERE x.group_ref = m.reversed_by_ref)""")["n"] == 0)
check("out item never in two destinations at once",
      one(DB, """SELECT COUNT(*) AS n FROM (
                 SELECT x.id FROM machines x
                 WHERE x.status IN ('With Workshop','With Dealer')
                   AND (SELECT COUNT(DISTINCT m.to_location) FROM movements m
                        WHERE m.machine_id = x.id AND m.movement_type IN ('Send to Workshop','Send to Dealer')
                          AND m.id > COALESCE((SELECT MIN(m2.id) FROM movements m2
                                               WHERE m2.machine_id = x.id AND m2.movement_type = 'Return'
                                               UNION ALL
                                               SELECT MIN(m3.id) FROM movements m3
                                               WHERE m3.machine_id = x.id AND m3.movement_type = 'Reversal'), -1)) > 1)""")["n"] == 0)
check("every movement row has a type + date",
      one(DB, "SELECT COUNT(*) AS n FROM movements WHERE movement_type IS NULL OR movement_date IS NULL")["n"] == 0)

print()
if FAILURES:
    print(f"{len(FAILURES)} FAILURES:")
    for f in FAILURES:
        print("  -", f)
    raise SystemExit(1)
print("ALL STAGE 4 MOVEMENT TESTS PASSED")
