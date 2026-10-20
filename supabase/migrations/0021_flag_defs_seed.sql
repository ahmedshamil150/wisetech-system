-- One yellow flag, not two: 'NEED REVIEW SHOULD NOT BE WRITTEN' reads
-- the same as 'Should not be written' — fold it into the shorter name
-- and keep the shared light-yellow.
update public.flags
set note = 'Should not be written'
where lower(trim(note)) = 'need review should not be written';

-- Seed the library with every description already in use, taking each
-- one's own color, so today's flags become reusable saved flags.
insert into public.flag_defs (name, color)
select distinct on (lower(trim(note))) trim(note), color
from public.flags
where note is not null and btrim(note) <> ''
order by lower(trim(note)), id;

-- Green and red join the library too — the same two colors the review
-- dots read, now applicable anywhere a flag can go.
insert into public.flag_defs (name, color)
select v.name, v.color
from (values ('Green', '#43A047'), ('Red', '#E53935')) as v(name, color)
where not exists (
  select 1 from public.flag_defs d where lower(trim(d.name)) = lower(v.name)
);
