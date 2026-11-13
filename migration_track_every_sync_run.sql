
create table if not exists public.api_sync_runs (
  run_id uuid primary key default gen_random_uuid(),
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  purpose text not null,
  trigger_source text,
  status text not null default 'running'
    check (status in ('running','success','failed','skipped')),
  summary jsonb not null default '{}'::jsonb,
  error text,
  request_count integer not null default 0
);
create index if not exists api_sync_runs_started_at_idx on public.api_sync_runs (started_at desc);
do $$
begin
  if not exists (select 1 from pg_constraint where conrelid='public.api_request_log'::regclass and conname='api_request_log_run_id_fkey') then
    alter table public.api_request_log add constraint api_request_log_run_id_fkey
      foreign key (run_id) references public.api_sync_runs(run_id) on delete set null;
  end if;
end $$;
alter table public.api_sync_runs enable row level security;
revoke all on public.api_sync_runs from public, anon, authenticated;
grant select, insert, update on public.api_sync_runs to service_role;

create or replace function public.start_api_sync_run(p_purpose text, p_trigger_source text default null)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_id uuid;
begin
  if coalesce(auth.role(),'') <> 'service_role' then raise exception 'service_role required'; end if;
  insert into public.api_sync_runs(purpose,trigger_source,status)
  values(left(coalesce(p_purpose,'sync'),160),left(p_trigger_source,120),'running')
  returning run_id into v_id;
  return v_id;
end $$;
revoke all on function public.start_api_sync_run(text,text) from public, anon, authenticated;
grant execute on function public.start_api_sync_run(text,text) to service_role;

create or replace function public.finish_api_sync_run(
  p_run_id uuid,p_status text,p_summary jsonb default '{}'::jsonb,
  p_error text default null,p_request_count integer default 0
) returns void language plpgsql security definer set search_path=public as $$
begin
  if coalesce(auth.role(),'') <> 'service_role' then raise exception 'service_role required'; end if;
  if p_status not in ('success','failed','skipped') then raise exception 'Invalid run status'; end if;
  update public.api_sync_runs set finished_at=now(),status=p_status,
    summary=coalesce(p_summary,'{}'::jsonb),error=left(p_error,4000),
    request_count=greatest(0,coalesce(p_request_count,0))
  where run_id=p_run_id and status='running';
  if not found then raise exception 'Sync run not found or already finished'; end if;
end $$;
revoke all on function public.finish_api_sync_run(uuid,text,jsonb,text,integer) from public, anon, authenticated;
grant execute on function public.finish_api_sync_run(uuid,text,jsonb,text,integer) to service_role;

create or replace function public.admin_recent_api_sync_runs(p_limit integer default 100)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v jsonb;
begin
  if not public.admin_is_admin() then raise exception 'אין הרשאת מנהל'; end if;
  select coalesce(jsonb_agg(to_jsonb(r) order by r.started_at desc),'[]'::jsonb) into v
  from (
    select run_id,started_at,finished_at,purpose,trigger_source,status,summary,error,request_count
    from public.api_sync_runs order by started_at desc
    limit greatest(1,least(coalesce(p_limit,100),300))
  ) r;
  return v;
end $$;
revoke all on function public.admin_recent_api_sync_runs(integer) from public, anon;
grant execute on function public.admin_recent_api_sync_runs(integer) to authenticated;

create or replace function public.admin_api_run_details(p_run_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v jsonb;
begin
  if not public.admin_is_admin() then raise exception 'אין הרשאת מנהל'; end if;
  select jsonb_build_object(
    'run',to_jsonb(r),
    'requests',coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',q.id,'called_at',q.called_at,'endpoint',q.endpoint,'params',q.params,
        'status_code',q.status_code,'purpose',q.purpose,
        'response_summary',q.response_summary,'duration_ms',q.duration_ms
      ) order by q.called_at asc,q.id asc)
      from public.api_request_log q where q.run_id=r.run_id
    ),'[]'::jsonb)
  ) into v from public.api_sync_runs r where r.run_id=p_run_id;
  if v is null then raise exception 'Sync run not found'; end if;
  return v;
end $$;
revoke all on function public.admin_api_run_details(uuid) from public, anon;
grant execute on function public.admin_api_run_details(uuid) to authenticated;
notify pgrst,'reload schema';
