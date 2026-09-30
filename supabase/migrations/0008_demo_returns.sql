-- ============================================================
-- 0008: DEMO SENDS + RETURN TO INVENTORY
--
--   * movements.is_demo marks a unit that was sent to a dealer or a
--     customer as a demo (it stays company stock until it comes back)
--   * create_movement gains p_demo; the reason spells the demo out too
--   * return_to_inventory puts any item back from anywhere:
--     status, location and a "Return" movement row so the history shows
--     when it came back and where it went
-- ============================================================

ALTER TABLE movements
    ADD COLUMN IF NOT EXISTS is_demo boolean NOT NULL DEFAULT false;

-- ------------------------------------------------------------
-- create_movement (recreated with p_demo)
-- ------------------------------------------------------------
DROP FUNCTION IF EXISTS public.create_movement(text, bigint, text, bigint,
                                               bigint, bigint, text, text);

CREATE OR REPLACE FUNCTION public.create_movement(
    p_item_type   text,
    p_item_id     bigint,
    p_kind        text,
    p_dealer_id   bigint DEFAULT NULL,
    p_customer_id bigint DEFAULT NULL,
    p_workshop_id bigint DEFAULT NULL,
    p_date        text   DEFAULT NULL,
    p_notes       text   DEFAULT NULL,
    p_demo        boolean DEFAULT false
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
    IF p_kind = 'Dealer' AND p_dealer_id IS NULL THEN
        RAISE EXCEPTION 'a dealer must be chosen';
    END IF;
    IF p_kind = 'Customer' AND p_customer_id IS NULL THEN
        RAISE EXCEPTION 'a customer must be chosen';
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

    SELECT CASE WHEN p_kind = 'Workshop' THEN 'Workshop'
                WHEN p_kind = 'Dealer'
                    THEN (SELECT name FROM dealers WHERE id = p_dealer_id)
                ELSE (SELECT name FROM customers WHERE id = p_customer_id) END
      INTO v_to;

    IF v_to IS NULL THEN
        RAISE EXCEPTION 'destination not found';
    END IF;

    -- status changes for workshop / dealer, customer only changes location
    IF p_kind = 'Workshop' THEN
        v_new_status := 'With Workshop';
    ELSIF p_kind = 'Dealer' THEN
        v_new_status := 'With Dealer';
    ELSE
        v_new_status := v_rec.status;
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
        auth.uid(), new_group_ref(), next_movement_reference(),
        p_demo
    )
    RETURNING id INTO v_id;

    RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.create_movement(text, bigint, text, bigint,
                                                  bigint, bigint, text, text,
                                                  boolean)
    TO authenticated;

-- ------------------------------------------------------------
-- return_to_inventory: any item, from anywhere, back to stock
--
--   * status goes back to the in-stock value for its kind
--   * location goes back to where it left from (last outbound
--     movement), falling back to 'Company'
--   * a 'Return' movement row records when it came back
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.return_to_inventory(
    p_item_type text,
    p_item_id   bigint,
    p_date      text DEFAULT NULL,
    p_notes     text DEFAULT NULL
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
    v_prev        text;
    v_mstatus     text;
    v_clear_link  boolean := false;
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

    IF v_table = 'machines' THEN
        EXECUTE format(
            'SELECT id, status, current_location, '
            'NULL::bigint AS assigned_machine_id '
            'FROM machines WHERE id = $1')
            INTO v_rec USING p_item_id;
    ELSE
        EXECUTE format(
            'SELECT id, status, current_location, assigned_machine_id '
            'FROM %I WHERE id = $1', v_table)
            INTO v_rec USING p_item_id;
    END IF;

    -- note: EXECUTE ... INTO does not set FOUND, check the record instead
    IF v_rec IS NULL THEN
        RAISE EXCEPTION 'item % not found in %', p_item_id, v_table;
    END IF;

    v_from := v_rec.current_location;

    -- where the item was before it left: the from_location of its most
    -- recent outbound movement
    SELECT from_location INTO v_prev
      FROM movements
     WHERE (CASE p_item_type
              WHEN 'machine' THEN machine_id
              WHEN 'probe'   THEN probe_id
              WHEN 'printer' THEN printer_id
              ELSE part_id END) = p_item_id
       AND movement_type <> 'Return'
     ORDER BY id DESC
     LIMIT 1;
    v_to := COALESCE(NULLIF(v_prev, ''), 'Company');

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

    IF v_table = 'machines' THEN
        EXECUTE format(
            'UPDATE %I SET status = $1, current_location = $2 WHERE id = $3',
            v_table)
            USING v_new_status, v_to, p_item_id;
    ELSE
        EXECUTE format(
            'UPDATE %I SET status = $1, current_location = $2, '
            'assigned_machine_id = $3 WHERE id = $4',
            v_table)
            USING v_new_status, v_to,
                  CASE WHEN v_clear_link THEN NULL
                       ELSE v_rec.assigned_machine_id END,
                  p_item_id;
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
        v_from, v_to, 'Returned to inventory', p_notes,
        auth.uid(), new_group_ref(), next_movement_reference()
    )
    RETURNING id INTO v_id;

    RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.return_to_inventory(text, bigint, text, text)
    TO authenticated;
