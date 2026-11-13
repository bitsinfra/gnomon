-- Integrations inside the database: PostgREST / Supabase, poolers.

-- PostgREST: set db-pre-request = 'gnomon.postgrest_pre_request'. A request picks a branch with
-- the X-Gnomon-Branch header (and optionally X-Gnomon-As-Of). PostgREST qualifies table names
-- with the request's schema profile, so in SQL-only mode expose the routing schemas as profiles
-- (db-schemas = 'public, gnomon_r_public') and send Accept-Profile / Content-Profile:
-- gnomon_r_public; with the C module the header alone routes.
create function gnomon.postgrest_pre_request() returns void language plpgsql volatile as $$
declare h json; b text; a text;
begin
  begin
    h := nullif(current_setting('request.headers', true), '')::json;
  exception when others then
    return;
  end;
  b := nullif(h ->> 'x-gnomon-branch', '');
  a := nullif(h ->> 'x-gnomon-as-of', '');
  if b is null and a is null then return; end if;
  perform gnomon.begin(coalesce(b, 'main'), a);
end $$;
grant execute on function gnomon.postgrest_pre_request() to public;

create function gnomon.postgrest_config(c_module bool default false) returns text language sql stable as $$
  select concat_ws(E'\n',
    '# PostgREST configuration for gnomon branches',
    'db-pre-request = "gnomon.postgrest_pre_request"',
    case when c_module then 'db-schemas = "' || coalesce((select string_agg(distinct nsp, ', ') from gnomon.tracked), 'public') || '"'
         else 'db-schemas = "' || coalesce((select string_agg(distinct nsp || ', gnomon_r_' || nsp, ', ') from gnomon.tracked), 'public, gnomon_r_public') || '"' end,
    case when c_module then '# clients send: X-Gnomon-Branch: <branch>'
         else '# clients send: X-Gnomon-Branch: <branch> and Accept-Profile/Content-Profile: gnomon_r_<schema>' end)
$$;
