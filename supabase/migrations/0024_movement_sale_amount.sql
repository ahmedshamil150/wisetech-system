-- Sale amount recorded when a send is marked Sold (optional — blank is
-- fine). Stored on every row of the send, the same way paid and reason
-- are, so the send reads as one settlement. Existing rows are untouched.
alter table movements add column if not exists sale_amount numeric;
