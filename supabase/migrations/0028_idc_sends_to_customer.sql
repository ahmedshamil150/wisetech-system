-- IDC was recorded as a dealer on four sends (12-10-2026 and
-- 17-10-2026). IDC is a customer, not a dealer: move those sends to the
-- customer side. Items, dates, notes, paid flags and group refs stay
-- exactly as they are.
--
-- The four rows are copied first so nothing is lost if this ever has to
-- be undone. The copy carries no policies, so PostgREST cannot read it.
create table if not exists public.movements_bak_20261030_idc as
select * from public.movements
where id in (1438, 1439, 1440, 1448);

alter table public.movements_bak_20261030_idc enable row level security;

update public.movements
set movement_type = 'Customer',
    customer_id = 687,        -- IDC
    dealer_id = null,
    reason = 'Sent to customer'
where id in (1438, 1439, 1440, 1448)
  and movement_type = 'Dealer';
