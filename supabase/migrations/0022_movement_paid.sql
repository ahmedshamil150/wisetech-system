-- ============================================================
-- 0022: PAID flag on a movement (a send)
--
-- A send can be settled: movements.paid marks the whole send paid
-- or unpaid. Everything starts unpaid.
--
--   * paid column, default false
--   * create_movement gains p_paid, so a new movement can be
--     recorded as paid in the same call — any member may record a
--     movement (insert policy), while only admins may flip paid
--     afterwards (the admin-write policy stands)
-- ============================================================

ALTER TABLE movements ADD COLUMN paid boolean NOT NULL DEFAULT false;

-- ------------------------------------------------------------
-- create_movement (recreated: records the paid flag too)
-- ------------------------------------------------------------
DROP FUNCTION IF EXISTS public.create_movement(text, bigint, text, bigint,
                                                bigint, bigint, text, text,
                                                boolean, text);

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
    p_group_ref   text   DEFAULT NULL,
    p_paid        boolean DEFAULT false
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
        v_rec.current_location, v_to,
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
                                                  boolean, text, boolean)
    TO authenticated;
