-- Repair already-imported Israeli fixtures for provider short-name variants.
-- This changes display names and crests only; fixture IDs, dates, odds, bets and results remain untouched.

UPDATE public.games
SET home_team = CASE lower(trim(coalesce(nullif(sportstats_api_home_name, ''), home_team)))
  WHEN 'sakhnin' THEN 'בני סכנין'
  WHEN 'bnei sakhnin' THEN 'בני סכנין'
  WHEN 'bnei sakhnin fc' THEN 'בני סכנין'
  WHEN 'ironi kiryat shmona fc' THEN 'עירוני קריית שמונה'
  WHEN 'hapoel ironi kiryat shmona fc' THEN 'עירוני קריית שמונה'
  WHEN 'kiryat shmona' THEN 'עירוני קריית שמונה'
  WHEN 'ramat gan' THEN 'הפועל רמת גן'
  WHEN 'hap. ramat gan' THEN 'הפועל רמת גן'
  WHEN 'hap ramat gan' THEN 'הפועל רמת גן'
  WHEN 'ramat gan fc' THEN 'הפועל רמת גן'
  WHEN 'hapoel ramat gan' THEN 'הפועל רמת גן'
  WHEN 'hapoel ramat gan givatayim' THEN 'הפועל רמת גן'
  WHEN 'hapoel ramat gan givatayim fc' THEN 'הפועל רמת גן'
  ELSE home_team
END,
home_flag = CASE lower(trim(coalesce(nullif(sportstats_api_home_name, ''), home_team)))
  WHEN 'sakhnin' THEN 'https://assets.footylogos.com/logos/ihud-bnei-sakhnin/ihud-bnei-sakhnin-logo-footylogos.svg'
  WHEN 'bnei sakhnin' THEN 'https://assets.footylogos.com/logos/ihud-bnei-sakhnin/ihud-bnei-sakhnin-logo-footylogos.svg'
  WHEN 'bnei sakhnin fc' THEN 'https://assets.footylogos.com/logos/ihud-bnei-sakhnin/ihud-bnei-sakhnin-logo-footylogos.svg'
  WHEN 'ironi kiryat shmona fc' THEN 'https://assets.footylogos.com/logos/ironi-kiryat-shmona/ironi-kiryat-shmona-logo-footylogos.svg'
  WHEN 'hapoel ironi kiryat shmona fc' THEN 'https://assets.footylogos.com/logos/ironi-kiryat-shmona/ironi-kiryat-shmona-logo-footylogos.svg'
  WHEN 'kiryat shmona' THEN 'https://assets.footylogos.com/logos/ironi-kiryat-shmona/ironi-kiryat-shmona-logo-footylogos.svg'
  WHEN 'ramat gan' THEN 'https://commons.wikimedia.org/wiki/Special:FilePath/H_Ramat_Gan-Logo.gif'
  WHEN 'hap. ramat gan' THEN 'https://commons.wikimedia.org/wiki/Special:FilePath/H_Ramat_Gan-Logo.gif'
  WHEN 'hap ramat gan' THEN 'https://commons.wikimedia.org/wiki/Special:FilePath/H_Ramat_Gan-Logo.gif'
  WHEN 'ramat gan fc' THEN 'https://commons.wikimedia.org/wiki/Special:FilePath/H_Ramat_Gan-Logo.gif'
  WHEN 'hapoel ramat gan' THEN 'https://commons.wikimedia.org/wiki/Special:FilePath/H_Ramat_Gan-Logo.gif'
  WHEN 'hapoel ramat gan givatayim' THEN 'https://commons.wikimedia.org/wiki/Special:FilePath/H_Ramat_Gan-Logo.gif'
  WHEN 'hapoel ramat gan givatayim fc' THEN 'https://commons.wikimedia.org/wiki/Special:FilePath/H_Ramat_Gan-Logo.gif'
  ELSE home_flag
END
WHERE lower(trim(coalesce(nullif(sportstats_api_home_name, ''), home_team))) IN (
  'sakhnin','bnei sakhnin','bnei sakhnin fc','ironi kiryat shmona fc',
  'hapoel ironi kiryat shmona fc','kiryat shmona','ramat gan','ramat gan fc','hap. ramat gan','hap ramat gan',
  'hapoel ramat gan','hapoel ramat gan givatayim','hapoel ramat gan givatayim fc'
);

UPDATE public.games
SET away_team = CASE lower(trim(coalesce(nullif(sportstats_api_away_name, ''), away_team)))
  WHEN 'sakhnin' THEN 'בני סכנין'
  WHEN 'bnei sakhnin' THEN 'בני סכנין'
  WHEN 'bnei sakhnin fc' THEN 'בני סכנין'
  WHEN 'ironi kiryat shmona fc' THEN 'עירוני קריית שמונה'
  WHEN 'hapoel ironi kiryat shmona fc' THEN 'עירוני קריית שמונה'
  WHEN 'kiryat shmona' THEN 'עירוני קריית שמונה'
  WHEN 'ramat gan' THEN 'הפועל רמת גן'
  WHEN 'ramat gan fc' THEN 'הפועל רמת גן'
  WHEN 'hapoel ramat gan' THEN 'הפועל רמת גן'
  WHEN 'hapoel ramat gan givatayim' THEN 'הפועל רמת גן'
  WHEN 'hapoel ramat gan givatayim fc' THEN 'הפועל רמת גן'
  ELSE away_team
END,
away_flag = CASE lower(trim(coalesce(nullif(sportstats_api_away_name, ''), away_team)))
  WHEN 'sakhnin' THEN 'https://assets.footylogos.com/logos/ihud-bnei-sakhnin/ihud-bnei-sakhnin-logo-footylogos.svg'
  WHEN 'bnei sakhnin' THEN 'https://assets.footylogos.com/logos/ihud-bnei-sakhnin/ihud-bnei-sakhnin-logo-footylogos.svg'
  WHEN 'bnei sakhnin fc' THEN 'https://assets.footylogos.com/logos/ihud-bnei-sakhnin/ihud-bnei-sakhnin-logo-footylogos.svg'
  WHEN 'ironi kiryat shmona fc' THEN 'https://assets.footylogos.com/logos/ironi-kiryat-shmona/ironi-kiryat-shmona-logo-footylogos.svg'
  WHEN 'hapoel ironi kiryat shmona fc' THEN 'https://assets.footylogos.com/logos/ironi-kiryat-shmona/ironi-kiryat-shmona-logo-footylogos.svg'
  WHEN 'kiryat shmona' THEN 'https://assets.footylogos.com/logos/ironi-kiryat-shmona/ironi-kiryat-shmona-logo-footylogos.svg'
  WHEN 'ramat gan' THEN 'https://commons.wikimedia.org/wiki/Special:FilePath/H_Ramat_Gan-Logo.gif'
  WHEN 'ramat gan fc' THEN 'https://commons.wikimedia.org/wiki/Special:FilePath/H_Ramat_Gan-Logo.gif'
  WHEN 'hapoel ramat gan' THEN 'https://commons.wikimedia.org/wiki/Special:FilePath/H_Ramat_Gan-Logo.gif'
  WHEN 'hapoel ramat gan givatayim' THEN 'https://commons.wikimedia.org/wiki/Special:FilePath/H_Ramat_Gan-Logo.gif'
  WHEN 'hapoel ramat gan givatayim fc' THEN 'https://commons.wikimedia.org/wiki/Special:FilePath/H_Ramat_Gan-Logo.gif'
  ELSE away_flag
END
WHERE lower(trim(coalesce(nullif(sportstats_api_away_name, ''), away_team))) IN (
  'sakhnin','bnei sakhnin','bnei sakhnin fc','ironi kiryat shmona fc',
  'hapoel ironi kiryat shmona fc','kiryat shmona','ramat gan','ramat gan fc',
  'hapoel ramat gan','hapoel ramat gan givatayim','hapoel ramat gan givatayim fc'
);
