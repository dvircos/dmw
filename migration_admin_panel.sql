-- Admin panel for Mordechai Winners.
-- Run once in Supabase SQL Editor. Then add your own auth.users UUID to admin_users
-- using the INSERT statement in the README. Never expose a service-role key in the browser.

alter table public.profiles add column if not exists is_deleted boolean not null default false;

create table if not exists public.admin_users (
  user_id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

create table if not exists public.admin_audit_log (
  id bigserial primary key,
  admin_id uuid not null references auth.users(id),
  action text not null,
  target_user_id uuid,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

alter table public.admin_users enable row level security;
alter table public.admin_audit_log enable row level security;
revoke all on public.admin_users, public.admin_audit_log from anon, authenticated, public;

create or replace function public.admin_is_admin()
returns boolean language sql stable security definer set search_path=public as $$
  select auth.uid() is not null and exists(select 1 from public.admin_users where user_id=auth.uid());
$$;
revoke all on function public.admin_is_admin() from public, anon;
grant execute on function public.admin_is_admin() to authenticated;

create or replace function public.admin_list_users()
returns jsonb language plpgsql security definer set search_path=public as $$
declare v jsonb;
begin
  if not public.admin_is_admin() then raise exception 'אין הרשאת מנהל'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',p.id,'username',p.username,'balance',p.balance,'is_deleted',p.is_deleted,
    'created_at',p.created_at,
    'pending_bets',(select count(*) from public.bets b where b.user_id=p.id and b.status='pending')
  ) order by p.created_at desc),'[]'::jsonb) into v
  from public.profiles p;
  return v;
end; $$;

create or replace function public.admin_set_balance(p_user_id uuid,p_balance numeric,p_reason text default 'manual')
returns jsonb language plpgsql security definer set search_path=public as $$
declare old_balance numeric(10,2); new_balance numeric(10,2);
begin
  if not public.admin_is_admin() then raise exception 'אין הרשאת מנהל'; end if;
  if p_balance is null or p_balance < 0 or p_balance > 9999999 then raise exception 'יתרה לא תקינה'; end if;
  select balance into old_balance from public.profiles where id=p_user_id for update;
  if not found then raise exception 'המשתמש לא נמצא'; end if;
  update public.profiles set balance=round(p_balance,2) where id=p_user_id returning balance into new_balance;
  insert into public.admin_audit_log(admin_id,action,target_user_id,details)
  values(auth.uid(),'set_balance',p_user_id,jsonb_build_object('old_balance',old_balance,'new_balance',new_balance,'reason',left(coalesce(p_reason,''),120)));
  return jsonb_build_object('user_id',p_user_id,'old_balance',old_balance,'balance',new_balance);
end; $$;

create or replace function public.admin_soft_delete_user(p_user_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare old_name text;
begin
  if not public.admin_is_admin() then raise exception 'אין הרשאת מנהל'; end if;
  if p_user_id=auth.uid() then raise exception 'אי אפשר למחוק את חשבון המנהל'; end if;
  update public.profiles set is_deleted=true, username='deleted-'||replace(p_user_id::text,'-','')
  where id=p_user_id and is_deleted=false returning username into old_name;
  if not found then raise exception 'המשתמש לא נמצא או כבר נמחק'; end if;
  insert into public.admin_audit_log(admin_id,action,target_user_id,details)
  values(auth.uid(),'soft_delete_user',p_user_id,jsonb_build_object('note','Profile hidden; bet history retained'));
  return jsonb_build_object('user_id',p_user_id,'deleted',true,'history_retained',true);
end; $$;

create or replace function public.admin_user_bets(p_user_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v jsonb;
begin
  if not public.admin_is_admin() then raise exception 'אין הרשאת מנהל'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',b.id,'bet_amount',b.bet_amount,'odds',b.odds,'potential_payout',b.potential_payout,
    'status',b.status,'bet_selection',b.bet_selection,'game_id',b.game_id,
    'legs',b.legs
  ) order by b.id desc),'[]'::jsonb) into v
  from (select * from public.bets where user_id=p_user_id order by id desc limit 100) b;
  return v;
end; $$;

revoke all on function public.admin_list_users() from public,anon;
revoke all on function public.admin_set_balance(uuid,numeric,text) from public,anon;
revoke all on function public.admin_soft_delete_user(uuid) from public,anon;
revoke all on function public.admin_user_bets(uuid) from public,anon;
grant execute on function public.admin_list_users() to authenticated;
grant execute on function public.admin_set_balance(uuid,numeric,text) to authenticated;
grant execute on function public.admin_soft_delete_user(uuid) to authenticated;
grant execute on function public.admin_user_bets(uuid) to authenticated;

-- Prevent further bet creation/edits by profiles that were soft-deleted.
create or replace function public.reject_bets_from_deleted_profiles()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if tg_op = 'UPDATE'
     and old.bet_amount is not distinct from new.bet_amount
     and old.game_id is not distinct from new.game_id
     and old.bet_selection is not distinct from new.bet_selection
     and old.legs is not distinct from new.legs then
    return new; -- allow settlement/status changes on existing open bets
  end if;
  if exists(select 1 from public.profiles where id=new.user_id and is_deleted=true) then
    raise exception 'החשבון אינו פעיל';
  end if;
  return new;
end; $$;
drop trigger if exists bets_reject_deleted_profile on public.bets;
create trigger bets_reject_deleted_profile before insert or update on public.bets
for each row execute function public.reject_bets_from_deleted_profiles();

create or replace function public.admin_recent_audit()
returns jsonb language plpgsql security definer set search_path=public as $$
declare v jsonb;
begin
  if not public.admin_is_admin() then raise exception 'אין הרשאת מנהל'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('id',a.id,'action',a.action,'target_user_id',a.target_user_id,'details',a.details,'created_at',a.created_at) order by a.id desc),'[]'::jsonb)
    into v from (select * from public.admin_audit_log order by id desc limit 50) a;
  return v;
end; $$;
revoke all on function public.admin_recent_audit() from public,anon;
grant execute on function public.admin_recent_audit() to authenticated;

notify pgrst, 'reload schema';
