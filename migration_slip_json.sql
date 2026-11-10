alter table public.bets add column if not exists total_odds numeric(14,4);
alter table public.bets add column if not exists legs jsonb;
update public.bets set total_odds = odds where total_odds is null;
