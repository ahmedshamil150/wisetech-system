-- Name of the person who sold it, asked when a send is marked Sold.
-- Free text — shop staff may not have an account — and optional, so
-- older sold sends stay as they are. Stored on every row of the send,
-- the same way paid, reason and sale_amount are.
alter table movements add column if not exists sold_by text;
