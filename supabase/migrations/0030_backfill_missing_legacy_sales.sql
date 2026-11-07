-- Restore the last legacy sales rows missing from the app.
--
-- Audit of localhost (3).sql against the live DB (2026-11-07):
--   * wises invoice 1360 (04-09-2026, customer 424 = Sameer Sb DLR,
--     trno 0, price 0) was never imported and has no lines in the dump.
--   * wises lines 367 and 368 (trno 19822900) are missing; that trno has
--     no invoice row in either dump database, so they get one synthetic
--     invoice, dated like the other no-invoice imports.
-- Every other legacy invoice/line is already represented (asen copies
-- were merged into their wises rows on 2026-11-07).

insert into public.sales (customer_id, sale_date, sale_price, notes,
                          old_source_id, old_trno)
select 672, '2026-09-04', 0, null, 1360, '0'
where not exists (select 1 from public.sales where old_source_id = 1360);

insert into public.sales (customer_id, sale_date, sale_price, notes,
                          old_source_id, old_trno)
select null, '0001-01-01', null, 'Imported legacy sale (no invoice row).',
       9500001, '19822900'
where not exists (select 1 from public.sales where old_source_id = 9500001);

insert into public.sale_items (sale_id, item_type, probe_id, item_description,
                               item_serial, item_price, is_main_item,
                               old_source_id)
select (select id from public.sales where old_source_id = 9500001),
       'probe', (select id from public.probes where old_source_id = 805),
       'B&W Printer, Model: UP-D897', '55556666', 25000, 1, 367
where not exists (select 1 from public.sale_items where old_source_id = 367);

insert into public.sale_items (sale_id, item_type, machine_id, item_description,
                               item_serial, item_price, is_main_item,
                               old_source_id)
select (select id from public.sales where old_source_id = 9500001),
       'machine', (select id from public.machines where old_source_id = 803),
       'Convex Probe, Model: 4C', 'NIL-503', 25000, 1, 368
where not exists (select 1 from public.sale_items where old_source_id = 368);
