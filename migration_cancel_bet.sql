-- Allow cancelled bets to stay in history and be refunded before kickoff.

do $$
declare
  v_name text;
begin
  select conname into v_name
  from pg_constraint
  where conrelid = 'public.bets'::regclass
    and contype = 'c'
    and pg_get_constraintdef(oid) ilike '%status%';
  if v_name is not null then
    execute format('alter table public.bets drop constraint %I', v_name);
  end if;
end $$;

alter table public.bets add constraint bets_status_check
  check (status in ('pending', 'won', 'lost', 'void', 'cancelled'));

drop index if exists public.bets_one_slip_per_selection;
create unique index bets_one_slip_per_selection
  on public.bets (user_id, game_id, bet_selection)
  where status = 'pending';

create or replace function public.edit_bet(
  p_bet_id bigint,
  p_selection text,
  p_amount numeric
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_bet public.bets%rowtype;
  v_game public.games%rowtype;
  v_amount numeric(10,2);
  v_odds numeric(4,2);
  v_payout numeric(10,2);
  v_balance numeric(10,2);
begin
  if v_uid is null then
    raise exception 'יש להתחבר';
  end if;
  if p_selection not in ('1', 'X', '2') then
    raise exception 'בחירה לא תקינה';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'סכום לא תקין';
  end if;
  v_amount := round(p_amount, 2);
  if v_amount <= 0 then
    raise exception 'סכום לא תקין';
  end if;

  select * into v_bet
  from public.bets
  where id = p_bet_id and user_id = v_uid
  for update;
  if not found then
    raise exception 'ההימור לא נמצא';
  end if;
  if v_bet.status <> 'pending' then
    raise exception 'אפשר לערוך רק הימור ממתין';
  end if;

  select * into v_game
  from public.games
  where id = v_bet.game_id
  for update;
  if not found then
    raise exception 'המשחק לא נמצא';
  end if;
  if v_game.match_time is null or v_game.match_time <= now() then
    raise exception 'המשחק כבר התחיל';
  end if;

  if exists (
    select 1 from public.bets
    where user_id = v_uid
      and game_id = v_bet.game_id
      and bet_selection = p_selection
      and status = 'pending'
      and id <> v_bet.id
  ) then
    raise exception 'כבר קיים הימור על הבחירה הזו';
  end if;

  if p_selection = v_bet.bet_selection then
    v_odds := v_bet.odds;
  else
    v_odds := case p_selection
      when '1' then v_game.home_odds
      when 'X' then v_game.draw_odds
      else v_game.away_odds
    end;
  end if;
  if v_odds is null or v_odds < 1.01 then
    raise exception 'היחס לא זמין';
  end if;
  if v_amount * v_odds > 99999999.99 then
    raise exception 'הסכום חורג מהתקרה';
  end if;
  v_payout := round(v_amount * v_odds, 2);

  select balance into v_balance
  from public.profiles
  where id = v_uid
  for update;
  if v_balance + v_bet.bet_amount < v_amount then
    raise exception 'יתרה לא מספיקה';
  end if;

  update public.profiles
  set balance = balance + v_bet.bet_amount - v_amount
  where id = v_uid;

  begin
    update public.bets
    set bet_selection = p_selection,
        bet_amount = v_amount,
        odds = v_odds,
        potential_payout = v_payout
    where id = v_bet.id;
  exception when unique_violation then
    raise exception 'כבר קיים הימור על הבחירה הזו';
  end;

  select balance into v_balance from public.profiles where id = v_uid;
  return jsonb_build_object(
    'bet_id', v_bet.id,
    'bet_selection', p_selection,
    'bet_amount', v_amount,
    'odds', v_odds,
    'potential_payout', v_payout,
    'balance', v_balance
  );
end;
$$;

create or replace function public.cancel_bet(p_bet_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_bet public.bets%rowtype;
  v_game public.games%rowtype;
  v_balance numeric(10,2);
begin
  if v_uid is null then
    raise exception 'יש להתחבר';
  end if;

  select * into v_bet
  from public.bets
  where id = p_bet_id and user_id = v_uid
  for update;
  if not found then
    raise exception 'ההימור לא נמצא';
  end if;
  if v_bet.status <> 'pending' then
    raise exception 'אפשר לבטל רק הימור ממתין';
  end if;

  select * into v_game
  from public.games
  where id = v_bet.game_id
  for update;
  if not found then
    raise exception 'המשחק לא נמצא';
  end if;
  if v_game.status <> 'upcoming' or v_game.match_time is null or v_game.match_time <= now() then
    raise exception 'אפשר לבטל רק לפני תחילת המשחק';
  end if;

  update public.profiles
  set balance = balance + v_bet.bet_amount
  where id = v_uid;

  update public.bets
  set status = 'cancelled'
  where id = v_bet.id;

  select balance into v_balance from public.profiles where id = v_uid;
  return jsonb_build_object(
    'bet_id', v_bet.id,
    'status', 'cancelled',
    'refund', v_bet.bet_amount,
    'balance', v_balance
  );
end;
$$;

revoke all on function public.cancel_bet(bigint) from public, anon, authenticated;
grant execute on function public.cancel_bet(bigint) to authenticated;
notify pgrst, 'reload schema';
