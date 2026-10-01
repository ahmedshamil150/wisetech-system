-- ============================================================
-- 0013: DELETE A SEND, DELETE A PARTY
--
--   * delete_movement erases a whole send (its group) together with
--     the Return rows that belong to it, replays each item's
--     remaining history to restore its status and location, and
--     removes the customer/dealer when it was added with this send
--     and nothing else uses it
--   * deleting a send stitches the history: the first surviving send
--     of an item takes over the origin of the erased ones, so piecewise
--     deletes still end at the item's real starting place
--   * delete_party removes a customer/dealer together with its sends —
--     blocked while sales or repairs still point at it
--
--   Only the sender (or an admin) may delete a movement; only an
--   admin may delete a record from the records screen. Items that are
--   Sold or Archived are never restated — a sale is its own record.
-- ============================================================

-- ------------------------------------------------------------
-- delete_movement_rows (internal): stitch the history, remove the
-- given movement rows plus the Return rows that belong to them, and
-- replay what is left to restore every touched item's state
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
      ELSIF v_rec.movement_type = 'Return' THEN
        v_status := 'In Stock';
        v_loc := v_rec.to_location;
      ELSE
        v_loc := v_rec.to_location;   -- customer sends keep the status
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
        ELSIF v_rec.movement_type = 'Return' THEN
          v_status := v_stock;
          v_loc := v_rec.to_location;
        ELSE
          v_loc := v_rec.to_location;   -- customer sends keep the status
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

-- only the two public entry points may be called from the app
REVOKE EXECUTE ON FUNCTION public.delete_movement_rows(bigint[])
    FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.delete_movement_rows(bigint[])
    TO service_role;

-- ------------------------------------------------------------
-- delete_movement: erase one send
--
--   * the whole group goes (every item row of the send)
--   * Return rows that belong to those rows go with them
--   * the customer/dealer is removed too when it was created with
--     this send (within a day) and nothing else points at it
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.delete_movement(p_movement_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_rec     movements%ROWTYPE;
  v_ids     bigint[];
  v_custs   bigint[];
  v_deals   bigint[];
  v_party   bigint;
  v_created timestamptz;
BEGIN
  SELECT * INTO v_rec FROM movements WHERE id = p_movement_id;
  IF v_rec IS NULL THEN
    RAISE EXCEPTION 'movement not found';
  END IF;
  IF NOT public.is_admin() AND v_rec.actor_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'only the sender or an admin can delete this movement';
  END IF;

  IF v_rec.group_ref IS NOT NULL AND v_rec.group_ref <> '' THEN
    SELECT coalesce(array_agg(id), '{}') INTO v_ids
      FROM movements WHERE group_ref = v_rec.group_ref;
  ELSE
    v_ids := ARRAY[v_rec.id];
  END IF;

  SELECT coalesce(array_agg(DISTINCT customer_id)
                    FILTER (WHERE customer_id IS NOT NULL), '{}'),
         coalesce(array_agg(DISTINCT dealer_id)
                    FILTER (WHERE dealer_id IS NOT NULL), '{}'),
         min(created_at)
    INTO v_custs, v_deals, v_created
    FROM movements
   WHERE id = ANY(v_ids);

  PERFORM public.delete_movement_rows(v_ids);

  -- a customer/dealer added with this send goes with it — as long as
  -- nothing else in the app still points at it
  FOREACH v_party IN ARRAY v_custs LOOP
    IF NOT EXISTS (SELECT 1 FROM movements WHERE customer_id = v_party)
       AND NOT EXISTS (SELECT 1 FROM sales WHERE customer_id = v_party)
       AND NOT EXISTS (SELECT 1 FROM repair_jobs WHERE customer_id = v_party)
       AND coalesce((SELECT created_at FROM customers WHERE id = v_party),
                    'epoch'::timestamptz)
              >= coalesce(v_created, now()) - interval '1 day'
    THEN
      DELETE FROM customers WHERE id = v_party;
    END IF;
  END LOOP;

  FOREACH v_party IN ARRAY v_deals LOOP
    IF NOT EXISTS (SELECT 1 FROM movements WHERE dealer_id = v_party)
       AND coalesce((SELECT created_at FROM dealers WHERE id = v_party),
                    'epoch'::timestamptz)
              >= coalesce(v_created, now()) - interval '1 day'
    THEN
      DELETE FROM dealers WHERE id = v_party;
    END IF;
  END LOOP;
END;
$$;

GRANT EXECUTE ON FUNCTION public.delete_movement(bigint) TO authenticated;

-- ------------------------------------------------------------
-- delete_party: erase a customer/dealer with its sends
--
--   admin only; raises a clear error while sales or repair jobs
--   still point at the record (nothing is touched then)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.delete_party(p_table text, p_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_name text;
  v_ids  bigint[];
  v_used bigint;
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'only an admin can delete a record';
  END IF;
  IF p_table NOT IN ('customers', 'dealers') THEN
    RAISE EXCEPTION 'unknown table: %', p_table;
  END IF;

  IF p_table = 'customers' THEN
    SELECT name INTO v_name FROM customers WHERE id = p_id;
    IF v_name IS NULL THEN
      RAISE EXCEPTION 'record not found';
    END IF;
    SELECT count(*) INTO v_used FROM sales WHERE customer_id = p_id;
    IF v_used > 0 THEN
      RAISE EXCEPTION '"%" is used by % sale(s) — delete the sales first',
                      v_name, v_used;
    END IF;
    SELECT count(*) INTO v_used FROM repair_jobs WHERE customer_id = p_id;
    IF v_used > 0 THEN
      RAISE EXCEPTION '"%" is used by % repair job(s) — delete them first',
                      v_name, v_used;
    END IF;
    SELECT coalesce(array_agg(id), '{}') INTO v_ids
      FROM movements WHERE customer_id = p_id;
  ELSE
    SELECT name INTO v_name FROM dealers WHERE id = p_id;
    IF v_name IS NULL THEN
      RAISE EXCEPTION 'record not found';
    END IF;
    SELECT coalesce(array_agg(id), '{}') INTO v_ids
      FROM movements WHERE dealer_id = p_id;
  END IF;

  PERFORM public.delete_movement_rows(v_ids);

  EXECUTE format('DELETE FROM %I WHERE id = $1', p_table) USING p_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.delete_party(text, bigint) TO authenticated;
