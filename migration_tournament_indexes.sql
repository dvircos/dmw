-- Keep tournament score and creator lookups indexed.
create index if not exists tournaments_created_by_idx on public.tournaments(created_by);
create index if not exists tournament_predictions_tournament_user_idx on public.tournament_predictions(tournament_id,user_id);
notify pgrst, 'reload schema';