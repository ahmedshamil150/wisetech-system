-- ============================================================
-- 0014: DELETE ONE MOVEMENT ROW
--
--   delete_movement erases a whole send. Sometimes a single item was
--   moved by mistake — only its own row should go, the rest of the
--   send stays, and the item returns to stock.
--
--   delete_movement_row removes exactly that one row (plus the Return
--   rows that belong to it) through the same internal helper as
--   0013: the history is stitched and replayed, so the item ends up
--   wherever its remaining history puts it (usually back in the
--   inventory). Sold / Archived items are never restated.
--
--   The party is NOT deleted here — the other rows of the send still
--   point at it. Same permission rule as delete_movement: the sender
--   or an admin.
-- ============================================================

CREATE OR REPLACE FUNCTION public.delete_movement_row(p_movement_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_rec movements%ROWTYPE;
BEGIN
  SELECT * INTO v_rec FROM movements WHERE id = p_movement_id;
  IF v_rec IS NULL THEN
    RAISE EXCEPTION 'movement not found';
  END IF;
  IF NOT public.is_admin() AND v_rec.actor_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'only the sender or an admin can delete this movement';
  END IF;

  PERFORM public.delete_movement_rows(ARRAY[v_rec.id]);
END;
$$;

GRANT EXECUTE ON FUNCTION public.delete_movement_row(bigint) TO authenticated;
