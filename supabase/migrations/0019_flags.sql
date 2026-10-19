-- Generic admin flags: one colored dot (with an optional note) per
-- flagged thing — an inventory item, a single movement row, a whole
-- send, or a repair job. Admins write them; everybody sees them.
create table if not exists public.flags (
  id          bigint generated always as identity primary key,
  item_kind   text,
  item_id     bigint,
  movement_id bigint,
  repair_id   bigint,
  group_ref   text,
  color       text not null,
  note        text,
  created_by  uuid default auth.uid(),
  created_at  timestamptz not null default now(),
  constraint flags_one_target check (
    (case when item_id is not null then 1 else 0 end +
     case when movement_id is not null then 1 else 0 end +
     case when repair_id is not null then 1 else 0 end) = 1
  ),
  constraint flags_item_kind check (
    item_kind is null or item_kind in ('machine', 'probe', 'printer', 'part')
  ),
  constraint flags_item_needs_kind check ( (item_id is null) = (item_kind is null) ),
  constraint flags_group_needs_movement check ( group_ref is null or movement_id is not null )
);

alter table public.flags enable row level security;

create policy "read all" on public.flags
    for select to authenticated using (true);

create policy "admin write" on public.flags
    for all to authenticated
    using (public.is_admin()) with check (public.is_admin());

create index if not exists idx_flags_item     on public.flags (item_kind, item_id);
create index if not exists idx_flags_movement on public.flags (movement_id);
create index if not exists idx_flags_group    on public.flags (group_ref);
create index if not exists idx_flags_repair   on public.flags (repair_id);
