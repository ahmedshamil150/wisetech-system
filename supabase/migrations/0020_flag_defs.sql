-- The reusable flag library: a description + color, defined once in
-- Records and applied to items, movements or repairs anywhere in the
-- app. Applying copies the description and color onto the flag row, so
-- deleting a library entry never removes flags already in use.
create table if not exists public.flag_defs (
  id         bigint generated always as identity primary key,
  name       text not null,
  color      text not null,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);

alter table public.flag_defs enable row level security;

create policy "read all" on public.flag_defs
    for select to authenticated using (true);

create policy "admin write" on public.flag_defs
    for all to authenticated
    using (public.is_admin()) with check (public.is_admin());
