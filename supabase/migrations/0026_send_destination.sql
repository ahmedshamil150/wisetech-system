-- ============================================================
-- 0026: CORRECT WHERE A SEND WENT
--
-- A send can be recorded against the wrong place — a machine typed
-- as sent to a customer that really went to a dealer, a misspelt
-- party, or a dealer trip that was really our own branch. The Edit
-- sheet corrects it in place:
--
--   * every row of the send takes the new kind, party, destination
--     name and demo mark; a Sold row stays Sold
--   * the items follow — status and current location are rewritten
--     as if the send had been recorded right the first time, but
--     only while this send is still the item's latest movement, and
--     never over a Sold or Archived item
--
-- Admins only: this rewrites history, so it is not open to every
-- member the way recording a movement is.
-- ============================================================

CREATE OR REPLACE FUNCTION public.set_send_destination(
    p_movement_ids bigint[],
    p_kind         text,
    p_dealer_id    bigint  DEFAULT NULL,
    p_customer_id  bigint  DEFAULT NULL,
    p_demo         boolean DEFAULT false
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_workshop_id bigint;
    v_to          text;
    v_word        text;
    v_new_status  text;
    v_table       text;
    v_col         text;
    v_item        bigint;
    v_latest      bigint;
    v_status      text;
BEGIN
    IF NOT public.is_admin() THEN
        RAISE EXCEPTION 'only an admin can change where a send went';
    END IF;
    IF p_movement_ids IS NULL
       OR coalesce(array_length(p_movement_ids, 1), 0) = 0 THEN
        RETURN;
    END IF;
    IF p_kind NOT IN ('Workshop', 'Dealer', 'Customer', 'Branch') THEN
        RAISE EXCEPTION 'unknown movement type: %', p_kind;
    END IF;

    -- only dealer and customer sends carry a party, and only they can
    -- be demos; the workshop and our own branch are company locations
    IF p_kind <> 'Dealer' THEN
        p_dealer_id := NULL;
    END IF;
    IF p_kind <> 'Customer' THEN
        p_customer_id := NULL;
    END IF;
    IF p_kind = 'Workshop' THEN
        SELECT id INTO v_workshop_id FROM workshops
          WHERE is_archived = 0 ORDER BY id LIMIT 1;
        IF v_workshop_id IS NULL THEN
            RAISE EXCEPTION 'no workshop configured';
        END IF;
        p_demo := false;
    ELSIF p_kind = 'Branch' THEN
        p_demo := false;
    END IF;

    -- the destination name is written the way create_movement writes
    -- it, placeholder included when the party has no name yet
    IF p_kind = 'Workshop' THEN
        v_to := 'Workshop';
        v_word := 'workshop';
    ELSIF p_kind = 'Branch' THEN
        v_to := 'Lahore branch';
        v_word := 'lahore branch';
    ELSIF p_kind = 'Dealer' THEN
        IF p_dealer_id IS NOT NULL THEN
            SELECT name INTO v_to FROM dealers WHERE id = p_dealer_id;
            IF v_to IS NULL THEN
                RAISE EXCEPTION 'destination not found';
            END IF;
        ELSE
            v_to := 'Dealer';
        END IF;
        v_word := 'dealer';
    ELSE
        IF p_customer_id IS NOT NULL THEN
            SELECT name INTO v_to FROM customers WHERE id = p_customer_id;
            IF v_to IS NULL THEN
                RAISE EXCEPTION 'destination not found';
            END IF;
        ELSE
            v_to := 'Customer';
        END IF;
        v_word := 'customer';
    END IF;

    v_new_status := CASE p_kind
                        WHEN 'Workshop' THEN 'With Workshop'
                        WHEN 'Dealer'   THEN 'With Dealer'
                        WHEN 'Branch'   THEN 'With Branch'
                        ELSE 'With Customer'
                    END;

    -- every row of the send, however many groups it holds; Return rows
    -- are history of another kind and never rewritten here
    UPDATE movements
       SET movement_type = p_kind,
           dealer_id   = CASE WHEN p_kind = 'Dealer'   THEN p_dealer_id   END,
           customer_id = CASE WHEN p_kind = 'Customer' THEN p_customer_id END,
           workshop_id = CASE WHEN p_kind = 'Workshop' THEN v_workshop_id END,
           to_location = v_to,
           is_demo     = p_demo,
           reason      = CASE
                             WHEN coalesce(reason, '') LIKE '%Sold%'
                                 THEN reason
                             ELSE 'Sent to ' || v_word
                                  || CASE WHEN p_demo THEN ' (demo)' ELSE '' END
                         END
     WHERE id = ANY(p_movement_ids)
       AND movement_type <> 'Return';

    -- the items follow while this send is still the last thing that
    -- happened to them — a later return or send decides on its own
    FOR v_table, v_col IN
        SELECT * FROM (VALUES ('machines', 'machine_id'),
                              ('probes',   'probe_id'),
                              ('printers', 'printer_id'),
                              ('parts',    'part_id')) AS t(tbl, col)
    LOOP
        FOR v_item IN EXECUTE format(
            'SELECT DISTINCT %1$I FROM movements
              WHERE id = ANY($1) AND %1$I IS NOT NULL', v_col)
            USING p_movement_ids
        LOOP
            EXECUTE format(
                'SELECT id FROM movements WHERE %1$I = $1
                  ORDER BY id DESC LIMIT 1', v_col)
                INTO v_latest USING v_item;
            IF v_latest IS NULL OR NOT (v_latest = ANY(p_movement_ids)) THEN
                CONTINUE;
            END IF;

            EXECUTE format('SELECT status FROM %I WHERE id = $1', v_table)
                INTO v_status USING v_item;
            IF v_status IN ('Sold', 'Archived') THEN
                CONTINUE;
            END IF;

            EXECUTE format(
                'UPDATE %I SET status = $1, current_location = $2
                  WHERE id = $3', v_table)
                USING v_new_status, v_to, v_item;
        END LOOP;
    END LOOP;
END;
$$;

GRANT EXECUTE ON FUNCTION public.set_send_destination(bigint[], text, bigint,
                                                     bigint, boolean)
    TO authenticated;
