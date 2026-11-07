-- Six old machines are marked Sold in the legacy data but have no sale
-- record anywhere: no sale_inv/sale_temp_inv line in either legacy
-- database (by purchase id or serial), no legacy sale event, and no
-- sale_items row in the app. Flag them so the owner can investigate.
insert into public.flags (item_kind, item_id, color, note, created_by)
select 'machine', m.id, '#E53935',
       'Marked Sold in legacy data, but no sale exists in the old system or the app.',
       '41c30e7a-f8b4-49df-b334-df6d5c87a941'
from public.machines m
where m.machine_id in ('M-02152', 'M-02459', 'M-02595',
                       'M-04134', 'M-04136', 'M-04137')
  and m.status = 'Sold'
  and not exists (
      select 1 from public.flags f
      where f.item_kind = 'machine' and f.item_id = m.id);
