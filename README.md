
## UI update v2.5
- Added persistent light/dark theme toggle, a short splash screen, refined header icons and spacing, search icon, and clearer game-card metadata/odds typography.
- Theme preference is stored in browser localStorage.

# מרדכי ווינרים - ליגת האומות

הדמיית הימורים לנייד על משחקי יורו ליגת האומות. היתרה וירטואלית, בלי הפקדות ובלי משיכות.

Live app (after GitHub username/repository rename): https://dvircos.github.io/dmw/

## איך זה עובד

- ההרשמה פותחת פרופיל עם יתרת פתיחה של ₪1,000 וירטואליים.
- הימור מתקבל רק דרך הפונקציה `place_bet`: היחס נקרא מטבלת המשחקים בתוך מסד הנתונים, התשלום מחושב שם, והיתרה והטופס נשמרים באותה טרנזקציה.
- אי אפשר לשלוח טופס אם נשארו פחות מחמש דקות לפתיחת המשחק.
- `main.py` מושך משחקים, סטטוסים ותוצאות מהזנת הכדורגל החיצונית בלבד. יחסי 1X2 מגיעים אך ורק מתוסף Winner. ההכרעה מתבצעת לפי תוצאת 90 הדקות בלבד.
- משחקים עם מספר מפגש מעל 900000 הם משחקי הדגמה, עד שמגדירים מפתח אמיתי של API-Football.

## עדכון יחסים ותוצאות

הזרימה רצה כל שעתיים ב-GitHub Actions, ואפשר גם להפעיל אותה ידנית. נדרש מפתח ספק נתוני הכדורגל ב-secret בשם `API_KEY`. מפתח השירות של Supabase נשאר ב-secrets של Actions ואינו נמצא בקוד האתר.

## League filters and admin panel update (extension 2.1.1)

The catalogue sync keeps all Israeli Premier League and UEFA Champions League fixtures, plus the existing Nations League fixtures. In Spain it keeps only Real Madrid or Barcelona matches. In the English Premier League it keeps only matches involving Manchester United, Manchester City, Liverpool, Arsenal, or Chelsea. The Winner extension captures full-time 1X2 markets only for those leagues/teams and the existing Nations League.

### Admin panel setup

1. Run `migration_admin_panel.sql` once in the Supabase SQL Editor.
2. In Supabase SQL Editor, find your account UUID:
   ```sql
   select id, email from auth.users order by created_at;
   ```
3. Insert **your own** UUID into the admin allowlist (replace the UUID):
   ```sql
   insert into public.admin_users(user_id) values ('YOUR-AUTH-USER-UUID');
   ```
4. Deploy the updated site files and reload the extension folder in Chrome.

Only UUIDs in `admin_users` can call the admin RPCs. The browser contains no service-role key. Resetting a user's balance to ₪1,000 leaves all pending bets unchanged. The delete action is a soft delete: it hides the profile from the public leaderboard and retains its bet history. Admin actions are recorded in `admin_audit_log`.

Run the SQL migrations in this order if the project has not already had them applied: the existing schema/migrations used by your current installation, then `migration_allow_repeated_bets.sql`, then `migration_admin_panel.sql`. Do not rerun the base schema on a live project without checking its effects.


### מקור יחסי זכייה ותוצאות
- יחסי 1X2 מגיעים **רק מתוסף Winner**. תהליך הסנכרון החיצוני אינו קורא או מעדכן יחסי זכייה, כדי שלא ידרוס נתונים שנקלטו מ-Winner.
- ה-API החיצוני נשאר פעיל רק לאיתור משחקים, סטטוסים ותוצאות; לא מבטלים אותו כל עוד רוצים עדכון תוצאות אוטומטי.
- סנכרון קטלוג המשחקים מתבצע פעם בשבוע בלבד (`sync.yml`), לטווח שבעת הימים הבאים. סנכרון תוצאות נפרד מתבצע בערב כל חצי שעה (`sync-results.yml`) ורק למשחקים שכבר התחילו, קיימים באפליקציה, ממופים ל־API-Football וטרם הוכרעו.
- תוצאה רגילה (`FT`) נבדקת לאחר 95 דקות לפחות מהפתיחה; `AET`/`PEN` רק לאחר 120 דקות לפחות. התוצאה שנשלחת להכרעה היא `score.fulltime` (תוצאת 90 הדקות), ולא שערי הארכה או דו־קרב הפנדלים. פונקציית RPC ייעודית מעדכנת הימורים בודדים ומשולבים פעם אחת בלבד.
- מצבי הארכה/דו־קרב שעדיין מתנהלים (`ET`, `P`) נשארים חיים. `PST`, `ABD`, `AWD` ו־`WO` אינם מבוטלים אוטומטית; רק `CANC` מזכה החזר אוטומטי.


## Hourly Winner synchronization (extension 2.2.0)

- The Chrome extension stores a compact history of captured fixtures and their last 1X2 prices. It queues only new fixtures or fixtures whose 1X2 prices changed, avoiding repeated submissions of unchanged markets.
- When Chrome is running, the extension schedules a Winner scan every 60 minutes. It uses the open Winner tab and reloads it to trigger Winner's normal fixture/market requests; this can refresh the page and interrupt an action in progress, so keep Winner on a listing page rather than in the middle of a transaction.
- The app must be opened and signed in once after installing/updating the extension so the extension can receive the Supabase session refresh token. After that, the app tab can be closed; the extension refreshes the session as needed and sends updates directly to Supabase. If the user signs out or revokes the session, sign in again in the app.
- If the computer is off, Chrome is closed, or no Winner tab is open, no scan occurs. The next scan runs when the browser is available and the Winner tab is open.
- The hourly scan does not create games by itself; it captures only 1X2 data Winner actually returns to the page. The separate fixture sync remains responsible for creating/updating the fixture catalogue.
- To update: open `chrome://extensions`, enable Developer mode, click Reload on the unpacked extension (or Load unpacked from the updated `winner-extension` folder). Then open the app and sign in once, and keep a Winner tab open.


## אחרי שינוי שמות ב-GitHub
הכתובת הצפויה: https://dvircos.github.io/dmw/
יש להוסיף את הכתובת החדשה ב-Supabase Authentication > URL Configuration > Redirect URLs.
לאחר החלפת קובצי התוסף יש לפתוח chrome://extensions וללחוץ Reload.


## API-Football — הפרדה בין קטלוג לתוצאות

- `sync_api_football.py fixtures`: ריצה שבועית בלבד; מושכת את שבעת הימים הבאים עבור ליגת העל בישראל (202), ליגת האלופות (2), לה ליגה (140), הפרמייר ליג (39) וליגת האומות (633).
- `sync_api_football.py results`: ריצת ערב כל 30 דקות; קוראת תחילה רק את משחקי האפליקציה שכבר עבר מועד הפתיחה שלהם, שטרם אושרה בהם תוצאה ושיש להם מזהה API-Football. המזהים נשלחים בקבוצות של עד 20 במשיכת `/fixtures?ids=`.
- מזהה API-Football נשמר בעמודה נפרדת `api_football_fixture_id`. מזהה השורה הפנימי `games.id` נשאר קבוע, ולכן הפניות של `bets` ו־`bet_items` נשמרות.
- שמות הקבוצות המקוריים מה־API נשמרים בעמודות alias. ייבוא Winner יכול להתאים לפי השם המוצג באפליקציה או לפי שם ה־API, יחד עם שעת הפתיחה (חלון 20 דקות). Winner נשאר המקור היחיד ליחסי 1X2.
- מגבלת בטיחות פנימית עוצרת את התהליכים ב־80 בקשות ביום, מתחת למכסת Free של 100 בקשות ביום.
- פריסה: להריץ תחילה ב־Supabase את `migration_api_football_split_sync.sql`, ולאחריו את הגרסה המעודכנת של `migration_winner_extension.sql`. מפתח API-Football ישיר נשמר ב־GitHub Actions Secret בשם `API_KEY`; סודות Supabase הקיימים נשארים ללא שינוי.
- `main.py` הישן אינו עוד נקודת כניסה לסנכרון. אין להריץ אותו; משתמשים בשתי הפקודות החדשות בלבד.
