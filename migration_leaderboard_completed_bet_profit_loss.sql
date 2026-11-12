-- Rank users by net profit/loss from settled bets only.
-- Pending bets are intentionally excluded; void bets have no net effect.
create or replace function public.groups_leaderboard(p_group_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  v jsonb;
begin
  if auth.uid() is null then
    raise exception 'יש להתחבר';
  end if;

  if p_group_id = '00000000-0000-0000-0000-000000000001'::uuid then
    select coalesce(
      jsonb_agg(
        jsonb_build_object(
          'id', p.id,
          'username', p.username,
          'net_profit', stats.net_profit
        )
        order by stats.net_profit desc, p.username
      ),
      '[]'::jsonb
    )
    into v
    from public.profiles p
    left join lateral (
      select coalesce(
        sum(
          case
            when b.status = 'won'
              then coalesce(b.potential_payout, 0) - coalesce(b.bet_amount, 0)
            when b.status = 'lost'
              then -coalesce(b.bet_amount, 0)
            else 0
          end
        ),
        0
      )::numeric(12,2) as net_profit
      from public.bets b
      where b.user_id = p.id
        and b.status in ('won', 'lost')
    ) stats on true
    where coalesce(p.is_deleted, false) = false;
  else
    if not exists (
      select 1
      from public.app_group_members
      where group_id = p_group_id
        and user_id = auth.uid()
    ) then
      raise exception 'צריך להצטרף לקבוצה כדי לצפות בטבלה';
    end if;

    select coalesce(
      jsonb_agg(
        jsonb_build_object(
          'id', p.id,
          'username', p.username,
          'net_profit', stats.net_profit
        )
        order by stats.net_profit desc, p.username
      ),
      '[]'::jsonb
    )
    into v
    from public.app_group_members m
    join public.profiles p on p.id = m.user_id
    left join lateral (
      select coalesce(
        sum(
          case
            when b.status = 'won'
              then coalesce(b.potential_payout, 0) - coalesce(b.bet_amount, 0)
            when b.status = 'lost'
              then -coalesce(b.bet_amount, 0)
            else 0
          end
        ),
        0
      )::numeric(12,2) as net_profit
      from public.bets b
      where b.user_id = p.id
        and b.status in ('won', 'lost')
    ) stats on true
    where m.group_id = p_group_id
      and coalesce(p.is_deleted, false) = false;
  end if;

  return v;
end;
$function$;
