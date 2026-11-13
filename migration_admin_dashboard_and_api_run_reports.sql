alter table public.api_request_log
  add column if not exists response_summary jsonb,
  add column if not exists duration_ms integer,
  add column if not exists run_id uuid;

create index if not exists api_request_log_called_at_idx
  on public.api_request_log (called_at desc);

drop function if exists public.log_api_request(text, jsonb, integer, text);
create function public.log_api_request(
  p_endpoint text,
  p_params jsonb,
  p_status integer,
  p_purpose text,
  p_response jsonb default null,
  p_duration_ms integer default null,
  p_run_id uuid default null
)
returns void
language sql
security definer
set search_path = public
as $$
  insert into public.api_request_log
    (endpoint, params, status_code, purpose, response_summary, duration_ms, run_id)
  values
    (left(coalesce(p_endpoint, ''), 500),
     coalesce(p_params, '{}'::jsonb),
     p_status,
     left(coalesce(p_purpose, ''), 160),
     p_response,
     case when p_duration_ms is null then null else greatest(0, p_duration_ms) end,
     p_run_id);
$$;
revoke all on function public.log_api_request(text,jsonb,integer,text,jsonb,integer,uuid) from public, anon, authenticated;
grant execute on function public.log_api_request(text,jsonb,integer,text,jsonb,integer,uuid) to service_role;

create or replace function public.admin_recent_api_requests(p_limit integer default 100)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v jsonb;
begin
  if not public.admin_is_admin() then raise exception 'אין הרשאת מנהל'; end if;
  select coalesce(jsonb_agg(to_jsonb(r) order by r.called_at desc), '[]'::jsonb)
    into v
  from (
    select id, called_at, endpoint, params, status_code, purpose,
           response_summary, duration_ms, run_id
    from public.api_request_log
    order by called_at desc
    limit greatest(1, least(coalesce(p_limit, 100), 300))
  ) r;
  return v;
end;
$$;
revoke all on function public.admin_recent_api_requests(integer) from public, anon;
grant execute on function public.admin_recent_api_requests(integer) to authenticated;

notify pgrst, 'reload schema';
