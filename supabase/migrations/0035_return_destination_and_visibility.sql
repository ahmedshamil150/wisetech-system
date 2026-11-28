-- ============================================================
-- 0035: RETURN A SEND TO A CHOSEN PLACE, AND MAKE IT VISIBLE
--
-- Returning a send used to put every item back with the status and
-- location it left from. An imported item (BATCH-OLD) stayed in the
-- old batch, and an item that left the Basement came back to the
-- Basement, so the Inventory page - which only lists the current
-- batches and hides basement rows - could not show it. That is why a
-- returned machine like W5A1672001 and its probe and printer were
-- nowhere to be found.
--
-- return_to_inventory now takes p_destination:
--   * 'inventory' (default) -> Company, in-stock status, current batch
--   * 'workshop'            -> Workshop, With Workshop
--   * 'basement'            -> Basement, in-stock status
--
-- It also clears the Missing flag and any old workshop-room flag, so
-- nothing stays hidden behind a stale mark.
-- ============================================================

-- The old 4-argument version would be an ambiguous overload next to the
-- new one; drop it before creating the replacement.
DROP FUNCTION IF EXISTS public.return_to_inventory(text, bigint, text, text);

CREATE OR REPLACE FUNCTION public.return_to_inventory(
    p_item_type   text,
    p_item_id     bigint,
    p_date        text DEFAULT NULL,
    p_notes       text DEFAULT NULL,
    p_destination text DEFAULT 'inventory'
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_table       text;
    v_rec         record;
    v_from        text;
    v_to          text;
    v_new_status  text;
    v_mstatus     text;
    v_clear_link  boolean := false;
    v_batch       bigint;
    v_reason      text;
    v_id          bigint;
BEGIN
    v_table := CASE p_item_type
                   WHEN 'machine' THEN 'machines'
                   WHEN 'probe'   THEN 'probes'
                   WHEN 'printer' THEN 'printers'
                   WHEN 'part'    THEN 'parts'
                   ELSE NULL END;
    IF v_table IS NULL THEN
        RAISE EXCEPTION 'unknown item type: %', p_item_type;
    END IF;
    IF p_destination NOT IN ('inventory', 'workshop', 'basement') THEN
        RAISE EXCEPTION 'unknown destination: %', p_destination;
    END IF;

    IF v_table = 'machines' THEN
        EXECUTE 'SELECT id, status, current_location, batch_id, '
                'NULL::bigint AS assigned_machine_id '
                'FROM machines WHERE id = $1'
            INTO v_rec USING p_item_id;
    ELSE
        EXECUTE format(
            'SELECT id, status, current_location, batch_id, '
            'assigned_machine_id FROM %I WHERE id = $1', v_table)
            INTO v_rec USING p_item_id;
    END IF;

    -- note: EXECUTE ... INTO does not set FOUND, check the record instead
    IF v_rec IS NULL THEN
        RAISE EXCEPTION 'item % not found in %', p_item_id, v_table;
    END IF;

    v_from := v_rec.current_location;

    IF p_destination = 'workshop' THEN
        v_to := 'Workshop';
        v_new_status := 'With Workshop';
        v_reason := 'Returned to workshop';
    ELSIF p_destination = 'basement' THEN
        v_to := 'Basement';
        v_new_status := CASE
            WHEN p_item_type = 'machine' THEN 'In Stock'
            WHEN v_rec.assigned_machine_id IS NOT NULL THEN 'With Machine'
            ELSE 'Available' END;
        v_reason := 'Returned to basement';
    ELSE
        v_to := 'Company';
        v_reason := 'Returned to inventory';

        IF p_item_type = 'machine' THEN
            v_new_status := 'In Stock';
        ELSIF v_rec.assigned_machine_id IS NOT NULL THEN
            SELECT status INTO v_mstatus
              FROM machines WHERE id = v_rec.assigned_machine_id;
            IF FOUND AND v_mstatus NOT IN ('Sold', 'Archived') THEN
                v_new_status := 'With Machine';
            ELSE
                -- its machine is gone: a free part again
                v_new_status := 'Available';
                v_clear_link := true;
            END IF;
        ELSE
            v_new_status := 'Available';
        END IF;

        -- Imported stock that comes back to the main Inventory list must
        -- join the current batch; otherwise the batch filter keeps it
        -- hidden for ever.
        IF v_rec.batch_id = 30 THEN
            SELECT NULLIF(value, '')::bigint INTO v_batch
              FROM app_settings WHERE key = 'current_batch_id' LIMIT 1;
            IF v_batch IS NULL THEN
                SELECT id INTO v_batch
                  FROM batches WHERE code <> 'BATCH-OLD'
                  ORDER BY id DESC LIMIT 1;
            END IF;
        END IF;
    END IF;

    IF v_batch IS NOT NULL THEN
        EXECUTE format(
            'UPDATE %I SET status = $1, current_location = $2, '
            'batch_id = $3 WHERE id = $4', v_table)
            USING v_new_status, v_to, v_batch, p_item_id;
    ELSE
        EXECUTE format(
            'UPDATE %I SET status = $1, current_location = $2 WHERE id = $3',
            v_table)
            USING v_new_status, v_to, p_item_id;
    END IF;

    IF v_table <> 'machines' THEN
        EXECUTE format(
            'UPDATE %I SET assigned_machine_id = $1 WHERE id = $2', v_table)
            USING CASE WHEN v_clear_link THEN NULL
                       ELSE v_rec.assigned_machine_id END,
                  p_item_id;
    END IF;

    -- a found item is not missing any more
    DELETE FROM flags
     WHERE item_kind = p_item_type AND item_id = p_item_id
       AND note = 'Missing';

    -- leaving the workshop drops the old room label
    IF p_item_type = 'machine' AND p_destination <> 'workshop' THEN
        DELETE FROM flags
         WHERE item_kind = 'machine' AND item_id = p_item_id
           AND note IN ('Room 1', 'Room 2', 'Room 3', 'Lounge', 'Workarea',
                        'Unassigned', 'Capasse II', 'Apron');
    END IF;

    INSERT INTO movements (
        movement_type, movement_date,
        machine_id, probe_id, printer_id, part_id,
        from_location, to_location, reason, notes,
        actor_id, group_ref, reference
    ) VALUES (
        'Return',
        COALESCE(p_date, to_char(now(), 'DD-MM-YYYY')),
        CASE WHEN p_item_type = 'machine' THEN p_item_id END,
        CASE WHEN p_item_type = 'probe'   THEN p_item_id END,
        CASE WHEN p_item_type = 'printer' THEN p_item_id END,
        CASE WHEN p_item_type = 'part'    THEN p_item_id END,
        v_from, v_to, v_reason, p_notes,
        auth.uid(), new_group_ref(), next_movement_reference()
    )
    RETURNING id INTO v_id;

    RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.return_to_inventory(text, bigint, text, text,
                                                      text)
    TO authenticated;

-- ------------------------------------------------------------
-- Repair: items already returned through the old function
--
-- An imported (BATCH-OLD) item that was returned to inventory kept
-- batch 30, so the Inventory page's batch filter hid it. Where the
-- latest movement is a Return, move the row to the current batch so it
-- shows on Inventory again. Sold and archived rows are left alone, and
-- only the old batch is touched - current stock is never rewritten.
-- ------------------------------------------------------------
DO $$
DECLARE
    v_batch bigint;
BEGIN
    SELECT NULLIF(value, '')::bigint INTO v_batch
      FROM app_settings WHERE key = 'current_batch_id' LIMIT 1;
    IF v_batch IS NULL THEN
        SELECT id INTO v_batch
          FROM batches WHERE code <> 'BATCH-OLD'
          ORDER BY id DESC LIMIT 1;
    END IF;
    IF v_batch IS NULL THEN
        RETURN;
    END IF;

    CREATE TEMP TABLE _latest_return ON COMMIT DROP AS
    WITH all_moves AS (
        SELECT 'machine' AS kind, machine_id AS item_id,
               movement_type, id
          FROM movements WHERE machine_id IS NOT NULL
        UNION ALL
        SELECT 'probe', probe_id, movement_type, id
          FROM movements WHERE probe_id IS NOT NULL
        UNION ALL
        SELECT 'printer', printer_id, movement_type, id
          FROM movements WHERE printer_id IS NOT NULL
        UNION ALL
        SELECT 'part', part_id, movement_type, id
          FROM movements WHERE part_id IS NOT NULL
    ), ranked AS (
        SELECT kind, item_id, movement_type,
               row_number() OVER (
                   PARTITION BY kind, item_id ORDER BY id DESC
               ) AS rn
          FROM all_moves
    )
    SELECT kind, item_id
      FROM ranked
     WHERE rn = 1 AND movement_type = 'Return';

    UPDATE machines m
       SET batch_id = v_batch
      FROM _latest_return r
     WHERE r.kind = 'machine' AND r.item_id = m.id
       AND m.batch_id = 30
       AND m.status NOT IN ('Sold', 'Archived');

    UPDATE probes p
       SET batch_id = v_batch
      FROM _latest_return r
     WHERE r.kind = 'probe' AND r.item_id = p.id
       AND p.batch_id = 30
       AND p.status NOT IN ('Sold', 'Archived');

    UPDATE printers p
       SET batch_id = v_batch
      FROM _latest_return r
     WHERE r.kind = 'printer' AND r.item_id = p.id
       AND p.batch_id = 30
       AND p.status NOT IN ('Sold', 'Archived');
END $$;

