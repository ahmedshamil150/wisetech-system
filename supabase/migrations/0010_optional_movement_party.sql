-- ============================================================
-- 0010: MOVEMENTS WITHOUT A DEALER / CUSTOMER NAME
--
--   * create_movement no longer requires a dealer or customer id:
--     the movement is recorded with a placeholder destination
--     ('Dealer' / 'Customer') and the name can be added later
--   * set_movement_party fills the name in afterwards — only the
--     person who recorded the movement (or an admin) may do it,
--     and the item's location follows only if it is still sitting
--     at the placeholder
-- ============================================================

-- ------------------------------------------------------------
-- create_movement (recreated: party optional, shared group ref)
--
--   p_group_ref lets one save loop put every item of a single send
--   under the same group so the list shows them as one card and the
--   dealer/customer name only has to be added once. Falls back to a
--   fresh ref for single-item calls.
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
-- set_movement_party: add the dealer/customer name later
--
--   * only for dealer/customer movements whose party is still empty
--   * the sender of the movement or an admin may set it
--   * the item's location follows only while it still sits at the
--     placeholder ('Dealer' / 'Customer')
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.set_movement_party(
    p_movement_id bigint,
    p_dealer_id   bigint DEFAULT NULL,
    p_customer_id bigint DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_rec    movements%ROWTYPE;
    v_name   text;
    v_old_to text;
BEGIN
    IF (p_dealer_id IS NULL) = (p_customer_id IS NULL) THEN
        RAISE EXCEPTION 'provide a dealer id or a customer id (exactly one)';
    END IF;

    SELECT * INTO v_rec FROM movements WHERE id = p_movement_id;
    IF v_rec IS NULL THEN
        RAISE EXCEPTION 'movement not found';
    END IF;

    IF NOT public.is_admin() AND v_rec.actor_id IS DISTINCT FROM auth.uid() THEN
        RAISE EXCEPTION 'only the sender or an admin can update this movement';
    END IF;

    IF p_dealer_id IS NOT NULL THEN
        IF v_rec.movement_type <> 'Dealer' THEN
            RAISE EXCEPTION 'this movement is not a dealer send';
        END IF;
        IF v_rec.dealer_id IS NOT NULL THEN
            RAISE EXCEPTION 'a dealer is already set';
        END IF;
        SELECT name INTO v_name FROM dealers WHERE id = p_dealer_id;
        IF v_name IS NULL THEN
            RAISE EXCEPTION 'destination not found';
        END IF;
        UPDATE movements
           SET dealer_id = p_dealer_id, to_location = v_name
         WHERE id = p_movement_id;
    ELSE
        IF v_rec.movement_type <> 'Customer' THEN
            RAISE EXCEPTION 'this movement is not a customer send';
        END IF;
        IF v_rec.customer_id IS NOT NULL THEN
            RAISE EXCEPTION 'a customer is already set';
        END IF;
        SELECT name INTO v_name FROM customers WHERE id = p_customer_id;
        IF v_name IS NULL THEN
            RAISE EXCEPTION 'destination not found';
        END IF;
        UPDATE movements
           SET customer_id = p_customer_id, to_location = v_name
         WHERE id = p_movement_id;
    END IF;

    -- follow the item only while it is still at the placeholder
    v_old_to := v_rec.to_location;
    IF v_rec.machine_id IS NOT NULL THEN
        UPDATE machines SET current_location = v_name
         WHERE id = v_rec.machine_id AND current_location = v_old_to;
    ELSIF v_rec.probe_id IS NOT NULL THEN
        UPDATE probes SET current_location = v_name
         WHERE id = v_rec.probe_id AND current_location = v_old_to;
    ELSIF v_rec.printer_id IS NOT NULL THEN
        UPDATE printers SET current_location = v_name
         WHERE id = v_rec.printer_id AND current_location = v_old_to;
    ELSIF v_rec.part_id IS NOT NULL THEN
        UPDATE parts SET current_location = v_name
         WHERE id = v_rec.part_id AND current_location = v_old_to;
    END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION public.set_movement_party(bigint, bigint, bigint)
    TO authenticated;
