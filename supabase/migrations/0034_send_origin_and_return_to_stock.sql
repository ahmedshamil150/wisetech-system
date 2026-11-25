-- ============================================================
-- 0034: SEND ORIGIN + RETURN A BRANCH / SOLD ITEM TO STOCK
--
--   * create_movement gains p_from_location, so a send can record the
--     page the item really left from (Workshop, Missing items,
--     Basement) instead of a stale current_location.
--   * return_item_to_stock moves a branch or sold item to a chosen
--     place - Main Inventory, Workshop or Basement - carries a
--     machine's kit with it and writes a Return row for every item
--     that moved, so history shows the way back.
-- ============================================================

-- ------------------------------------------------------------
-- create_movement (recreated: records the origin page too)
-- ------------------------------------------------------------
DROP FUNCTION IF EXISTS public.create_movement(text, bigint, text, bigint,
                                                bigint, bigint, text, text,
                                                boolean, text, boolean);

CREATE OR REPLACE FUNCTION public.create_movement(
    p_item_type     text,
    p_item_id       bigint,
    p_kind          text,
    p_dealer_id     bigint DEFAULT NULL,
    p_customer_id   bigint DEFAULT NULL,
    p_workshop_id   bigint DEFAULT NULL,
    p_date          text   DEFAULT NULL,
    p_notes         text   DEFAULT NULL,
    p_demo          boolean DEFAULT false,
    p_group_ref     text   DEFAULT NULL,
    p_paid          boolean DEFAULT false,
    p_from_location text   DEFAULT NULL
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
    IF p_kind NOT IN ('Workshop', 'Dealer', 'Customer', 'Branch') THEN
        RAISE EXCEPTION 'unknown movement type: %', p_kind;
    END IF;
    IF p_kind = 'Workshop' THEN
        SELECT id INTO p_workshop_id FROM workshops
          WHERE is_archived = 0 ORDER BY id LIMIT 1;
        IF p_workshop_id IS NULL THEN
            RAISE EXCEPTION 'no workshop configured';
        END IF;
        p_demo := false;   -- only dealer / customer sends can be demos
    ELSIF p_kind = 'Branch' THEN
        p_demo := false;   -- a transfer to our own branch is never a demo
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
    ELSIF p_kind = 'Branch' THEN
        v_to := 'Lahore branch';   -- the company's own location
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

    -- workshop / dealer / customer / branch all take the item out of
    -- stock; a sale or an archive is never overwritten
    IF p_kind = 'Workshop' THEN
        v_new_status := 'With Workshop';
    ELSIF p_kind = 'Dealer' THEN
        v_new_status := 'With Dealer';
    ELSIF v_rec.status IN ('Sold', 'Archived') THEN
        v_new_status := v_rec.status;
    ELSIF p_kind = 'Branch' THEN
        v_new_status := 'With Branch';
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
        actor_id, group_ref, reference, is_demo, paid
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
        COALESCE(NULLIF(p_from_location, ''), v_rec.current_location), v_to,
        'Sent to ' || CASE WHEN p_kind = 'Workshop' THEN 'workshop'
                           WHEN p_kind = 'Branch' THEN 'lahore branch'
                           WHEN p_kind = 'Dealer' THEN 'dealer'
                           ELSE 'customer' END
          || CASE WHEN p_demo THEN ' (demo)' ELSE '' END,
        p_notes,
        auth.uid(), COALESCE(p_group_ref, new_group_ref()),
        next_movement_reference(),
        p_demo,
        COALESCE(p_paid, false)
    )
    RETURNING id INTO v_id;

    RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.create_movement(text, bigint, text, bigint,
                                                  bigint, bigint, text, text,
                                                  boolean, text, boolean, text)
    TO authenticated;

-- ------------------------------------------------------------
-- return_item_to_stock: branch / sold item -> chosen stock list
--
--   p_destination: 'inventory' | 'workshop' | 'basement'
--
--   * status and location take the chosen list's values
--   * a machine carries its probes, printer and parts with it
--   * the Missing flag is cleared for everything that moved
--   * a Return row is written for each item, with the old place as
--     from_location and the chosen list as to_location
--   * an old-side row (BATCH-OLD, id 30) coming back to Main
--     Inventory joins the current batch, otherwise the Inventory
--     batch filter would keep it hidden
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.return_item_to_stock(
    p_item_type  text,
    p_item_id    bigint,
    p_destination text,
    p_date       text DEFAULT NULL,
    p_notes      text DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_table      text;
    v_rec        record;
    v_from       text;
    v_to         text;
    v_status     text;
    v_reason     text;
    v_group      text;
    v_batch      bigint;
    v_kit_table  text;
    v_kit_kind   text;
    v_kit        record;
    v_kit_status text;
    v_id         bigint;
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
    IF v_rec IS NULL THEN
        RAISE EXCEPTION 'item % not found in %', p_item_id, v_table;
    END IF;

    v_from := v_rec.current_location;
    v_group := new_group_ref();

    IF p_destination = 'workshop' THEN
        v_to := 'Workshop';
        v_status := 'With Workshop';
        v_reason := 'Returned to workshop';
    ELSIF p_destination = 'basement' THEN
        v_to := 'Basement';
        v_status := CASE
            WHEN p_item_type = 'machine' THEN 'In Stock'
            WHEN v_rec.assigned_machine_id IS NOT NULL THEN 'With Machine'
            ELSE 'Available' END;
        v_reason := 'Returned to basement';
    ELSE
        v_to := 'Company';
        v_status := CASE
            WHEN p_item_type = 'machine' THEN 'In Stock'
            WHEN v_rec.assigned_machine_id IS NOT NULL THEN 'With Machine'
            ELSE 'Available' END;
        v_reason := 'Returned to inventory';
        -- old-side stock joins the current batch when it comes back to
        -- the main Inventory list
        IF v_rec.batch_id = 30 THEN
            SELECT NULLIF(value, '')::bigint INTO v_batch
              FROM app_settings WHERE key = 'current_batch_id' LIMIT 1;
        END IF;
    END IF;

    IF v_batch IS NOT NULL THEN
        EXECUTE format(
            'UPDATE %I SET status = $1, current_location = $2, '
            'batch_id = $3 WHERE id = $4', v_table)
            USING v_status, v_to, v_batch, p_item_id;
    ELSE
        EXECUTE format(
            'UPDATE %I SET status = $1, current_location = $2 WHERE id = $3',
            v_table)
            USING v_status, v_to, p_item_id;
    END IF;

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
        auth.uid(), v_group, next_movement_reference()
    )
    RETURNING id INTO v_id;

    -- a machine brings its kit along, and every kit member gets its own
    -- Return row so its history says where it came back to
    IF p_item_type = 'machine' THEN
        FOR v_kit_table, v_kit_kind IN
            SELECT * FROM (VALUES ('probes', 'probe'),
                                  ('printers', 'printer'),
                                  ('parts', 'part')) AS t(tbl, kind)
        LOOP
            FOR v_kit IN EXECUTE format(
                'SELECT id, status, current_location FROM %I '
                'WHERE assigned_machine_id = $1', v_kit_table)
                USING p_item_id
            LOOP
                IF v_kit.status IN ('Sold', 'Archived') THEN
                    CONTINUE;
                END IF;

                v_kit_status := CASE
                    WHEN p_destination = 'workshop' THEN 'With Workshop'
                    WHEN p_destination = 'inventory' THEN 'With Machine'
                    ELSE v_kit.status END;

                EXECUTE format(
                    'UPDATE %I SET status = $1, current_location = $2 '
                    'WHERE id = $3', v_kit_table)
                    USING v_kit_status, v_to, v_kit.id;

                DELETE FROM flags
                 WHERE item_kind = v_kit_kind AND item_id = v_kit.id
                   AND note = 'Missing';

                INSERT INTO movements (
                    movement_type, movement_date,
                    machine_id, probe_id, printer_id, part_id,
                    from_location, to_location, reason, notes,
                    actor_id, group_ref, reference
                ) VALUES (
                    'Return',
                    COALESCE(p_date, to_char(now(), 'DD-MM-YYYY')),
                    CASE WHEN v_kit_kind = 'machine' THEN v_kit.id END,
                    CASE WHEN v_kit_kind = 'probe'   THEN v_kit.id END,
                    CASE WHEN v_kit_kind = 'printer' THEN v_kit.id END,
                    CASE WHEN v_kit_kind = 'part'    THEN v_kit.id END,
                    v_kit.current_location, v_to, v_reason, p_notes,
                    auth.uid(), v_group, next_movement_reference()
                );
            END LOOP;
        END LOOP;
    END IF;

    RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.return_item_to_stock(text, bigint, text,
                                                      text, text)
    TO authenticated;
