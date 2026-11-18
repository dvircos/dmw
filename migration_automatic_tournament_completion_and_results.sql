-- Automatic tournament completion, prize payout, and one-time winner podium notifications.
begin;
create table if not exists public.tournament_result_notifications (
  user_id uuid not null references auth.users(id) on delete cascade,
  tournament_id uuid not null references public.tournaments(id) on delete cascade,
  seen_at timestamptz not null default now(),
  primary key (user_id, tournament_id)
);
alter table public.tournament_result_notifications enable row level security;
revoke all on public.tournament_result_notifications from public, anon, authenticated;

CREATE OR REPLACE FUNCTION public._finalize_tournament_core(p_tournament_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_t public.tournaments%rowtype;
  v_pending integer;
  v_top integer;
  v_winners integer;
  v_share numeric(12,2);
  v_remainder_cents integer:=0;
begin
  select * into v_t from public.tournaments where id=p_tournament_id for update;
  if not found then raise exception 'הטורניר לא נמצא'; end if;
  if v_t.status='completed' then return jsonb_build_object('completed',true,'already_completed',true); end if;
  if v_t.status not in ('open','locked') then return jsonb_build_object('completed',false,'skipped',true); end if;

  select count(*) into v_pending
  from public.tournament_games tg join public.games g on g.id=tg.game_id
  where tg.tournament_id=p_tournament_id and g.status not in ('finished','cancelled');
  if v_pending>0 then return jsonb_build_object('completed',false,'pending_games',v_pending); end if;

  with scores as (
    select p.user_id,pr.username,
      coalesce(sum(case when g.status='finished' and tp.selection=case when g.home_score>g.away_score then '1' when g.home_score=g.away_score then 'X' else '2' end then 3 else 0 end),0)::integer points
    from public.tournament_participants p
    join public.profiles pr on pr.id=p.user_id
    left join public.tournament_predictions tp on tp.tournament_id=p.tournament_id and tp.user_id=p.user_id
    left join public.games g on g.id=tp.game_id
    where p.tournament_id=p_tournament_id
    group by p.user_id,pr.username
  )
  select max(points),count(*) filter(where points=(select max(points) from scores))
  into v_top,v_winners from scores;

  if coalesce(v_top,0)<=0 then v_winners:=0; end if;
  if v_t.prize_pool>0 and coalesce(v_winners,0)>0 then
    v_share:=trunc(v_t.prize_pool/v_winners,2);
    v_remainder_cents:=greatest(0,round((v_t.prize_pool-v_share*v_winners)*100)::integer);
    with scores as (
      select p.user_id,pr.username,
        coalesce(sum(case when g.status='finished' and tp.selection=case when g.home_score>g.away_score then '1' when g.home_score=g.away_score then 'X' else '2' end then 3 else 0 end),0)::integer points
      from public.tournament_participants p
      join public.profiles pr on pr.id=p.user_id
      left join public.tournament_predictions tp on tp.tournament_id=p.tournament_id and tp.user_id=p.user_id
      left join public.games g on g.id=tp.game_id
      where p.tournament_id=p_tournament_id group by p.user_id,pr.username
    ), winners as (
      select user_id,row_number() over(order by username,user_id) as rn from scores where points=v_top
    )
    update public.profiles pr
    set balance=pr.balance+v_share+case when w.rn<=v_remainder_cents then 0.01 else 0 end
    from winners w where pr.id=w.user_id;

    with scores as (
      select p.user_id,pr.username,
        coalesce(sum(case when g.status='finished' and tp.selection=case when g.home_score>g.away_score then '1' when g.home_score=g.away_score then 'X' else '2' end then 3 else 0 end),0)::integer points
      from public.tournament_participants p
      join public.profiles pr on pr.id=p.user_id
      left join public.tournament_predictions tp on tp.tournament_id=p.tournament_id and tp.user_id=p.user_id
      left join public.games g on g.id=tp.game_id
      where p.tournament_id=p_tournament_id group by p.user_id,pr.username
    ), winners as (
      select user_id,row_number() over(order by username,user_id) as rn from scores where points=v_top
    )
    update public.tournament_participants p
    set prize_paid=v_share+case when w.rn<=v_remainder_cents then 0.01 else 0 end
    from winners w where p.tournament_id=p_tournament_id and p.user_id=w.user_id;
  end if;

  update public.tournaments set status='completed',completed_at=now() where id=p_tournament_id;
  return jsonb_build_object('completed',true,'winners',coalesce(v_winners,0),'prize_each_base',coalesce(v_share,0),'top_points',v_top,'remainder_cents',v_remainder_cents);
end; $function$

CREATE OR REPLACE FUNCTION public.admin_tournament_finalize(p_tournament_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_t public.tournaments%rowtype; v_result jsonb;
begin
  if not public.admin_is_admin() then raise exception 'אין הרשאת מנהל'; end if;
  select * into v_t from public.tournaments where id=p_tournament_id;
  if not found then raise exception 'הטורניר לא נמצא'; end if;
  v_result:=public._finalize_tournament_core(p_tournament_id);
  if coalesce((v_result->>'completed')::boolean,false) and not coalesce((v_result->>'already_completed')::boolean,false) then
    insert into public.admin_audit_log(admin_id,action,details)
    values(auth.uid(),'tournament_finalized',jsonb_build_object('tournament_id',p_tournament_id,'prize_pool',v_t.prize_pool,'winners',v_result->'winners','prize_each_base',v_result->'prize_each_base'));
  end if;
  return v_result;
end; $function$

CREATE OR REPLACE FUNCTION public.auto_finalize_completed_tournaments()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_id uuid; v_count integer:=0; v_result jsonb;
begin
  for v_id in
    select t.id from public.tournaments t
    where t.status in ('open','locked')
      and exists(select 1 from public.tournament_games tg where tg.tournament_id=t.id)
      and not exists(
        select 1 from public.tournament_games tg join public.games g on g.id=tg.game_id
        where tg.tournament_id=t.id and g.status not in ('finished','cancelled')
      )
    order by t.created_at
  loop
    v_result:=public._finalize_tournament_core(v_id);
    if coalesce((v_result->>'completed')::boolean,false) and not coalesce((v_result->>'already_completed')::boolean,false) then
      v_count:=v_count+1;
    end if;
  end loop;
  return v_count;
end; $function$

CREATE OR REPLACE FUNCTION public.tournament_unseen_results()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v jsonb;
begin
  if auth.uid() is null then raise exception 'יש להתחבר'; end if;
  perform public.auto_finalize_completed_tournaments();
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',t.id,'name',t.name,'prize_pool',t.prize_pool,'completed_at',t.completed_at,
    'leaderboard',coalesce((
      select jsonb_agg(jsonb_build_object(
        'user_id',p.user_id,'username',pr.username,
        'correct_predictions',(
          select count(*)::integer from public.tournament_predictions tp
          join public.games g on g.id=tp.game_id
          where tp.tournament_id=t.id and tp.user_id=p.user_id and g.status='finished'
            and tp.selection=case when g.home_score>g.away_score then '1' when g.home_score=g.away_score then 'X' else '2' end
        ),
        'total_games',(select count(*)::integer from public.tournament_games tg join public.games g on g.id=tg.game_id where tg.tournament_id=t.id and g.status='finished'),
        'prize_paid',p.prize_paid
      ) order by (
        select count(*) from public.tournament_predictions tp
        join public.games g on g.id=tp.game_id
        where tp.tournament_id=t.id and tp.user_id=p.user_id and g.status='finished'
          and tp.selection=case when g.home_score>g.away_score then '1' when g.home_score=g.away_score then 'X' else '2' end
      ) desc,pr.username asc)
      from public.tournament_participants p join public.profiles pr on pr.id=p.user_id
      where p.tournament_id=t.id
    ),'[]'::jsonb)
  ) order by t.completed_at desc),'[]'::jsonb)
  into v
  from public.tournaments t
  join public.tournament_participants mine on mine.tournament_id=t.id and mine.user_id=auth.uid()
  left join public.tournament_result_notifications n on n.tournament_id=t.id and n.user_id=auth.uid()
  where t.status='completed' and n.tournament_id is null;
  return v;
end; $function$

CREATE OR REPLACE FUNCTION public.tournament_mark_result_seen(p_tournament_id uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if auth.uid() is null then raise exception 'יש להתחבר'; end if;
  if not exists(select 1 from public.tournaments t join public.tournament_participants p on p.tournament_id=t.id
    where t.id=p_tournament_id and t.status='completed' and p.user_id=auth.uid()) then
    raise exception 'לא נמצאה תוצאת טורניר למשתמש';
  end if;
  insert into public.tournament_result_notifications(user_id,tournament_id)
  values(auth.uid(),p_tournament_id) on conflict(user_id,tournament_id) do nothing;
  return true;
end; $function$


revoke all on function public._finalize_tournament_core(uuid) from public,anon,authenticated;
revoke all on function public.auto_finalize_completed_tournaments() from public,anon,authenticated;
revoke all on function public.tournament_unseen_results() from public,anon;
revoke all on function public.tournament_mark_result_seen(uuid) from public,anon;
grant execute on function public.tournament_unseen_results() to authenticated;
grant execute on function public.tournament_mark_result_seen(uuid) to authenticated;
revoke all on function public.admin_tournament_finalize(uuid) from public,anon;
grant execute on function public.admin_tournament_finalize(uuid) to authenticated;

do $$
declare v_job bigint;
begin
  for v_job in select jobid from cron.job where jobname='dmw-auto-finalize-tournaments' loop
    perform cron.unschedule(v_job);
  end loop;
  perform cron.schedule('dmw-auto-finalize-tournaments','* * * * *',
    $cmd$select public.auto_finalize_completed_tournaments();$cmd$);
end; $$;
notify pgrst,'reload schema';
commit;