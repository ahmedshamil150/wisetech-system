-- 0009: remove the phantom 98T VIAMO sale set, renumber machines so 90T and
-- 92T are free for the two new machines (series ends at 99T = PROSOUND ALPHA
-- 7 serial 20265766), and make next_machine_code fill the lowest free number.

-- 1) delete the 98T set: its machine sale, the two probe sale lines that
--    reference its probes, the probes, then the machine row
--    (FKs to machines/probes are NO ACTION, so children first)
DELETE FROM movements
 WHERE machine_id = (SELECT id FROM machines WHERE machine_id = '98T')
    OR probe_id IN (SELECT id FROM probes
                     WHERE assigned_machine_id =
                           (SELECT id FROM machines WHERE machine_id = '98T'));

DELETE FROM probes
 WHERE assigned_machine_id = (SELECT id FROM machines WHERE machine_id = '98T');

DELETE FROM machines WHERE machine_id = '98T';

-- 2) renumber 90..97 -> 91, 93..99; highest target first so
--    machines_machine_id_key never collides mid-way
UPDATE machines SET machine_id = '99T' WHERE machine_id = '97T';
UPDATE machines SET machine_id = '98T' WHERE machine_id = '96T';
UPDATE machines SET machine_id = '97T' WHERE machine_id = '95T';
UPDATE machines SET machine_id = '96T' WHERE machine_id = '94T';
UPDATE machines SET machine_id = '95T' WHERE machine_id = '93T';
UPDATE machines SET machine_id = '94T' WHERE machine_id = '92T';
UPDATE machines SET machine_id = '93T' WHERE machine_id = '91T';
UPDATE machines SET machine_id = '91T' WHERE machine_id = '90T';

-- 3) kit ids that share their machine's code follow the new code
--    (legacy PRB-/PART- style ids stay as they are)
UPDATE probes p
   SET internal_id = m.machine_id
  FROM machines m
 WHERE m.id = p.assigned_machine_id
   AND p.internal_id::text IN
       ('90T', '91T', '92T', '93T', '94T', '95T', '96T', '97T');

UPDATE printers pr
   SET internal_id = m.machine_id
  FROM machines m
 WHERE m.id = pr.assigned_machine_id
   AND pr.internal_id::text IN
       ('90T', '91T', '92T', '93T', '94T', '95T', '96T', '97T');

-- 4) next machine id = lowest free number (so 90T, then 92T get used first)
CREATE OR REPLACE FUNCTION next_machine_code(p_letter TEXT)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_max INT;
    v_n   INT;
BEGIN
    IF p_letter IS NULL OR p_letter !~ '^[A-Z]$' THEN
        RAISE EXCEPTION 'bad batch letter: %', p_letter;
    END IF;

    SELECT COALESCE(MAX((regexp_match(machine_id, '^([0-9]+)'))[1]::INT), 0)
      INTO v_max
      FROM machines
     WHERE machine_id ~ ('^[0-9]+' || p_letter || '$');

    SELECT MIN(n)
      INTO v_n
      FROM generate_series(1, v_max + 1) AS n
     WHERE NOT EXISTS (SELECT 1 FROM machines m
                        WHERE m.machine_id = (n::text || p_letter));

    RETURN v_n || p_letter;
END;
$$;
