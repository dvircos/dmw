create or replace function public.admin_tournament_finalize(p_tournament_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  v_t public.tournaments%rowtype;
  v_pending integer;
  v_top integer;
  v_winners integer;
  v_share numeric(12,2);
  v_remainder_cents integer:=0;
begin
  if not public.admin_is_admin() then raise exception 'אין הרשאת מנהל'; end if;
  select * into v_t from public.tournaments where id=p_tournament_id for update;
  if not found then raise exception 'הטורניר לא נמצא'; end if;
  if v_t.status='completed' then raise exception 'הפרסים כבר חולקו'; end if;
  if v_t.status not in ('open','locked') then raise exception 'הטורניר אינו ניתן לסגירה'; end if;
  select count(*) into v_pending
  from public.tournament_games tg join public.games g on g.id=tg.game_id
  where tg.tournament_id=p_tournament_id and g.status not in ('finished','cancelled');
  if v_pending>0 then raise exception 'יש עדיין משחקים שלא הסתיימו'; end if;

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
  insert into public.admin_audit_log(admin_id,action,details)
  values(auth.uid(),'tournament_finalized',jsonb_build_object('tournament_id',p_tournament_id,'prize_pool',v_t.prize_pool,'winners',coalesce(v_winners,0),'prize_each_base',coalesce(v_share,0)));
  return jsonb_build_object('completed',true,'winners',coalesce(v_winners,0),'prize_each_base',coalesce(v_share,0),'top_points',v_top,'remainder_cents',v_remainder_cents);
end; $$;
revoke all on function public.admin_tournament_finalize(uuid) from public,anon;
grant execute on function public.admin_tournament_finalize(uuid) to authenticated;
notify pgrst, 'reload schema';