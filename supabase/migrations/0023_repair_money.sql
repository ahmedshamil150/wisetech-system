-- ============================================================
-- 0023: repairs — money handed over when the item goes back.
--
--   * money_received / money_received_by record the payment taken
--     at the moment the repaired item is returned, and who took it
--   * create_repair wrote NULL for an empty problem, which the
--     NOT NULL problem_description rejects — "Problem (optional)"
--     now actually works
-- ============================================================

ALTER TABLE repair_jobs ADD COLUMN IF NOT EXISTS money_received NUMERIC(12,2);
ALTER TABLE repair_jobs ADD COLUMN IF NOT EXISTS money_received_by TEXT;

CREATE OR REPLACE FUNCTION public.create_repair(
    p_customer_name TEXT,
    p_contact       TEXT DEFAULT NULL,
    p_received_at   TEXT DEFAULT NULL,
    p_problem       TEXT DEFAULT NULL,
    p_items         JSONB DEFAULT '[]'::jsonb
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_customer_id BIGINT;
    v_job_id      BIGINT;
    v_entry       RECORD;
    v_model       TEXT;
BEGIN
    IF p_customer_name IS NULL OR btrim(p_customer_name) = '' THEN
        RAISE EXCEPTION 'a name is required — who sent the machine?';
    END IF;
    IF p_items IS NULL OR jsonb_array_length(p_items) = 0 THEN
        RAISE EXCEPTION 'add at least one item';
    END IF;

    SELECT id INTO v_customer_id
      FROM customers
     WHERE lower(name) = lower(btrim(p_customer_name))
     ORDER BY id
     LIMIT 1;

    IF v_customer_id IS NULL THEN
        INSERT INTO customers (name, phone, customer_type)
        VALUES (btrim(p_customer_name), nullif(btrim(coalesce(p_contact, '')), ''), 'Customer')
        RETURNING id INTO v_customer_id;
    END IF;

    INSERT INTO repair_jobs (
        job_number, customer_id, customer_contact, received_at,
        problem_description, status, actor_id
    ) VALUES (
        next_repair_job_number(),
        v_customer_id,
        nullif(btrim(coalesce(p_contact, '')), ''),
        COALESCE(nullif(btrim(coalesce(p_received_at, '')), ''), to_char(now(), 'DD-MM-YYYY')),
        COALESCE(nullif(btrim(coalesce(p_problem, '')), ''), ''),
        'Received',
        auth.uid()
    )
    RETURNING id INTO v_job_id;

    FOR v_entry IN SELECT value FROM jsonb_array_elements(p_items) LOOP
        v_model := nullif(btrim(coalesce(v_entry.value ->> 'model', '')), '');
        IF v_model IS NULL THEN
            RAISE EXCEPTION 'every item needs a model';
        END IF;
        INSERT INTO repair_items (repair_job_id, equipment_type, name_model, serial_number, quantity)
        VALUES (
            v_job_id,
            CASE WHEN v_entry.value ->> 'type' IN ('machine', 'probe', 'printer', 'other')
                 THEN v_entry.value ->> 'type' ELSE 'machine' END,
            v_model,
            nullif(btrim(coalesce(v_entry.value ->> 'serial', '')), ''),
            1
        );
    END LOOP;

    RETURN v_job_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.create_repair(TEXT, TEXT, TEXT, TEXT, JSONB)
    TO authenticated;
