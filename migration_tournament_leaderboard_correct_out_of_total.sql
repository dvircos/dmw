-- Show tournament leaderboard as correct predictions out of all tournament games.
-- Keep prize settlement logic unchanged; this only changes leaderboard display data.
create or replace function public.tournament_leaderboard(p_tournament_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v jsonb;
begin
  if auth.uid() is null then raise exception 'יש להתחבר'; end if;
  if not exists(select 1 from public.tournaments where id=p_tournament_id and status in ('locked','completed')) and not public.admin_is_admin() then
    raise exception 'הדירוג ייפתח לאחר סגירת ההרשמה';
  end if;

  with scores as (
    select
      p.user_id,
      pr.username,
      count(*) filter (
        where g.status='finished'
          and tp.selection=case
            when g.home_score>g.away_score then '1'
            when g.home_score=g.away_score then 'X'
            else '2'
          end
      )::integer as correct_predictions,
      (select count(*)::integer
       from public.tournament_games tg
       join public.games finished_game on finished_game.id=tg.game_id
       where tg.tournament_id=p_tournament_id
         and finished_game.status='finished') as total_games
    from public.tournament_participants p
    join public.profiles pr on pr.id=p.user_id
    left join public.tournament_predictions tp
      on tp.tournament_id=p.tournament_id and tp.user_id=p.user_id
    left join public.games g on g.id=tp.game_id
    where p.tournament_id=p_tournament_id
    group by p.user_id,pr.username
  )
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'user_id',user_id,
        'username',username,
        'correct_predictions',correct_predictions,
        'total_games',total_games
      )
      order by correct_predictions desc,username asc
    ),
    '[]'::jsonb
  )
  into v
  from scores;

  return v;
end; $$;

revoke all on function public.tournament_leaderboard(uuid) from public,anon;
grant execute on function public.tournament_leaderboard(uuid) to authenticated;
notify pgrst, 'reload schema';
