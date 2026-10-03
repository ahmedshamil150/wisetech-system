-- ============================================================
-- 0015: 'With Customer' STATUS
--
--   A customer send used to change only the location — the item
--   kept 'In Stock' / 'Available' and showed up in the inventory's
--   in-stock filter while it was actually out with a customer
--   (e.g. 23T, 60T at Jahangir Sb LHR).
--
--   * 'With Customer' joins the status list of machines, probes,
--     printers and parts
--   * create_movement sets it for customer sends (Sold/Archived
--     stay put — the sale is the authority)
--   * delete_movement_rows replays customer sends to the new status
--     as well, so a deleted send puts the item back in stock and an
--     existing one restates it as With Customer
--   * existing rows whose last movement is a customer send and that
--     still claim to be in stock are corrected
-- ============================================================

-- ------------------------------------------------------------
-- 1. status check constraints accept the new value
-- ------------------------------------------------------------
ALTER TABLE machines DROP CONSTRAINT machines_status_check;
ALTER TABLE machines ADD CONSTRAINT machines_status_check CHECK (
    status = ANY (ARRAY['In Stock'::text, 'With Workshop'::text,
                        'With Dealer'::text, 'With Customer'::text,
                        'Sold'::text, 'Archived'::text]));

ALTER TABLE probes DROP CONSTRAINT probes_status_check;
ALTER TABLE probes ADD CONSTRAINT probes_status_check CHECK (
    status = ANY (ARRAY['Available'::text, 'With Machine'::text,
                        'With Workshop'::text, 'With Dealer'::text,
                        'With Customer'::text, 'Sold'::text,
                        'Archived'::text]));

ALTER TABLE printers DROP CONSTRAINT printers_status_check;
ALTER TABLE printers ADD CONSTRAINT printers_status_check CHECK (
    status = ANY (ARRAY['Available'::text, 'With Machine'::text,
                        'With Workshop'::text, 'With Dealer'::text,
                        'With Customer'::text, 'Sold'::text,
                        'Archived'::text]));

ALTER TABLE parts DROP CONSTRAINT parts_status_check;
ALTER TABLE parts ADD CONSTRAINT parts_status_check CHECK (
    status = ANY (ARRAY['Available'::text, 'With Machine'::text,
                        'With Workshop'::text, 'With Dealer'::text,
                        'With Customer'::text, 'Sold'::text,
                        'Archived'::text]));

-- ------------------------------------------------------------
-- 2. create_movement (recreated: customer sends change the status)
-- ------------------------------------------------------------
DROP FUNCTION IF EXISTS public.create_movement(text, bigint, text, bigint,
                                                bigint, bigint, text, text,
                                                boolean);

CREATE OR REPLACE FUNCTION public.create_movement(
    p_item_type   text,
    p_item_id     bigint,
    p_kind        text,
    p_dealer_id   bigint DEFAULT NULL,
    p_customer_id bigint DEFAULT NULL,
    p_workshop_id bigint DEFAULT NULL,
    p_date        text   DEFAULT NULL,
    p_notes       text   DEFAULT NULL,
    p_demo        boolean DEFAULT false,
    p_group_ref   text   DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_table      text;
    v_label_col  text;
    v_rec        record;
    v_to         text;
    v_new_status text;
    v_id         bigint;
BEGIN
    IF p_kind NOT IN ('Workshop', 'Dealer', 'Customer') THEN
        RAISE EXCEPTION 'unknown movement type: %', p_kind;
    END IF;
    IF p_kind = 'Workshop' THEN
        SELECT id INTO p_workshop_id FROM workshops
          WHERE is_archived = 0 ORDER BY id LIMIT 1;
        IF p_workshop_id IS NULL THEN
            RAISE EXCEPTION 'no workshop configured';
        END IF;
        p_demo := false;   -- only dealer / customer sends can be demos
    END IF;

    v_table := CASE p_item_type
                   WHEN 'machine' THEN 'machines'
                   WHEN 'probe'   THEN 'probes'
                   WHEN 'printer' THEN 'printers'
                   WHEN 'part'    THEN 'parts'
                   ELSE NULL END;
    IF v_table IS NULL THEN
        RAISE EXCEPTION 'unknown item type: %', p_item_type;
    END IF;
    v_label_col := CASE WHEN v_table IN ('machines', 'probes')
                        THEN 'model' ELSE 'name_model' END;

    EXECUTE format(
        'SELECT id, status, current_location, serial_number, %I FROM %I WHERE id = $1',
        v_label_col, v_table)
        INTO v_rec USING p_item_id;

    -- note: EXECUTE ... INTO does not set FOUND, check the record instead
    IF v_rec IS NULL THEN
        RAISE EXCEPTION 'item % not found in %', p_item_id, v_table;
    END IF;

    -- the name may be missing on purpose: it can be added later
    IF p_kind = 'Workshop' THEN
        v_to := 'Workshop';
    ELSIF p_kind = 'Dealer' THEN
        IF p_dealer_id IS NOT NULL THEN
            SELECT name INTO v_to FROM dealers WHERE id = p_dealer_id;
            IF v_to IS NULL THEN
                RAISE EXCEPTION 'destination not found';
            END IF;
        ELSE
            v_to := 'Dealer';
        END IF;
    ELSE
        IF p_customer_id IS NOT NULL THEN
            SELECT name INTO v_to FROM customers WHERE id = p_customer_id;
            IF v_to IS NULL THEN
                RAISE EXCEPTION 'destination not found';
            END IF;
        ELSE
            v_to := 'Customer';
        END IF;
    END IF;

    -- workshop / dealer / customer all take the item out of stock;
    -- a sale or an archive is never overwritten
    IF p_kind = 'Workshop' THEN
        v_new_status := 'With Workshop';
    ELSIF p_kind = 'Dealer' THEN
        v_new_status := 'With Dealer';
    ELSIF v_rec.status IN ('Sold', 'Archived') THEN
        v_new_status := v_rec.status;
    ELSE
        v_new_status := 'With Customer';
    END IF;

    EXECUTE format(
        'UPDATE %I SET status = $1, current_location = $2 WHERE id = $3',
        v_table)
        USING v_new_status, v_to, p_item_id;

    INSERT INTO movements (
        movement_type, movement_date,
        machine_id, probe_id, printer_id, part_id,
        workshop_id, dealer_id, customer_id,
        from_location, to_location, reason, notes,
        actor_id, group_ref, reference, is_demo
    ) VALUES (
        p_kind,
        COALESCE(p_date, to_char(now(), 'DD-MM-YYYY')),
        CASE WHEN p_item_type = 'machine' THEN p_item_id END,
        CASE WHEN p_item_type = 'probe'   THEN p_item_id END,
        CASE WHEN p_item_type = 'printer' THEN p_item_id END,
        CASE WHEN p_item_type = 'part'    THEN p_item_id END,
        CASE WHEN p_kind = 'Workshop' THEN p_workshop_id END,
        CASE WHEN p_kind = 'Dealer'   THEN p_dealer_id   END,
        CASE WHEN p_kind = 'Customer' THEN p_customer_id END,
        v_rec.current_location, v_to,
        'Sent to ' || CASE WHEN p_kind = 'Workshop' THEN 'workshop'
                           WHEN p_kind = 'Dealer' THEN 'dealer'
                           ELSE 'customer' END
          || CASE WHEN p_demo THEN ' (demo)' ELSE '' END,
        p_notes,
        auth.uid(), COALESCE(p_group_ref, new_group_ref()),
        next_movement_reference(),
        p_demo
    )
    RETURNING id INTO v_id;

    RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.create_movement(text, bigint, text, bigint,
                                                  bigint, bigint, text, text,
                                                  boolean, text)
    TO authenticated;

-- ------------------------------------------------------------
-- 3. delete_movement_rows (recreated: the replay knows customer
--    sends now too)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.delete_movement_rows(p_ids bigint[])
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_rec       record;
  v_item      bigint;
  v_mids      bigint[];
  v_pids      bigint[];
  v_printids  bigint[];
  v_partids   bigint[];
  v_col       text;
  v_table     text;
  v_arr       bigint[];
  v_status    text;
  v_stock     text;
  v_from      text;
  v_loc       text;
BEGIN
  IF p_ids IS NULL OR coalesce(array_length(p_ids, 1), 0) = 0 THEN
    RETURN;
  END IF;

  SELECT coalesce(array_agg(DISTINCT machine_id)
                    FILTER (WHERE machine_id IS NOT NULL), '{}'),
         coalesce(array_agg(DISTINCT probe_id)
                    FILTER (WHERE probe_id IS NOT NULL), '{}'),
         coalesce(array_agg(DISTINCT printer_id)
                    FILTER (WHERE printer_id IS NOT NULL), '{}'),
         coalesce(array_agg(DISTINCT part_id)
                    FILTER (WHERE part_id IS NOT NULL), '{}')
    INTO v_mids, v_pids, v_printids, v_partids
    FROM movements
   WHERE id = ANY(p_ids);

  -- stitch: the earliest surviving send of an item takes over the
  -- origin of the erased ones — deleting an earlier send must not
  -- make the next one claim the item started at that destination
  FOR v_col, v_arr IN
    SELECT * FROM (VALUES ('machine_id', v_mids),
                          ('probe_id',    v_pids),
                          ('printer_id',  v_printids),
                          ('part_id',     v_partids))
         AS t(col, ids)
  LOOP
    FOREACH v_item IN ARRAY coalesce(v_arr, '{}'::bigint[]) LOOP
      EXECUTE format(
        'UPDATE movements SET from_location ='
        ' (SELECT m.from_location FROM movements m'
        '  WHERE m.id = ANY($1) AND m.%1$I = $2'
        '  ORDER BY m.id LIMIT 1)'
        ' WHERE %1$I = $2'
        '   AND id = (SELECT min(m.id) FROM movements m'
        '              WHERE m.%1$I = $2 AND NOT (m.id = ANY($1)))'
        '   AND EXISTS (SELECT 1 FROM movements m'
        '                WHERE m.id = ANY($1) AND m.%1$I = $2'
        '                  AND m.id < movements.id)', v_col)
        USING p_ids, v_item;
    END LOOP;
  END LOOP;

  -- a Return row belongs to the send that was the last outbound
  -- movement before it: erasing the send erases its returns too
  FOR v_rec IN
    SELECT COALESCE(machine_id, probe_id, printer_id, part_id) AS item_id,
           CASE WHEN machine_id IS NOT NULL THEN 'machine_id'
                WHEN probe_id   IS NOT NULL THEN 'probe_id'
                WHEN printer_id IS NOT NULL THEN 'printer_id'
                ELSE 'part_id' END AS col
      FROM movements
     WHERE id = ANY(p_ids)
       AND COALESCE(machine_id, probe_id, printer_id, part_id) IS NOT NULL
     ORDER BY id
  LOOP
    EXECUTE format(
      'DELETE FROM movements r'
      ' WHERE r.movement_type = ''Return'' AND r.%1$I = $1'
      '   AND (SELECT s.id FROM movements s'
      '        WHERE s.%1$I = r.%1$I'
      '          AND s.movement_type <> ''Return'''
      '          AND s.id < r.id'
      '        ORDER BY s.id DESC LIMIT 1) = ANY($2)',
      v_rec.col)
      USING v_rec.item_id, p_ids;
  END LOOP;

  -- ---- machines: replay what is left of the history ----------------
  FOREACH v_item IN ARRAY v_mids LOOP
    SELECT status INTO v_status FROM machines WHERE id = v_item;
    IF v_status IN ('Sold', 'Archived') THEN
      CONTINUE;  -- the sale / the archive is the authority
    END IF;
    v_status := 'In Stock';
    SELECT coalesce(nullif(from_location, ''), 'Company') INTO v_from
      FROM movements
     WHERE id = ANY(p_ids) AND machine_id = v_item
     ORDER BY id LIMIT 1;
    v_loc := coalesce(v_from, 'Company');
    FOR v_rec IN
      SELECT movement_type, to_location FROM movements
       WHERE machine_id = v_item AND NOT (id = ANY(p_ids))
       ORDER BY id
    LOOP
      IF v_rec.movement_type = 'Workshop' THEN
        v_status := 'With Workshop';
        v_loc := v_rec.to_location;
      ELSIF v_rec.movement_type = 'Dealer' THEN
        v_status := 'With Dealer';
        v_loc := v_rec.to_location;
      ELSIF v_rec.movement_type = 'Customer' THEN
        v_status := 'With Customer';
        v_loc := v_rec.to_location;
      ELSIF v_rec.movement_type = 'Return' THEN
        v_status := 'In Stock';
        v_loc := v_rec.to_location;
      ELSE
        v_loc := v_rec.to_location;
      END IF;
    END LOOP;
    UPDATE machines SET status = v_status, current_location = v_loc
     WHERE id = v_item;
  END LOOP;

  -- ---- probes, printers and parts: same replay ---------------------
  FOR v_col, v_table, v_arr IN
    SELECT * FROM (VALUES ('probe_id',   'probes',   v_pids),
                          ('printer_id', 'printers', v_printids),
                          ('part_id',    'parts',    v_partids))
         AS t(col, tbl, ids)
  LOOP
    FOREACH v_item IN ARRAY coalesce(v_arr, '{}'::bigint[]) LOOP
      EXECUTE format('SELECT status FROM %I WHERE id = $1', v_table)
        INTO v_status USING v_item;
      IF v_status IN ('Sold', 'Archived') THEN
        CONTINUE;  -- the sale / the archive is the authority
      END IF;

      -- where the item sits when nothing of its history is left
      EXECUTE format(
        'SELECT CASE WHEN t.assigned_machine_id IS NULL THEN ''Available'''
        ' ELSE coalesce((SELECT CASE WHEN m.status IS NULL'
        '              OR m.status IN (''Sold'', ''Archived'')'
        '              THEN ''Available'' ELSE ''With Machine'' END'
        '         FROM machines m WHERE m.id = t.assigned_machine_id),'
        '         ''Available'') END'
        ' FROM %I t WHERE t.id = $1', v_table)
        INTO v_stock USING v_item;
      EXECUTE format(
        'SELECT coalesce(nullif(from_location, ''''), ''Company'')'
        ' FROM movements WHERE id = ANY($1) AND %1$I = $2'
        ' ORDER BY id LIMIT 1', v_col)
        INTO v_from USING p_ids, v_item;

      v_status := v_stock;
      v_loc := coalesce(v_from, 'Company');
      FOR v_rec IN EXECUTE format(
        'SELECT movement_type, to_location FROM movements'
        ' WHERE %1$I = $1 AND NOT (id = ANY($2)) ORDER BY id', v_col)
        USING v_item, p_ids
      LOOP
        IF v_rec.movement_type = 'Workshop' THEN
          v_status := 'With Workshop';
          v_loc := v_rec.to_location;
        ELSIF v_rec.movement_type = 'Dealer' THEN
          v_status := 'With Dealer';
          v_loc := v_rec.to_location;
        ELSIF v_rec.movement_type = 'Customer' THEN
          v_status := 'With Customer';
          v_loc := v_rec.to_location;
        ELSIF v_rec.movement_type = 'Return' THEN
          v_status := v_stock;
          v_loc := v_rec.to_location;
        ELSE
          v_loc := v_rec.to_location;
        END IF;
      END LOOP;
      EXECUTE format(
        'UPDATE %I SET status = $1, current_location = $2 WHERE id = $3',
        v_table)
        USING v_status, v_loc, v_item;
    END LOOP;
  END LOOP;

  DELETE FROM movements WHERE id = ANY(p_ids);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.delete_movement_rows(bigint[])
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.delete_movement_rows(bigint[])
    TO service_role;

-- ------------------------------------------------------------
-- 4. fix the existing rows: last movement = customer send, but the
--    item still claims to be in stock
-- ------------------------------------------------------------
UPDATE machines m
   SET status = 'With Customer'
 WHERE m.status = 'In Stock'
   AND (SELECT movement_type FROM movements mm
         WHERE mm.machine_id = m.id ORDER BY mm.id DESC LIMIT 1)
       = 'Customer';

UPDATE probes p
   SET status = 'With Customer'
 WHERE p.status = 'Available'
   AND (SELECT movement_type FROM movements mm
         WHERE mm.probe_id = p.id ORDER BY mm.id DESC LIMIT 1)
       = 'Customer';

UPDATE printers pr
   SET status = 'With Customer'
 WHERE pr.status = 'Available'
   AND (SELECT movement_type FROM movements mm
         WHERE mm.printer_id = pr.id ORDER BY mm.id DESC LIMIT 1)
       = 'Customer';

UPDATE parts pt
   SET status = 'With Customer'
 WHERE pt.status = 'Available'
   AND (SELECT movement_type FROM movements mm
         WHERE mm.part_id = pt.id ORDER BY mm.id DESC LIMIT 1)
       = 'Customer';
