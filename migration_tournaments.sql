-- Tournament management and prediction contests.
create table if not exists public.tournaments (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(btrim(name)) between 3 and 60),
  status text not null default 'draft' check (status in ('draft','open','locked','completed','cancelled')),
  entry_fee numeric(10,2) not null default 0 check (entry_fee >= 0 and entry_fee <= 100000),
  prize_pool numeric(12,2) not null default 0 check (prize_pool >= 0),
  registration_closes_at timestamptz,
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  completed_at timestamptz
);
create table if not exists public.tournament_games (
  tournament_id uuid not null references public.tournaments(id) on delete cascade,
  game_id bigint not null references public.games(id) on delete restrict,
  sort_order integer not null default 0,
  primary key (tournament_id, game_id),
  unique (tournament_id, sort_order)
);
create table if not exists public.tournament_participants (
  tournament_id uuid not null references public.tournaments(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete restrict,
  entry_fee_paid numeric(10,2) not null default 0,
  joined_at timestamptz not null default now(),
  prize_paid numeric(12,2) not null default 0,
  primary key (tournament_id, user_id)
);
create table if not exists public.tournament_predictions (
  tournament_id uuid not null,
  game_id bigint not null,
  user_id uuid not null,
  selection text not null check (selection in ('1','X','2')),
  points integer not null default 0,
  updated_at timestamptz not null default now(),
  primary key (tournament_id, game_id, user_id),
  foreign key (tournament_id, game_id) references public.tournament_games(tournament_id, game_id) on delete cascade,
  foreign key (tournament_id, user_id) references public.tournament_participants(tournament_id, user_id) on delete cascade
);
create index if not exists tournament_games_game_idx on public.tournament_games(game_id);
create index if not exists tournament_participants_user_idx on public.tournament_participants(user_id);
alter table public.tournaments enable row level security;
alter table public.tournament_games enable row level security;
alter table public.tournament_participants enable row level security;
alter table public.tournament_predictions enable row level security;
revoke all on public.tournaments, public.tournament_games, public.tournament_participants, public.tournament_predictions from anon, authenticated, public;

create or replace function public.admin_tournament_list()
returns jsonb language plpgsql security definer set search_path=public as $$
declare v jsonb;
begin
  if not public.admin_is_admin() then raise exception 'אין הרשאת מנהל'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',t.id,'name',t.name,'status',t.status,'entry_fee',t.entry_fee,'prize_pool',t.prize_pool,
    'registration_closes_at',t.registration_closes_at,'created_at',t.created_at,
    'participant_count',(select count(*) from public.tournament_participants p where p.tournament_id=t.id),
    'game_count',(select count(*) from public.tournament_games g where g.tournament_id=t.id),
    'finished_count',(select count(*) from public.tournament_games tg join public.games g on g.id=tg.game_id where tg.tournament_id=t.id and g.status in ('finished','cancelled'))
  ) order by t.created_at desc),'[]'::jsonb) into v from public.tournaments t;
  return v;
end; $$;

create or replace function public.admin_tournament_create(
  p_name text, p_entry_fee numeric, p_registration_closes_at timestamptz, p_game_ids bigint[]
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_id uuid; v_count integer; v_earliest timestamptz;
begin
  if not public.admin_is_admin() then raise exception 'אין הרשאת מנהל'; end if;
  if p_name is null or char_length(btrim(p_name)) not between 3 and 60 then raise exception 'שם הטורניר חייב להכיל 3–60 תווים'; end if;
  if p_entry_fee is null or p_entry_fee < 0 or p_entry_fee > 100000 then raise exception 'דמי כניסה לא תקינים'; end if;
  if coalesce(array_length(p_game_ids,1),0) < 1 or array_length(p_game_ids,1) > 50 then raise exception 'יש לבחור בין משחק אחד ל-50 משחקים'; end if;
  if (select count(distinct x) from unnest(p_game_ids) x) <> array_length(p_game_ids,1) then raise exception 'נבחר משחק יותר מפעם אחת'; end if;
  select count(*), min(match_time) into v_count,v_earliest
  from public.games where id = any(p_game_ids) and status='upcoming' and match_time > now();
  if v_count <> array_length(p_game_ids,1) then raise exception 'אחד המשחקים כבר התחיל או אינו זמין'; end if;
  if p_registration_closes_at is not null and (p_registration_closes_at <= now() or p_registration_closes_at >= v_earliest) then
    raise exception 'מועד סגירת ההרשמה חייב להיות בעתיד ולפני המשחק הראשון';
  end if;
  insert into public.tournaments(name,entry_fee,registration_closes_at,created_by)
  values(btrim(p_name),round(p_entry_fee,2),coalesce(p_registration_closes_at,v_earliest),auth.uid())
  returning id into v_id;
  insert into public.tournament_games(tournament_id,game_id,sort_order)
  select v_id,x,ord::integer from unnest(p_game_ids) with ordinality as q(x,ord);
  insert into public.admin_audit_log(admin_id,action,details)
  values(auth.uid(),'tournament_created',jsonb_build_object('tournament_id',v_id,'name',btrim(p_name),'games',v_count,'entry_fee',p_entry_fee));
  return jsonb_build_object('id',v_id,'status','draft','game_count',v_count);
end; $$;

create or replace function public.admin_tournament_set_status(p_tournament_id uuid,p_status text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_t public.tournaments%rowtype; v_count integer;
begin
  if not public.admin_is_admin() then raise exception 'אין הרשאת מנהל'; end if;
  if p_status not in ('open','locked','cancelled') then raise exception 'סטטוס לא תקין'; end if;
  select * into v_t from public.tournaments where id=p_tournament_id for update;
  if not found then raise exception 'הטורניר לא נמצא'; end if;
  if v_t.status in ('completed','cancelled') then raise exception 'אי אפשר לשנות טורניר שהסתיים'; end if;
  select count(*) into v_count from public.tournament_games where tournament_id=p_tournament_id;
  if p_status='open' and (v_count=0 or v_t.registration_closes_at <= now()) then raise exception 'אי אפשר לפרסם: אין משחקים או שמועד ההרשמה חלף'; end if;
  update public.tournaments set status=p_status where id=p_tournament_id;
  insert into public.admin_audit_log(admin_id,action,details)
  values(auth.uid(),'tournament_status_changed',jsonb_build_object('tournament_id',p_tournament_id,'status',p_status));
  return jsonb_build_object('id',p_tournament_id,'status',p_status);
end; $$;

create or replace function public.tournament_list()
returns jsonb language plpgsql security definer set search_path=public as $$
declare v jsonb;
begin
  if auth.uid() is null then raise exception 'יש להתחבר'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',t.id,'name',t.name,'status',t.status,'entry_fee',t.entry_fee,'prize_pool',t.prize_pool,
    'registration_closes_at',t.registration_closes_at,
    'participant_count',(select count(*) from public.tournament_participants p where p.tournament_id=t.id),
    'game_count',(select count(*) from public.tournament_games g where g.tournament_id=t.id),
    'joined',exists(select 1 from public.tournament_participants p where p.tournament_id=t.id and p.user_id=auth.uid())
  ) order by case t.status when 'open' then 0 when 'locked' then 1 else 2 end,t.created_at desc),'[]'::jsonb)
  into v from public.tournaments t where t.status in ('open','locked','completed') or exists(select 1 from public.tournament_participants p where p.tournament_id=t.id and p.user_id=auth.uid());
  return v;
end; $$;

create or replace function public.tournament_join(p_tournament_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_t public.tournaments%rowtype; v_balance numeric;
begin
  if auth.uid() is null then raise exception 'יש להתחבר'; end if;
  select * into v_t from public.tournaments where id=p_tournament_id for update;
  if not found or v_t.status<>'open' then raise exception 'ההרשמה לטורניר אינה פתוחה'; end if;
  if v_t.registration_closes_at is not null and v_t.registration_closes_at<=now() then raise exception 'ההרשמה נסגרה'; end if;
  if exists(select 1 from public.tournament_participants where tournament_id=p_tournament_id and user_id=auth.uid()) then raise exception 'כבר נרשמת לטורניר'; end if;
  select balance into v_balance from public.profiles where id=auth.uid() and is_deleted=false for update;
  if not found then raise exception 'החשבון אינו פעיל'; end if;
  if v_balance < v_t.entry_fee then raise exception 'אין מספיק יתרה להצטרפות'; end if;
  update public.profiles set balance=balance-v_t.entry_fee where id=auth.uid();
  insert into public.tournament_participants(tournament_id,user_id,entry_fee_paid) values(p_tournament_id,auth.uid(),v_t.entry_fee);
  update public.tournaments set prize_pool=prize_pool+v_t.entry_fee where id=p_tournament_id;
  select balance into v_balance from public.profiles where id=auth.uid();
  return jsonb_build_object('joined',true,'balance',v_balance,'entry_fee',v_t.entry_fee);
end; $$;

create or replace function public.tournament_save_predictions(p_tournament_id uuid,p_predictions jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_item jsonb; v_game_id bigint; v_selection text; v_saved integer:=0;
begin
  if auth.uid() is null then raise exception 'יש להתחבר'; end if;
  if jsonb_typeof(p_predictions)<>'array' then raise exception 'מבנה ניחושים לא תקין'; end if;
  if not exists(select 1 from public.tournament_participants where tournament_id=p_tournament_id and user_id=auth.uid()) then raise exception 'צריך להצטרף לטורניר קודם'; end if;
  if not exists(select 1 from public.tournaments where id=p_tournament_id and status='open' and (registration_closes_at is null or registration_closes_at>now())) then raise exception 'הטורניר אינו פתוח לניחושים'; end if;
  for v_item in select value from jsonb_array_elements(p_predictions) loop
    v_game_id := (v_item->>'game_id')::bigint;
    v_selection := v_item->>'selection';
    if v_selection not in ('1','X','2') then raise exception 'ניחוש לא תקין'; end if;
    if not exists(select 1 from public.tournament_games tg join public.games g on g.id=tg.game_id where tg.tournament_id=p_tournament_id and tg.game_id=v_game_id and g.status='upcoming' and g.match_time>now()) then raise exception 'אי אפשר לנחש משחק שכבר התחיל'; end if;
    insert into public.tournament_predictions(tournament_id,game_id,user_id,selection)
    values(p_tournament_id,v_game_id,auth.uid(),v_selection)
    on conflict(tournament_id,game_id,user_id) do update set selection=excluded.selection,updated_at=now();
    v_saved:=v_saved+1;
  end loop;
  return jsonb_build_object('saved',v_saved);
end; $$;

create or replace function public.tournament_detail(p_tournament_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v jsonb; v_joined boolean;
begin
  if auth.uid() is null then raise exception 'יש להתחבר'; end if;
  select exists(select 1 from public.tournament_participants where tournament_id=p_tournament_id and user_id=auth.uid()) into v_joined;
  select jsonb_build_object(
    'id',t.id,'name',t.name,'status',t.status,'entry_fee',t.entry_fee,'prize_pool',t.prize_pool,
    'registration_closes_at',t.registration_closes_at,'joined',v_joined,
    'participants',(select count(*) from public.tournament_participants p where p.tournament_id=t.id),
    'games',coalesce((select jsonb_agg(jsonb_build_object(
      'id',g.id,'home_team',g.home_team,'away_team',g.away_team,'home_flag',g.home_flag,'away_flag',g.away_flag,
      'match_time',g.match_time,'status',g.status,'home_score',g.home_score,'away_score',g.away_score,
      'prediction',(select tp.selection from public.tournament_predictions tp where tp.tournament_id=t.id and tp.game_id=g.id and tp.user_id=auth.uid())
    ) order by tg.sort_order) from public.tournament_games tg join public.games g on g.id=tg.game_id where tg.tournament_id=t.id),'[]'::jsonb)
  ) into v from public.tournaments t where t.id=p_tournament_id and (t.status<>'draft' or public.admin_is_admin() or v_joined);
  if v is null then raise exception 'הטורניר לא נמצא'; end if;
  return v;
end; $$;

create or replace function public.tournament_leaderboard(p_tournament_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v jsonb;
begin
  if auth.uid() is null then raise exception 'יש להתחבר'; end if;
  if not exists(select 1 from public.tournaments where id=p_tournament_id and status in ('locked','completed')) and not public.admin_is_admin() then
    raise exception 'הדירוג ייפתח לאחר סגירת ההרשמה';
  end if;
  with scores as (
    select p.user_id,pr.username,
      coalesce(sum(case when g.status='finished' and tp.selection=case when g.home_score>g.away_score then '1' when g.home_score=g.away_score then 'X' else '2' end then 3 else 0 end),0)::integer as points,
      count(tp.game_id)::integer as predictions
    from public.tournament_participants p
    join public.profiles pr on pr.id=p.user_id
    left join public.tournament_predictions tp on tp.tournament_id=p.tournament_id and tp.user_id=p.user_id
    left join public.games g on g.id=tp.game_id
    where p.tournament_id=p_tournament_id
    group by p.user_id,pr.username
  )
  select coalesce(jsonb_agg(jsonb_build_object('user_id',user_id,'username',username,'points',points,'predictions',predictions)
    order by points desc,username asc),'[]'::jsonb) into v from scores;
  return v;
end; $$;

create or replace function public.admin_tournament_finalize(p_tournament_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_t public.tournaments%rowtype; v_pending integer; v_top integer; v_winners integer; v_share numeric;
begin
  if not public.admin_is_admin() then raise exception 'אין הרשאת מנהל'; end if;
  select * into v_t from public.tournaments where id=p_tournament_id for update;
  if not found then raise exception 'הטורניר לא נמצא'; end if;
  if v_t.status='completed' then raise exception 'הפרסים כבר חולקו'; end if;
  if v_t.status not in ('open','locked') then raise exception 'הטורניר אינו ניתן לסגירה'; end if;
  select count(*) into v_pending from public.tournament_games tg join public.games g on g.id=tg.game_id where tg.tournament_id=p_tournament_id and g.status not in ('finished','cancelled');
  if v_pending>0 then raise exception 'יש עדיין משחקים שלא הסתיימו'; end if;
  with scores as (
    select p.user_id,coalesce(sum(case when g.status='finished' and tp.selection=case when g.home_score>g.away_score then '1' when g.home_score=g.away_score then 'X' else '2' end then 3 else 0 end),0)::integer points
    from public.tournament_participants p
    left join public.tournament_predictions tp on tp.tournament_id=p.tournament_id and tp.user_id=p.user_id
    left join public.games g on g.id=tp.game_id
    where p.tournament_id=p_tournament_id group by p.user_id
  ) select max(points),count(*) filter(where points=(select max(points) from scores)) into v_top,v_winners from scores;
  if v_t.prize_pool>0 and coalesce(v_winners,0)>0 then
    v_share:=round(v_t.prize_pool/v_winners,2);
    with scores as (
      select p.user_id,coalesce(sum(case when g.status='finished' and tp.selection=case when g.home_score>g.away_score then '1' when g.home_score=g.away_score then 'X' else '2' end then 3 else 0 end),0)::integer points
      from public.tournament_participants p
      left join public.tournament_predictions tp on tp.tournament_id=p.tournament_id and tp.user_id=p.user_id
      left join public.games g on g.id=tp.game_id
      where p.tournament_id=p_tournament_id group by p.user_id
    )
    update public.profiles pr set balance=pr.balance+v_share
    from scores s where pr.id=s.user_id and s.points=v_top;
    update public.tournament_participants set prize_paid=v_share where tournament_id=p_tournament_id and user_id in (
      select p.user_id from public.tournament_participants p
      left join public.tournament_predictions tp on tp.tournament_id=p.tournament_id and tp.user_id=p.user_id
      left join public.games g on g.id=tp.game_id
      where p.tournament_id=p_tournament_id group by p.user_id
      having coalesce(sum(case when g.status='finished' and tp.selection=case when g.home_score>g.away_score then '1' when g.home_score=g.away_score then 'X' else '2' end then 3 else 0 end),0)=v_top
    );
  end if;
  update public.tournaments set status='completed',completed_at=now() where id=p_tournament_id;
  insert into public.admin_audit_log(admin_id,action,details)
  values(auth.uid(),'tournament_finalized',jsonb_build_object('tournament_id',p_tournament_id,'prize_pool',v_t.prize_pool,'winners',coalesce(v_winners,0),'prize_each',coalesce(v_share,0)));
  return jsonb_build_object('completed',true,'winners',coalesce(v_winners,0),'prize_each',coalesce(v_share,0),'top_points',v_top);
end; $$;

revoke all on function public.admin_tournament_list() from public,anon;
revoke all on function public.admin_tournament_create(text,numeric,timestamptz,bigint[]) from public,anon;
revoke all on function public.admin_tournament_set_status(uuid,text) from public,anon;
revoke all on function public.tournament_list() from public,anon;
revoke all on function public.tournament_join(uuid) from public,anon;
revoke all on function public.tournament_save_predictions(uuid,jsonb) from public,anon;
revoke all on function public.tournament_detail(uuid) from public,anon;
revoke all on function public.tournament_leaderboard(uuid) from public,anon;
revoke all on function public.admin_tournament_finalize(uuid) from public,anon;
grant execute on function public.admin_tournament_list() to authenticated;
grant execute on function public.admin_tournament_create(text,numeric,timestamptz,bigint[]) to authenticated;
grant execute on function public.admin_tournament_set_status(uuid,text) to authenticated;
grant execute on function public.tournament_list() to authenticated;
grant execute on function public.tournament_join(uuid) to authenticated;
grant execute on function public.tournament_save_predictions(uuid,jsonb) to authenticated;
grant execute on function public.tournament_detail(uuid) to authenticated;
grant execute on function public.tournament_leaderboard(uuid) to authenticated;
grant execute on function public.admin_tournament_finalize(uuid) to authenticated;
notify pgrst, 'reload schema';
