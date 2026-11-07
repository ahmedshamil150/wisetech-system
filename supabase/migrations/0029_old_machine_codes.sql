-- A machine entered from the app into BATCH-OLD has no batch letter, so
-- next_machine_code() cannot number it. Give old-stock machines the same
-- legacy shape as the imported rows (M-#####), from a sequence that starts
-- above the imported codes (the highest imported is M-09260).
create sequence if not exists old_machine_code_seq start 10000;

create or replace function next_old_machine_code()
returns text
language plpgsql
security definer
set search_path = public
as $$
begin
    return 'M-' || lpad(nextval('old_machine_code_seq')::text, 5, '0');
end;
$$;

grant execute on function next_old_machine_code() to authenticated;
