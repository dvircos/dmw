# מרדכי ווינרים - ליגת האומות

הדמיית הימורים לנייד על משחקי יורו ליגת האומות. היתרה וירטואלית, בלי הפקדות ובלי משיכות.

Live app: https://dvirmor11-create.github.io/mordechai-winners-nations/

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
- סנכרון המשחקים והתוצאות מתוזמן כל שעתיים. חמש ליגות כפול 12 ריצות ביום הן עד 60 קריאות ליגה ביום, לפני קריאות חריגות/דפדוף.
- תוצאה סופית מאושרת לאחר 105 דקות לפחות מפתיחת המשחק, ואז `sync_game_result` מעדכנת הימורים בודדים ומשולבים ומזכה יתרות באופן אידמפוטנטי (הימורים שכבר הוכרעו אינם מזוכים שוב).
- משחקים שהסתיימו בהארכה/פנדלים בפיד RapidAPI אינם מוכרעים אוטומטית אם אין ציון ברור של 90 דקות; יש לבדוק אותם ידנית ולא לנחש תוצאה.
