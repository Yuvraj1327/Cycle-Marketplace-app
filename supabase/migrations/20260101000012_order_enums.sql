-- 12: new enum values. Kept in its own migration: a value added with ALTER TYPE cannot be used in the same transaction.
alter type public.payment_status add value if not exists 'processing';
alter type public.payment_status add value if not exists 'refunded';
alter type public.payment_status add value if not exists 'partially_refunded';

create type public.settlement_status as enum ('pending', 'ready', 'paid', 'cancelled');
