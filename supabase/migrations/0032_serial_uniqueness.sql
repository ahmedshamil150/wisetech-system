-- Serial numbers must never be duplicated again.
--
-- The 2026-11-07 audit found two very different kinds of duplicates:
--   * 1,781 asen rows that were copies of wises rows (removed, see
--     scripts/fix_serial_duplicates.py),
--   * a serial repeated between the old side and current stock, which is
--     legitimate (a sold old unit bought back / re-entered today).
-- So uniqueness is enforced per side and among active rows:
--   * batch BATCH-OLD (id 30) is the old side, every other batch the
--     current side;
--   * Sold rows are history and may repeat a serial (buy-backs);
--   * blank serials are ignored.
--
-- The unique indexes cover each table, the trigger covers the four
-- tables against each other. Both would have rejected the asen import.

create unique index if not exists machines_serial_old_uq
  on public.machines (upper(btrim(serial_number)))
  where batch_id = 30 and coalesce(btrim(serial_number), '') <> ''
    and coalesce(status, '') <> 'Sold';
create unique index if not exists machines_serial_new_uq
  on public.machines (upper(btrim(serial_number)))
  where batch_id is distinct from 30 and coalesce(btrim(serial_number), '') <> ''
    and coalesce(status, '') <> 'Sold';

create unique index if not exists probes_serial_old_uq
  on public.probes (upper(btrim(serial_number)))
  where batch_id = 30 and coalesce(btrim(serial_number), '') <> ''
    and coalesce(status, '') <> 'Sold';
create unique index if not exists probes_serial_new_uq
  on public.probes (upper(btrim(serial_number)))
  where batch_id is distinct from 30 and coalesce(btrim(serial_number), '') <> ''
    and coalesce(status, '') <> 'Sold';

create unique index if not exists printers_serial_old_uq
  on public.printers (upper(btrim(serial_number)))
  where batch_id = 30 and coalesce(btrim(serial_number), '') <> ''
    and coalesce(status, '') <> 'Sold';
create unique index if not exists printers_serial_new_uq
  on public.printers (upper(btrim(serial_number)))
  where batch_id is distinct from 30 and coalesce(btrim(serial_number), '') <> ''
    and coalesce(status, '') <> 'Sold';

create unique index if not exists parts_serial_old_uq
  on public.parts (upper(btrim(serial_number)))
  where batch_id = 30 and coalesce(btrim(serial_number), '') <> ''
    and coalesce(status, '') <> 'Sold';
create unique index if not exists parts_serial_new_uq
  on public.parts (upper(btrim(serial_number)))
  where batch_id is distinct from 30 and coalesce(btrim(serial_number), '') <> ''
    and coalesce(status, '') <> 'Sold';

create or replace function public.enforce_unique_item_serial()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_serial text := upper(btrim(coalesce(new.serial_number, '')));
  v_old boolean := new.batch_id = 30;
  v_sold boolean := coalesce(new.status, '') = 'Sold';
  v_skip_id bigint;
  v_table text;
  v_found text;
begin
  if v_serial = '' or v_sold then
    return new;
  end if;
  if tg_op = 'UPDATE'
     and v_serial = upper(btrim(coalesce(old.serial_number, '')))
     and v_old = (old.batch_id = 30)
     and v_sold = (coalesce(old.status, '') = 'Sold') then
    return new;
  end if;
  foreach v_table in array array['machines', 'probes', 'printers', 'parts'] loop
    v_skip_id := case when v_table = tg_table_name then new.id else -1 end;
    execute format(
      'select %L from %I where upper(btrim(serial_number)) = $1 '
      'and (batch_id = 30) = $2 and coalesce(status, %L) <> %L '
      'and ($3 = -1 or id <> $3) limit 1',
      v_table, v_table, '', 'Sold')
      into v_found using v_serial, v_old, v_skip_id;
    if v_found is not null then
      raise exception 'Serial % is already used by an active % (%)',
        new.serial_number, v_found, v_table
        using errcode = 'unique_violation';
    end if;
  end loop;
  return new;
end;
$$;

drop trigger if exists machines_serial_unique on public.machines;
create trigger machines_serial_unique
  before insert or update of serial_number on public.machines
  for each row execute function public.enforce_unique_item_serial();

drop trigger if exists probes_serial_unique on public.probes;
create trigger probes_serial_unique
  before insert or update of serial_number on public.probes
  for each row execute function public.enforce_unique_item_serial();

drop trigger if exists printers_serial_unique on public.printers;
create trigger printers_serial_unique
  before insert or update of serial_number on public.printers
  for each row execute function public.enforce_unique_item_serial();

drop trigger if exists parts_serial_unique on public.parts;
create trigger parts_serial_unique
  before insert or update of serial_number on public.parts
  for each row execute function public.enforce_unique_item_serial();
