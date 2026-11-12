-- Fix the existing bet guard trigger: the live bets table has no "legs" column.
-- Keep its original purpose: block new/edited wagers from deleted profiles,
-- while allowing result settlement and payout/status updates on existing bets.
create or replace function public.reject_bets_from_deleted_profiles()
returns trigger
language plpgsql
security definer
set search_path = public
as $function$
begin
  if tg_op = 'UPDATE'
     and old.bet_amount is not distinct from new.bet_amount
     and old.game_id is not distinct from new.game_id
     and old.bet_selection is not distinct from new.bet_selection then
    return new;
  end if;

  if exists (
    select 1 from public.profiles
    where id = new.user_id and is_deleted = true
  ) then
    raise exception 'החשבון אינו פעיל';
  end if;
  return new;
end;
$function$;

revoke all on function public.reject_bets_from_deleted_profiles() from public, anon, authenticated;