update public.games
set home_flag = 'https://assets.laliga.com/assets/2019/06/07/xsmall/malaga.png'
where sportstats_api_home_name in ('Malaga','Málaga','Malaga CF','Málaga CF')
   or home_team = 'מלאגה';
update public.games
set away_flag = 'https://assets.laliga.com/assets/2019/06/07/xsmall/malaga.png'
where sportstats_api_away_name in ('Malaga','Málaga','Malaga CF','Málaga CF')
   or away_team = 'מלאגה';