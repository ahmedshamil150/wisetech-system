"""
Audit script: parse localhost(3).sql purchases table (second database, the one
with branch_id) and compare against the live Supabase BATCH-OLD machines/probes/printers.
Output is a report only — no data is written.
"""
import re, json, urllib.request

SQL_PATH = r"d:\my projects\UltrasoundInventory\localhost (3).sql"
URL = 'https://yygbkgtxuuyuidkqrqqw.supabase.co/rest/v1/'
KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Inl5Z2JrZ3R4dXV5dWlka3FycXF3Iiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc5MDU4ODMxNywiZXhwIjoyMTA2MTY0MzE3fQ.qwHo9cm5HSwSWgWJJ-pJ2kajt79X9Iq4bvYvphOU1EI'
HEADERS = {'apikey': KEY, 'Authorization': 'Bearer ' + KEY}

def api_get(path, limit=5000):
    req = urllib.request.Request(
        URL + path + ('&' if '?' in path else '?') + f'limit={limit}',
        headers={**HEADERS, 'Range-Unit': 'items', 'Range': f'0-{limit-1}'}
    )
    return json.loads(urllib.request.urlopen(req).read())

# ── 1. Parse SQL ─────────────────────────────────────────────────────────────
print("Parsing SQL file...")
with open(SQL_PATH, encoding='latin-1') as f:
    sql = f.read()

# Find the SECOND `purchases` table block (the one with branch_id column)
# Split on the second occurrence of "Dumping data for table `purchases`"
parts = sql.split("Dumping data for table `purchases`")
# parts[2] is the second dump
purchase_block = parts[2]

# Parse catalogue table (second occurrence) for model lookup
cat_parts = sql.split("Dumping data for table `catalogue`")
cat_block = cat_parts[2] if len(cat_parts) > 2 else cat_parts[1]

# Extract catalogue rows: (id, product_type, model)
cat_rows = re.findall(
    r"\((\d+),\s*'(\d+)',\s*'([^']*)'",
    cat_block.split('--')[0]
)
catalogue = {}
for cid, ptype, model in cat_rows:
    catalogue[int(cid)] = {'ptype': int(ptype), 'model': model}

# product_type mapping
# 1255=Machine, 1251=Convex, 1252=Micro Convex, 1253=Linear, 1254=Sector/Phased
# 1256=Printer, 1259=Peds Sector, 1262=TVS, 1263=PC BOARD, 1264=4D Convex
# 1265=3D Convex, 1270=E.Rectal, 1271=Neonatal Cardiac, 1272=Micro Linear
PROBE_TYPES = {1251,1252,1253,1254,1259,1262,1264,1265,1270,1271,1272}
PRINTER_TYPES = {1256}
MACHINE_TYPES = {1255}
PART_TYPES = {1263}

def classify(ptype):
    if ptype in MACHINE_TYPES: return 'machine'
    if ptype in PROBE_TYPES: return 'probe'
    if ptype in PRINTER_TYPES: return 'printer'
    return 'part'

# Extract purchases rows from the second block
# columns: id, location, machine, status, sr, m_sr, arrival_date, issue_date,
#           show_web, vendors, model_year, sold, branch_id
row_pattern = re.compile(
    r"\((\d+),\s*'([^']*)',\s*'([^']*)',\s*'([^']*)',\s*'([^']*)',\s*'([^']*)',\s*'([^']*)',\s*'([^']*)',\s*'([^']*)',\s*'([^']*)',\s*'([^']*)',\s*(\d+),\s*(\d+|NULL)\)"
)

purchases = []
for m in row_pattern.finditer(purchase_block.split(';')[0] + purchase_block.split(';')[1] if ';' in purchase_block else purchase_block):
    pid, loc, machine, status, sr, m_sr, arr, issue, show, vendors, model_year, sold, branch_id = m.groups()
    cat_id = int(machine) if machine.isdigit() else None
    cat = catalogue.get(cat_id, {})
    ptype = cat.get('ptype', 0)
    model = cat.get('model', machine)
    purchases.append({
        'id': int(pid),
        'location': loc.strip(),
        'cat_id': cat_id,
        'model': model,
        'kind': classify(ptype),
        'ptype': ptype,
        'status': status,
        'sr': sr.strip(),       # item serial
        'm_sr': m_sr.strip(),   # machine serial (groups accessories to their machine)
        'arrival': arr,
        'issue': issue,
        'sold': int(sold),
        'branch_id': int(branch_id) if branch_id != 'NULL' else None,
    })

print(f"SQL purchases rows: {len(purchases)}")

# ── 2. Load live BATCH-OLD data from Supabase ────────────────────────────────
print("Loading Supabase BATCH-OLD data...")

def load_all_pages(path_no_limit):
    rows = []
    page = 0
    while True:
        chunk = api_get(path_no_limit + f'&offset={page*1000}', limit=1000)
        rows.extend(chunk)
        if len(chunk) < 1000:
            break
        page += 1
    return rows

sb_machines = load_all_pages(
    'machines?select=id,machine_id,model,serial_number,status,current_location,batch_id&batch_id=eq.30'
)
sb_probes = load_all_pages(
    'probes?select=id,internal_id,model,serial_number,status,current_location,batch_id,assigned_machine_id,box_id&batch_id=eq.30'
)
sb_printers = load_all_pages(
    'printers?select=id,internal_id,name_model,serial_number,status,current_location,batch_id,assigned_machine_id&batch_id=eq.30'
)

print(f"Supabase BATCH-OLD: {len(sb_machines)} machines, {len(sb_probes)} probes, {len(sb_printers)} printers")

# Index by serial number for matching
def index_by_serial(rows, serial_field='serial_number'):
    idx = {}
    for r in rows:
        sn = (r.get(serial_field) or '').strip().upper()
        if sn:
            idx.setdefault(sn, []).append(r)
    return idx

sb_machine_by_sn = index_by_serial(sb_machines)
sb_probe_by_sn = index_by_serial(sb_probes)
sb_printer_by_sn = index_by_serial(sb_printers)

# ── 3. Classify SQL purchases ────────────────────────────────────────────────
sql_machines = [p for p in purchases if p['kind'] == 'machine']
sql_probes = [p for p in purchases if p['kind'] == 'probe']
sql_printers = [p for p in purchases if p['kind'] == 'printer']
sql_parts = [p for p in purchases if p['kind'] == 'part']

print(f"\nSQL: {len(sql_machines)} machines, {len(sql_probes)} probes, {len(sql_printers)} printers, {len(sql_parts)} parts")

# sold
sold_m = [p for p in sql_machines if p['sold']==1]
sold_p = [p for p in sql_probes if p['sold']==1]
sold_pr = [p for p in sql_printers if p['sold']==1]
print(f"SQL sold: {len(sold_m)} machines, {len(sold_p)} probes, {len(sold_pr)} printers")

# branch (branch_id=2 = Lahore branch; location contains 'Lahore' or customer 6=WISETECH LHR)
branch_m = [p for p in sql_machines if p['sold']==0 and 'lahore' in p['location'].lower()]
branch_p = [p for p in sql_probes if p['sold']==0 and 'lahore' in p['location'].lower()]
branch_pr = [p for p in sql_printers if p['sold']==0 and 'lahore' in p['location'].lower()]
print(f"SQL branch (Lahore): {len(branch_m)} machines, {len(branch_p)} probes, {len(branch_pr)} printers")

# ── 4. For each SQL machine find its Supabase counterpart ───────────────────
print("\n=== MACHINES STATUS COMPARISON (first 40 not sold not branch) ===")
print(f"{'SQL_SR':25s}  {'SQL_model':30s}  {'SQL_loc':25s}  {'SB_status':20s}  {'SB_loc'}")
shown = 0
unmatched = []
for p in sql_machines:
    if p['sold'] == 1: continue
    if 'lahore' in p['location'].lower(): continue
    sn = p['sr'].upper()
    sb_matches = sb_machine_by_sn.get(sn, [])
    if not sb_matches:
        unmatched.append(p)
        if shown < 40:
            print(f"  {sn:25s}  {p['model']:30s}  {p['location']:25s}  NOT IN SUPABASE")
            shown += 1
    else:
        sb = sb_matches[0]
        if shown < 40:
            print(f"  {sn:25s}  {p['model']:30s}  {p['location']:25s}  {sb['status']:20s}  {sb['current_location']}")
            shown += 1

print(f"\nTotal unsold non-branch machines not found in Supabase by serial: {len(unmatched)}")

# ── 5. Status summary for all SQL machines that ARE in Supabase ─────────────
print("\n=== SUPABASE STATUS of SQL non-sold non-branch machines ===")
from collections import Counter
sb_statuses = Counter()
for p in sql_machines:
    if p['sold'] == 1: continue
    if 'lahore' in p['location'].lower(): continue
    sn = p['sr'].upper()
    sb_matches = sb_machine_by_sn.get(sn, [])
    if sb_matches:
        sb_statuses[sb_matches[0]['status']] += 1
    else:
        sb_statuses['__NOT_IN_SUPABASE__'] += 1
for s, n in sorted(sb_statuses.items(), key=lambda x:-x[1]):
    print(f"  {s:30s}  {n}")

# ── 6. Sold in SQL but NOT marked Sold in Supabase ──────────────────────────
print("\n=== SOLD in SQL but NOT Sold in Supabase ===")
count = 0
for p in sql_machines:
    if p['sold'] != 1: continue
    sn = p['sr'].upper()
    sb_matches = sb_machine_by_sn.get(sn, [])
    for sb in sb_matches:
        if sb['status'] != 'Sold':
            print(f"  {sn:25s}  {p['model']:30s}  SB_status={sb['status']}  SB_loc={sb['current_location']}")
            count += 1
print(f"  Total: {count}")

# ── 7. Probe attachment: SQL links probe to machine via m_sr ────────────────
print("\n=== PROBE → MACHINE links in SQL (sample 20) ===")
n = 0
for p in sql_probes[:40]:
    if p['sold']==1: continue
    machine_sr = p['m_sr'].strip().upper()
    if machine_sr in ('0','NONE','NILL','-',''):
        continue
    # find the machine in Supabase
    sb_m = sb_machine_by_sn.get(machine_sr, [])
    sb_p = sb_probe_by_sn.get(p['sr'].upper(), [])
    machine_code = sb_m[0]['machine_id'] if sb_m else '?'
    probe_code = sb_p[0]['internal_id'] if sb_p else '?'
    probe_assigned = sb_p[0].get('assigned_machine_id') if sb_p else None
    print(f"  probe_sr={p['sr']:20s} → machine_sr={machine_sr:20s} | SB_machine={machine_code} SB_probe={probe_code} assigned={probe_assigned}")
    n += 1
    if n >= 20: break

print("\nDone.")
