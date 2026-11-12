import { createClient } from "https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.49.1/+esm";
import { SUPABASE_ANON_KEY, SUPABASE_URL } from "./config.js";
import { BET_STATUS, GAME_STATUS, SELECTION, canBet, canCancel, canEdit, countdownLabel, leagueKey, money, slipLegs, when } from "./format.js";
import { toast } from "./toast.js";





const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
const state = {
  mode: "login",
  tab: "games",
  user: null,
  balance: 0,
  games: [],
  archiveGames: [],
  archiveOffset: 0,
  archiveHasMore: false,
  archiveLoading: false,
  gameMarkets: [],
  marketSettings: { handicap_ft: true, total_goals_2_5: true, btts: true },
  expandedGameId: null,
  gameView: "active",
  bets: [],
  betsFilter: "pending",
  board: [],
  groups: [],
  activeGroupId: "00000000-0000-0000-0000-000000000001",
  selected: null,
  submitting: false,
  channel: null,
  league: "all",
  slipTab: "combined",
  query: "",
  clock: null,
  slip: [],
  slipOpen: false,
  isAdmin: false,
  settledBadgeInitialized: false,
  refreshing: false,
};

const $ = (id) => document.getElementById(id);


function applyTheme(theme) {
  const next = theme === "light" ? "light" : "dark";
  document.body.dataset.theme = next;
  localStorage.setItem("mw-theme", next);
  const icon = $("theme-icon");
  if (icon) {
    icon.innerHTML = next === "light"
      ? '<path d="M20.5 15.5A8.5 8.5 0 0 1 8.5 3.5 8.5 8.5 0 1 0 20.5 15.5Z"/>'
      : '<circle cx="12" cy="12" r="4"/><path d="M12 2v2m0 16v2M4.93 4.93l1.42 1.42m11.3 11.3 1.42 1.42M2 12h2m16 0h2M4.93 19.07l1.42-1.42m11.3-11.3 1.42-1.42"/>';
  }
  const meta = document.querySelector('meta[name="theme-color"]');
  if (meta) meta.content = next === "light" ? "#f8fbff" : "#0f172a";
}

function initVisualPreferences() {
  applyTheme(localStorage.getItem("mw-theme") || "dark");
  $("theme-toggle")?.addEventListener("click", () => {
    applyTheme(document.body.dataset.theme === "dark" ? "light" : "dark");
  });
  const dismissSplash = () => {
    const splash = $("splash-screen");
    if (!splash || splash.dataset.dismissed === "1") return;
    splash.dataset.dismissed = "1";
    splash.classList.add("splash-hidden");
    window.setTimeout(() => splash.remove(), 350);
  };
  if (document.documentElement.classList.contains("tw-ready")) {
    window.setTimeout(dismissSplash, 150);
  } else {
    window.addEventListener("dmw:styles-ready", () => window.setTimeout(dismissSplash, 150), { once: true });
    window.setTimeout(() => {
      if (document.documentElement.classList.contains("tw-ready")) dismissSplash();
    }, 10000);
  }
}

function cleanError(error) {
  const raw = error?.message || error?.details || "הפעולה נכשלה";
  const line = String(raw).split("\n")[0];
  if (/failed to fetch|network/i.test(line)) return "אין חיבור לשרת";
  if (/invalid login/i.test(line)) return "אימייל או סיסמה שגויים";
  if (/already registered|already been registered/i.test(line)) return "האימייל כבר רשום";
  if (/password/i.test(line)) return "הסיסמה חייבת להכיל לפחות 6 תווים";
  if (/email not confirmed/i.test(line)) return "אשרו את האימייל ואז התחברו";
  return line.length > 180 ? "הפעולה נכשלה" : line;
}

function setBalance(value) {
  state.balance = Number(value) || 0;
  const node = $("balance");
  node.textContent = money(state.balance);
  node.classList.remove("flash");
  void node.offsetWidth;
  node.classList.add("flash");
}

function flag(url) {
  const img = document.createElement("img");
  img.alt = "";
  img.className = "h-8 w-8 rounded-full bg-white/10 object-cover";
  img.referrerPolicy = "no-referrer";
  if (typeof url === "string" && url.startsWith("https://")) img.src = url;
  return img;
}

function empty(parent, text) {
  parent.replaceChildren();
  const p = document.createElement("p");
  p.className = "rounded-2xl border border-dashed border-slate-700/50 px-4 py-10 text-center text-sm text-mist";
  p.textContent = text;
  parent.appendChild(p);
}

function showTab(tab) {
  state.tab = tab;
  if (tab === "games") state.gameView = "active";
  if (tab === "archive") state.gameView = "archive";
  const gamesVisible = tab === "games" || tab === "archive";
  $("games-tools").classList.toggle("hidden", !gamesVisible);
  $("view-games").classList.toggle("hidden", !gamesVisible);
  $("view-bets").classList.toggle("hidden", tab !== "bets");
  $("view-board").classList.toggle("hidden", tab !== "board");
  $("view-admin").classList.toggle("hidden", tab !== "admin");
  if (gamesVisible) renderGames();
  if (tab === "bets") markSettledBetsSeen();
  if (tab === "admin" && state.isAdmin) refreshAdmin();
  document.querySelectorAll(".nav-btn").forEach((button) => {
    const active = button.dataset.tab === tab;
    button.classList.toggle("text-gold", active);
    button.classList.toggle("text-slate-400", !active);
  });
}

function paintLeagueTabs() {
  document.querySelectorAll(".league-tab").forEach((button) => {
    const active = button.dataset.league === state.league;
    button.classList.toggle("active", active);
    button.setAttribute("aria-pressed", active ? "true" : "false");
    button.classList.toggle("bg-gold", active);
    button.classList.toggle("font-bold", active);
    button.classList.toggle("text-ink", active);
    button.classList.toggle("font-medium", !active);
    button.classList.toggle("text-mist", !active);
  });
}

function coversGame(bet, game) {
  if (bet.status !== "pending") return false;
  if (Array.isArray(bet.bet_items) && bet.bet_items.some((item) => Number(item.game_id) === Number(game.id))) return true;
  return Number(bet.game_id) === Number(game.id);
}

function pendingStake(game) {
  return state.bets
    .filter((bet) => coversGame(bet, game))
    .reduce((sum, bet) => sum + Number(bet.bet_amount || 0), 0);
}

function settledBetIds() {
  return state.bets
    .filter((bet) => bet.status === "won" || bet.status === "lost")
    .map((bet) => String(bet.id));
}

function seenSettledStorageKey() {
  return state.user ? `dmw-seen-settled-${state.user.id}` : null;
}

function renderSettledBadge() {
  const badge = $("nav-bets-badge");
  if (!badge) return;
  const key = seenSettledStorageKey();
  let seen = [];
  try { seen = JSON.parse(localStorage.getItem(key) || "[]"); } catch (_error) {}
  const seenSet = new Set(Array.isArray(seen) ? seen.map(String) : []);
  const count = settledBetIds().filter((id) => !seenSet.has(id)).length;
  badge.textContent = count > 9 ? "9+" : String(count);
  badge.classList.toggle("hidden", count === 0);
}

function markSettledBetsSeen() {
  const key = seenSettledStorageKey();
  if (!key) return;
  try {
    localStorage.setItem(key, JSON.stringify(settledBetIds()));
  } catch (_error) {}
  renderSettledBadge();
}

function renderGames() {
  const root = $("view-games");
  const isArchive = state.gameView === "archive";
  const query = state.query.trim().toLowerCase();
  const source = isArchive ? state.archiveGames : state.games;
  const games = source
    .filter((game) => state.league === "all" || leagueKey(game) === state.league)
    .filter((game) => !query || `${game.home_team || ""} ${game.away_team || ""}`.toLowerCase().includes(query))
    .sort((a, b) => isArchive
      ? new Date(b.match_time) - new Date(a.match_time)
      : (a.status === "live" ? 0 : 1) - (b.status === "live" ? 0 : 1) || new Date(a.match_time) - new Date(b.match_time));
  root.replaceChildren();
  if (isArchive) {
    const heading = document.createElement("div");
    heading.className = "mb-3 flex items-center justify-between gap-2";
    const title = document.createElement("h2");
    title.className = "text-lg font-extrabold";
    title.textContent = "ארכיון משחקים";
    const count = document.createElement("span");
    count.className = "text-xs text-slate-400";
    count.textContent = `${state.archiveGames.length} משחקים נטענו`;
    heading.append(title, count);
    root.append(heading);
  }
  if (!games.length) {
    const message = query ? "לא נמצאה קבוצה" : isArchive ? "אין משחקים בארכיון" : state.league === "all" ? "אין משחקים להצגה" : "אין משחקים בליגה הזו";
    const placeholder = document.createElement("p");
    placeholder.className = "rounded-2xl border border-dashed border-slate-700/50 px-4 py-10 text-center text-sm text-mist";
    placeholder.textContent = message;
    root.append(placeholder);
    if (isArchive && state.archiveHasMore) appendArchiveMore(root);
    return;
  }
  games.forEach((game) => {
    const card = document.createElement("article");
    card.className = "mb-3 overflow-hidden rounded-2xl border border-slate-700/60 bg-panel shadow-lg";
    const body = document.createElement("div");
    body.className = "p-4";
    const head = document.createElement("div");
    head.className = "mb-3 flex items-center justify-between gap-2 text-xs text-slate-400";
    const time = document.createElement("span");
    const countdown = !isArchive ? countdownLabel(game) : "";
    time.textContent = [when(game.match_time), countdown].filter(Boolean).join(" · ");
    const badge = document.createElement("span");
    badge.className = game.status === "live" ? "font-bold text-rose-400" : game.status === "finished" ? "font-bold text-emerald-400" : "text-slate-400";
    badge.textContent = game.status === "live" ? "● חי" : (GAME_STATUS[game.status] || game.status);
    head.append(time, badge);
    const teams = document.createElement("div");
    teams.className = "grid grid-cols-[1fr_auto_1fr] items-center gap-2";
    const home = teamColumn(game.home_flag, game.home_team);
    const away = teamColumn(game.away_flag, game.away_team);
    const score = document.createElement("div");
    score.className = "min-w-14 text-center text-xl font-extrabold";
    score.dir = "ltr";
    score.textContent = game.status === "live" || game.status === "finished" ? `${game.home_score} - ${game.away_score}` : "VS";
    teams.append(home, score, away);
    body.append(head, teams);

    const stake = pendingStake(game);
    if (stake > 0) {
      const badgeStake = document.createElement("p");
      badgeStake.className = "mt-3 inline-flex rounded-full bg-gold/15 px-2 py-0.5 text-[11px] font-bold text-gold";
      badgeStake.textContent = `הימרת ₪${Number.isInteger(stake) ? String(stake) : money(stake)}`;
      body.append(badgeStake);
    }

    const enabledMarkets = isArchive ? [] : state.gameMarkets.filter((market) =>
      Number(market.game_id) === Number(game.id) &&
      market.active !== false &&
      state.marketSettings[market.market_key] !== false
    );
    const open = !isArchive && game.status === "upcoming" && new Date(game.match_time).getTime() > Date.now() + 5 * 60 * 1000;
    const hasMainOdds = !isArchive && [game.home_odds, game.draw_odds, game.away_odds].some((value) => Number(value) >= 1.01);

    // Main 1X2 odds are always visible directly on the game card.
    if (hasMainOdds) {
      const mainOdds = document.createElement("section");
      mainOdds.className = "mt-4";
      const title = document.createElement("h3");
      title.className = "mb-2 text-center text-xs font-bold text-slate-400";
      title.textContent = "תוצאת המשחק";
      const grid = document.createElement("div");
      grid.className = "grid grid-cols-3 gap-2";
      [["1",game.home_odds,"1 · בית"],["X",game.draw_odds,"X · תיקו"],["2",game.away_odds,"2 · חוץ"]].forEach(([selection,price,label]) => {
        const button = document.createElement("button");
        button.type = "button";
        button.disabled = !open || !Number.isFinite(Number(price)) || Number(price) < 1.01;
        const picked = state.slip.some((leg) => leg.gameId === Number(game.id) && !leg.marketId && leg.selection === selection);
        button.className = "rounded-xl border px-2 py-2.5 text-center transition active:scale-[.98] disabled:opacity-40 " + (picked ? "border-gold bg-gold/15 ring-1 ring-gold" : "border-slate-700/70 bg-ink/35");
        const l = document.createElement("span"); l.className="block text-[11px] text-slate-400"; l.textContent=label;
        const v = document.createElement("strong"); v.className="mt-1 block text-lg font-extrabold text-mint"; v.dir="ltr"; v.textContent=Number(price)>=1.01?Number(price).toFixed(2):"—";
        button.append(l,v);
        if (!button.disabled) button.addEventListener("click",()=>toggleSlip(game,selection,Number(price)));
        grid.append(button);
      });
      mainOdds.append(title, grid);
      body.append(mainOdds);
    }

    if (enabledMarkets.length) {
      const toggle = document.createElement("button");
      toggle.type = "button";
      const expanded = state.expandedGameId === Number(game.id);
      toggle.setAttribute("aria-label", expanded ? "סגירת שווקים נוספים" : "הצגת שווקים נוספים");
      toggle.setAttribute("aria-expanded", expanded ? "true" : "false");
      toggle.className = "mx-auto mt-3 flex min-h-9 items-center justify-center gap-2 rounded-full border border-slate-700/60 px-4 text-xs font-bold text-slate-300 transition hover:border-gold/50 hover:text-gold";
      const label = document.createElement("span");
      label.textContent = expanded ? "הסתרת שווקים" : `${enabledMarkets.length} שווקים נוספים`;
      const toggleIcon = document.createElement("span");
      toggleIcon.className = "text-base leading-none";
      toggleIcon.textContent = expanded ? "⌃" : "⌄";
      toggle.append(label, toggleIcon);
      toggle.addEventListener("click", () => {
        state.expandedGameId = expanded ? null : Number(game.id);
        renderGames();
      });
      body.append(toggle);
    }
    card.append(body);

    if (enabledMarkets.length && state.expandedGameId === Number(game.id)) {
      const panel = document.createElement("div");
      panel.className = "space-y-4 border-t border-slate-700/60 bg-ink/20 p-4";
      enabledMarkets.forEach((market) => {
        const group = document.createElement("section");
        group.className = "rounded-xl border border-slate-700/60 bg-panel p-3";
        const title = document.createElement("h3");
        title.className = "mb-3 text-sm font-extrabold text-slate-100";
        title.textContent = market.market_key === "handicap_ft" && market.line != null
          ? `${market.market_label || "הפרשי שערים"} (${Number(market.line) > 0 ? "+" : ""}${Number(market.line)})`
          : market.market_label || "אפשרויות הימור";
        const outcomes = Array.isArray(market.outcomes) ? market.outcomes : [];
        const grid = document.createElement("div");
        grid.className = "grid grid-cols-2 gap-2";
        outcomes.forEach((outcome) => {
          const price = Number(outcome.price);
          const button = document.createElement("button");
          button.type = "button";
          button.disabled = !open || !Number.isFinite(price) || price < 1.01;
          const picked = state.slip.some((leg) => leg.gameId === Number(game.id) && Number(leg.marketId) === Number(market.id) && leg.marketSelection === outcome.selection);
          button.className = "rounded-xl border px-2 py-3 text-center transition active:scale-[.98] disabled:opacity-40 " + (picked ? "border-gold bg-gold/15 ring-1 ring-gold" : "border-slate-700/70 bg-ink/50");
          const label = document.createElement("span"); label.className="block text-xs text-slate-300"; label.textContent=outcome.label || outcome.selection;
          const value = document.createElement("strong"); value.className="mt-1 block text-lg text-mint"; value.dir="ltr"; value.textContent=Number.isFinite(price)?price.toFixed(2):"—";
          button.append(label,value);
          if (!button.disabled) button.addEventListener("click",()=>toggleMarketSlip(game,market,outcome));
          grid.append(button);
        });
        group.append(title,grid); panel.append(group);
      });
      if (!enabledMarkets.length) {
        const none=document.createElement("p"); none.className="text-center text-xs text-slate-400"; none.textContent="אין כרגע שווקים זמינים למשחק הזה"; panel.append(none);
      }
      card.append(panel);
    }
    root.append(card);
  });
  if (isArchive && state.archiveHasMore) appendArchiveMore(root);
}

function appendArchiveMore(root) {
  const button = document.createElement("button");
  button.type = "button";
  button.disabled = state.archiveLoading;
  button.className = "mb-5 w-full rounded-xl border border-slate-600/60 bg-panel px-4 py-3 text-sm font-bold text-slate-200 disabled:opacity-50";
  button.textContent = state.archiveLoading ? "טוען משחקים..." : "הצגת משחקים ישנים יותר";
  button.addEventListener("click", loadMoreArchive);
  root.append(button);
}

async function loadMoreArchive() {
  if (state.archiveLoading || !state.archiveHasMore) return;
  state.archiveLoading = true;
  renderGames();
  const from = state.archiveOffset;
  const to = from + 49;
  const { data, error } = await supabase.from("games").select("*")
    .in("status", ["finished", "cancelled"])
    .order("match_time", { ascending: false })
    .range(from, to);
  state.archiveLoading = false;
  if (error) {
    toast(cleanError(error), "error");
    renderGames();
    return;
  }
  const rows = data || [];
  state.archiveGames = [...state.archiveGames, ...rows];
  state.archiveOffset += rows.length;
  state.archiveHasMore = rows.length === 50;
  renderGames();
}

function teamColumn(url, name) {
  const wrap = document.createElement("div");
  wrap.className = "flex min-w-0 flex-col items-center gap-1 text-center";
  const title = document.createElement("span");
  title.className = "max-w-full truncate text-sm font-bold";
  title.textContent = name;
  wrap.append(flag(url), title);
  return wrap;
}

function renderBets() {
  const root = $("view-bets");
  root.replaceChildren();

  const filters = [
    ["pending", "פתוחים"],
    ["settled", "הסתיימו"],
    ["all", "הכל"],
  ];
  const toolbar = document.createElement("div");
  toolbar.className = "mb-4 rounded-2xl border border-slate-700/60 bg-[#17243a] p-2";
  const tabs = document.createElement("div");
  tabs.className = "grid grid-cols-3 gap-1";
  filters.forEach(([key, label]) => {
    const button = document.createElement("button");
    button.type = "button";
    button.className = state.betsFilter === key
      ? "rounded-xl bg-gold px-2 py-2.5 text-sm font-extrabold text-ink shadow"
      : "rounded-xl px-2 py-2.5 text-sm font-medium text-slate-300";
    button.textContent = label;
    button.addEventListener("click", () => {
      state.betsFilter = key;
      renderBets();
    });
    tabs.append(button);
  });
  toolbar.append(tabs);
  root.append(toolbar);

  // Cancelled selections are not real betting history: their stake was returned.
  // Keep only placed bets (pending) and bets that were actually settled (won/lost).
  const historyBets = state.bets.filter((bet) => ["pending", "won", "lost", "void"].includes(bet.status));
  const isPending = (bet) => bet.status === "pending";
  const visible = historyBets.filter((bet) => state.betsFilter === "all"
    || (state.betsFilter === "pending" ? isPending(bet) : !isPending(bet)));
  const counts = {
    pending: historyBets.filter(isPending).length,
    settled: historyBets.filter((bet) => ["won", "lost", "void"].includes(bet.status)).length,
  };
  tabs.querySelectorAll("button").forEach((button, index) => {
    const key = filters[index][0];
    if (key === "pending") button.textContent = `פתוחים · ${counts.pending}`;
    if (key === "settled") button.textContent = `הסתיימו · ${counts.settled}`;
  });

  if (!visible.length) {
    empty(root, historyBets.length ? "אין הימורים בקטגוריה הזו" : "עדיין אין הימורים");
    return;
  }

  visible.forEach((bet) => {
    const legs = slipLegs(bet);
    const combined = legs.length > 1;
    const game = legs[0]?.games || bet.games || {};
    const card = document.createElement("article");
    card.className = "bet-history-card mb-3 overflow-hidden rounded-2xl border border-slate-700/70 bg-[#1b2940] shadow-lg";

    const top = document.createElement("div");
    top.className = "flex items-start justify-between gap-3 px-4 pt-4";
    const heading = document.createElement("div");
    heading.className = "min-w-0";
    const title = document.createElement("p");
    title.className = "font-bold leading-6 text-slate-50";
    title.textContent = bet.market_label ? `${game.home_team || "משחק"} נגד ${game.away_team || ""} · ${bet.market_label}` : combined ? `טופס משולב · ${legs.length} משחקים` : `${game.home_team || "משחק"} נגד ${game.away_team || ""}`;
    const sub = document.createElement("p");
    sub.className = "mt-1 text-xs text-slate-400";
    sub.textContent = bet.market_outcome_label ? `${when(game.match_time)} · ${bet.market_outcome_label}` : combined ? "מספר משחקים בטופס אחד" : when(game.match_time);
    heading.append(title, sub);

    const status = document.createElement("span");
    status.className = `shrink-0 rounded-full px-2.5 py-1 text-xs font-bold ${bet.status === "won" ? "bg-emerald-400/15 text-emerald-300" : bet.status === "lost" ? "bg-rose-400/15 text-rose-300" : bet.status === "void" ? "bg-slate-400/15 text-slate-300" : "bg-amber-300/15 text-amber-200"}`;
    status.textContent = BET_STATUS[bet.status] || bet.status;
    top.append(heading, status);
    card.append(top);

    if (combined) {
      const details = document.createElement("details");
      details.className = "bet-legs-details mx-3 mt-3 rounded-xl border border-slate-600/50 bg-[#111d31]";
      const summary = document.createElement("summary");
      summary.className = "cursor-pointer list-none px-3 py-3 text-sm font-semibold text-slate-200";
      summary.textContent = "הצגת משחקי הטופס";
      const list = document.createElement("div");
      list.className = "space-y-2 border-t border-slate-700/70 px-3 py-3";
      legs.forEach((leg) => {
        const match = leg.games || {};
        const row = document.createElement("div");
        row.className = "flex items-center justify-between gap-2 text-sm";
        const name = document.createElement("span");
        name.className = "min-w-0 text-slate-200";
        name.textContent = `${match.home_team || "משחק"} – ${match.away_team || ""}`;
        const pick = document.createElement("span");
        pick.className = "shrink-0 text-xs text-slate-400";
        pick.textContent = (leg.market_outcome_label ? leg.market_label + " · " + leg.market_outcome_label : (SELECTION[leg.bet_selection] || leg.bet_selection)) + " · " + Number(leg.odds).toFixed(2);
        row.append(name, pick);
        list.append(row);
      });
      details.append(summary, list);
      card.append(details);
    }

    const metrics = document.createElement("div");
    metrics.className = "mt-3 grid grid-cols-2 gap-2 border-t border-slate-700/60 bg-[#152238] px-4 py-3";
    const stake = document.createElement("div");
    stake.innerHTML = '<span class="block text-[11px] text-slate-400">סכום הימור</span>';
    const stakeValue = document.createElement("strong");
    stakeValue.className = "mt-0.5 block text-base text-slate-100";
    stakeValue.textContent = `₪${money(bet.bet_amount)}`;
    stake.append(stakeValue);
    const returnBox = document.createElement("div");
    returnBox.className = "text-left";
    returnBox.innerHTML = `<span class="block text-[11px] text-slate-400">${bet.status === "pending" ? "זכייה אפשרית" : bet.status === "won" ? "תשלום בפועל" : bet.status === "void" ? "החזר" : "תשלום"}</span>`;
    const payout = document.createElement("strong");
    payout.className = "mt-0.5 block text-base text-gold";
    payout.textContent = `₪${money(bet.status === "lost" ? 0 : bet.potential_payout)}`;
    if (bet.status === "lost") payout.className = "mt-0.5 block text-base text-rose-300";
    if (bet.status === "void") payout.className = "mt-0.5 block text-base text-slate-300";
    returnBox.append(payout);
    metrics.append(stake, returnBox);
    card.append(metrics);

    const odds = document.createElement("p");
    odds.className = "px-4 pb-3 pt-2 text-xs text-slate-400";
    odds.textContent = `${combined ? "יחס משולב" : "יחס"} · ${Number(bet.odds).toFixed(2)}`;
    card.append(odds);

    if (bet.status === "pending") {
      const editable = !bet.market_id && canEdit(bet);
      const cancellable = canCancel(bet);
      const actions = document.createElement("div");
      actions.className = "grid grid-cols-2 gap-2 px-3 pb-3";
      if (!combined) {
        const edit = document.createElement("button");
        edit.type = "button";
        edit.className = "rounded-xl border border-slate-500/60 py-2.5 text-sm font-bold text-slate-100 disabled:opacity-40";
        edit.textContent = editable ? "עריכת הימור" : "ההימור נעול";
        edit.disabled = !editable;
        if (editable) edit.addEventListener("click", () => openSheet(game, bet.bet_selection || legs[0].bet_selection, bet.odds, bet));
        actions.append(edit);
      } else {
        const spacer = document.createElement("span");
        actions.append(spacer);
      }
      if (cancellable) {
        const cancel = document.createElement("button");
        cancel.type = "button";
        cancel.className = "rounded-xl border border-rose-400/40 py-2.5 text-sm font-bold text-rose-300";
        cancel.textContent = "ביטול הימור";
        cancel.addEventListener("click", () => cancelBet(bet));
        actions.append(cancel);
      }
      if (actions.childElementCount) card.append(actions);
    }
    root.append(card);
  });
}

function renderBoard() {
  const root = $("view-board");
  root.replaceChildren();

  const heading = document.createElement("div");
  heading.className = "mb-3 flex items-center justify-between gap-2";
  const title = document.createElement("h2");
  title.className = "text-xl font-extrabold";
  title.textContent = "טבלת מובילים";
  heading.append(title);
  root.append(heading);

  const actions = document.createElement("div");
  actions.className = "mb-4 grid grid-cols-2 gap-2";
  const create = document.createElement("button");
  create.type = "button";
  create.className = "rounded-xl bg-gold px-3 py-3 text-sm font-extrabold text-ink";
  create.textContent = "＋ יצירת קבוצה";
  create.addEventListener("click", async () => {
    const name = prompt("איך לקרוא לקבוצה?");
    if (name === null) return;
    if (name.trim().length < 2 || name.trim().length > 40) { toast("שם הקבוצה חייב להכיל 2 עד 40 תווים","error"); return; }
    const isPublic = confirm("להציג את הקבוצה ברשימת הקבוצות שכולם יכולים להצטרף אליה?\nבחרו ביטול כדי ליצור קבוצה פרטית באמצעות קישור.");
    const { data, error } = await supabase.rpc("groups_create", { p_name: name.trim(), p_is_public: isPublic });
    if (error) { toast(cleanError(error),"error"); return; }
    state.activeGroupId = data.id;
    toast(isPublic ? "הקבוצה נוצרה והיא זמינה להצטרפות" : "הקבוצה הפרטית נוצרה");
    await refreshBoard();
    if (data.invite_code && navigator.clipboard?.writeText) {
      try { await navigator.clipboard.writeText(data.invite_code); toast("קישור ההצטרפות הועתק ללוח"); } catch { toast("קוד הצטרפות: "+data.invite_code); }
    } else if (data.invite_code) toast("קוד הצטרפות: "+data.invite_code);
  });
  const join = document.createElement("button");
  join.type = "button";
  join.className = "rounded-xl border border-slate-600 bg-panel px-3 py-3 text-sm font-bold";
  join.textContent = "הצטרפות עם קוד";
  join.addEventListener("click", async () => {
    const code = prompt("הדביקו קוד או קישור הצטרפות לקבוצה:");
    if (!code) return;
    const match = code.match(/[a-f0-9]{12}/i);
    const inviteCode = match ? match[0] : code.trim();
    const { error } = await supabase.rpc("groups_join", { p_invite_code: inviteCode, p_group_id: null });
    if (error) { toast(cleanError(error),"error"); return; }
    toast("הצטרפת לקבוצה");
    await refreshBoard();
  });
  actions.append(create,join);
  root.append(actions);

  const groupTitle = document.createElement("p");
  groupTitle.className = "mb-2 text-xs font-bold text-slate-400";
  groupTitle.textContent = "הקבוצות שלך וקבוצות פתוחות";
  root.append(groupTitle);
  const groupList = document.createElement("div");
  groupList.className = "mb-4 flex gap-2 overflow-x-auto pb-2";
  (state.groups || []).forEach((group) => {
    const wrap = document.createElement("div");
    wrap.className = "shrink-0";
    if (group.is_member) {
      const select = document.createElement("button");
      select.type = "button";
      select.className = `rounded-xl border px-3 py-2 text-sm font-bold ${group.id === state.activeGroupId ? "border-gold bg-gold/15 text-gold" : "border-slate-700 bg-panel text-slate-200"}`;
      select.textContent = group.id === "00000000-0000-0000-0000-000000000001" ? "🌍 כולם" : group.name;
      select.addEventListener("click", async () => { state.activeGroupId = group.id; await refreshBoard(); });
      wrap.append(select);
      if (group.invite_code && group.id !== "00000000-0000-0000-0000-000000000001") {
        const share = document.createElement("button");
        share.type = "button";
        share.className = "ml-1 rounded-lg border border-slate-700 px-2 py-2 text-xs text-slate-300";
        share.textContent = "קישור";
        share.addEventListener("click", async () => {
          const url = new URL(location.href);
          url.searchParams.set("join", group.invite_code);
          try { await navigator.clipboard.writeText(url.toString()); toast("קישור ההצטרפות הועתק"); }
          catch { toast("קוד הצטרפות: "+group.invite_code); }
        });
        wrap.append(share);
      }
    } else {
      const joinGroup = document.createElement("button");
      joinGroup.type = "button";
      joinGroup.className = "rounded-xl border border-slate-700 bg-panel px-3 py-2 text-sm text-slate-200";
      joinGroup.textContent = `הצטרפות · ${group.name} · ${group.member_count}`;
      joinGroup.addEventListener("click", async () => {
        const { error } = await supabase.rpc("groups_join", { p_invite_code: null, p_group_id: group.id });
        if (error) { toast(cleanError(error),"error"); return; }
        state.activeGroupId = group.id;
        await refreshBoard();
      });
      wrap.append(joinGroup);
    }
    groupList.append(wrap);
  });
  root.append(groupList);

  const active = state.groups.find((group) => group.id === state.activeGroupId);
  const activeTitle = document.createElement("h3");
  activeTitle.className = "mb-3 text-base font-extrabold text-gold";
  activeTitle.textContent = active?.id === "00000000-0000-0000-0000-000000000001" ? "טבלת כולם" : `קבוצת ${active?.name || ""}`;
  root.append(activeTitle);

  if (!state.board.length) {
    empty(root, "עדיין אין שחקנים בקבוצה הזו");
    return;
  }
  const podium = state.board.length >= 3 ? document.createElement("div") : null;
  if (podium) {
    podium.className = "mb-4 grid grid-cols-3 gap-2";
    const medals = ["🥇", "🥈", "🥉"];
    state.board.slice(0, 3).forEach((row, index) => {
      const mine = row.id === state.user?.id;
      const card = document.createElement("div");
      card.className = `min-w-0 rounded-2xl border px-2 py-3 text-center ${mine ? "border-gold bg-gold/15" : "border-slate-700/60 bg-panel"}`;
      const medal = document.createElement("div");
      medal.className = "text-2xl";
      medal.textContent = medals[index];
      const name = document.createElement("p");
      name.className = "mt-1 truncate text-xs font-extrabold";
      name.textContent = row.username;
      const amount = document.createElement("p");
      amount.className = "mt-1 truncate text-xs font-bold text-gold";
      amount.dir = "ltr";
      amount.textContent = `₪${money(row.balance)}`;
      card.append(medal, name, amount);
      podium.append(card);
    });
    root.append(podium);
  }
  state.board.slice(podium ? 3 : 0).forEach((row, offset) => {
    const index = offset + (podium ? 3 : 0);
    const item = document.createElement("div");
    const mine = row.id === state.user?.id;
    item.className = `mb-2 flex items-center justify-between rounded-2xl border px-4 py-3 ${mine ? "border-gold bg-gold/15 ring-1 ring-gold" : "border-slate-700/40 bg-panel"}`;
    const who = document.createElement("div");
    who.className = "flex min-w-0 items-center gap-3";
    const place = document.createElement("span");
    place.className = "w-7 shrink-0 text-center text-sm font-extrabold text-gold";
    place.textContent = String(index + 1);
    const name = document.createElement("span");
    name.className = "truncate text-sm font-medium";
    name.textContent = row.username + (mine ? " · אתה" : "");
    who.append(place, name);
    const balance = document.createElement("span");
    balance.className = "shrink-0 text-sm font-bold";
    balance.dir = "ltr";
    balance.textContent = `₪${money(row.balance)}`;
    item.append(who, balance);
    root.append(item);
  });
}

function render() {
  renderGames();
  renderBets();
  renderBoard();
  renderSlip();
}

function slipTotal() {
  return state.slip.reduce((product, leg) => product * Number(leg.odds || 0), 1);
}

function slipRow(leg, extra) {
  const row = document.createElement("div");
  row.className = "mb-2 flex items-center justify-between gap-2 rounded-2xl border border-slate-700/50 bg-ink/60 px-3 py-2";
  const text = document.createElement("div");
  text.className = "min-w-0 flex-1";
  const name = document.createElement("p");
  name.className = "truncate text-sm font-bold text-slate-50";
  name.textContent = `${leg.home} נגד ${leg.away}`;
  const meta = document.createElement("p");
  meta.className = "text-xs text-mist";
  const pickLabel = leg.marketOutcomeLabel ? leg.marketLabel + " · " + leg.marketOutcomeLabel : (SELECTION[leg.selection] || leg.selection);
  meta.textContent = pickLabel + " · " + Number(leg.odds).toFixed(2);
  text.append(name, meta);
  const remove = document.createElement("button");
  remove.type = "button";
  remove.className = "shrink-0 px-1 text-base text-rose-300";
  remove.textContent = "✖";
  remove.addEventListener("click", () => {
    state.slip = state.slip.filter((item) => item.gameId !== leg.gameId);
    renderSlip();
    renderGames();
  });
  row.append(text);
  if (extra) row.append(extra);
  row.append(remove);
  return row;
}

function paintSlipTabs() {
  const combined = state.slipTab === "combined";
  $("slip-tab-combined").className = combined
    ? "rounded-xl bg-gold py-2 font-bold text-ink"
    : "rounded-xl py-2 font-medium text-mist";
  $("slip-tab-singles").className = combined
    ? "rounded-xl py-2 font-medium text-mist"
    : "rounded-xl bg-gold py-2 font-bold text-ink";
  $("slip-combined").classList.toggle("hidden", !combined);
  $("slip-singles").classList.toggle("hidden", combined);
  $("slip-confirm").textContent = combined ? "אישור משולב" : "אישור נפרדים";
}

function renderSlip() {
  const slip = $("slip");
  const backdrop = $("slip-backdrop");
  const app = $("app-view");
  if (!state.slip.length) {
    slip.classList.add("hidden");
    backdrop.classList.add("hidden");
    state.slipOpen = false;
    app.classList.remove("pb-44");
    app.classList.add("pb-28");
    return;
  }
  slip.classList.remove("hidden");
  app.classList.remove("pb-28");
  app.classList.add("pb-44");
  const total = slipTotal();
  $("slip-count").textContent = String(state.slip.length);
  $("slip-odds").textContent = total.toFixed(2);
  backdrop.classList.toggle("hidden", !state.slipOpen);
  paintSlipTabs();
  const combined = $("slip-combined-legs");
  combined.replaceChildren();
  const singles = $("slip-single-legs");
  singles.replaceChildren();
  state.slip.forEach((leg) => {
    combined.append(slipRow(leg));
    const stake = document.createElement("input");
    stake.inputMode = "decimal";
    stake.dir = "ltr";
    stake.value = leg.stake || "25";
    stake.className = "w-20 rounded-xl border border-slate-700/50 bg-ink px-2 py-2 text-center text-sm text-slate-50 outline-none focus:border-gold";
    stake.addEventListener("input", () => {
      leg.stake = stake.value;
      updateSinglesTotal();
    });
    singles.append(slipRow(leg, stake));
  });
  const amount = Number($("slip-stake").value);
  $("slip-total").textContent = total.toFixed(2);
  $("slip-payout").textContent = money(Number.isFinite(amount) && amount > 0 ? amount * total : 0);
  updateSinglesTotal();
}

function updateSinglesTotal() {
  const total = state.slip.reduce((sum, leg) => {
    const amount = Number(leg.stake || 0);
    return sum + (Number.isFinite(amount) && amount > 0 ? amount : 0);
  }, 0);
  const node = $("slip-singles-total");
  if (node) node.textContent = money(total);
}

function toggleSlip(game, selection, price) {
  const gameId = Number(game.id);
  const index = state.slip.findIndex((leg) => leg.gameId === gameId);
  if (index >= 0 && !state.slip[index].marketId && state.slip[index].selection === selection) state.slip.splice(index, 1);
  else {
    const leg = { gameId, selection, odds: Number(price), home: game.home_team, away: game.away_team, stake: index >= 0 ? state.slip[index].stake || "25" : "25" };
    if (index >= 0) state.slip[index] = leg;
    else { if (state.slip.length >= 8) { toast("אפשר עד 8 משחקים בטופס"); return; } state.slip.push(leg); }
  }
  renderSlip(); renderGames();
}

function toggleMarketSlip(game, market, outcome) {
  const gameId = Number(game.id);
  const index = state.slip.findIndex((leg) => leg.gameId === gameId);
  const same = index >= 0 && Number(state.slip[index].marketId) === Number(market.id) && state.slip[index].marketSelection === outcome.selection;
  if (same) state.slip.splice(index, 1);
  else {
    const leg = { gameId, marketId: Number(market.id), marketKey: market.market_key,
      marketLabel: market.market_label, marketOutcomeLabel: outcome.label, marketSelection: outcome.selection,
      marketLine: market.line, odds: Number(outcome.price), home: game.home_team, away: game.away_team,
      stake: index >= 0 ? state.slip[index].stake || "25" : "25" };
    if (index >= 0) state.slip[index] = leg;
    else { if (state.slip.length >= 8) { toast("אפשר עד 8 משחקים בטופס"); return; } state.slip.push(leg); }
  }
  renderSlip(); renderGames();
}

function oddsFor(game, selection) {
  if (selection === "1") return Number(game.home_odds);
  if (selection === "X") return Number(game.draw_odds);
  return Number(game.away_odds);
}

function renderSheetPicks(game, bet) {
  const picks = $("sheet-picks");
  picks.replaceChildren();
  if (!bet) {
    picks.classList.add("hidden");
    picks.classList.remove("grid");
    return;
  }
  picks.classList.remove("hidden");
  picks.classList.add("grid");
  ["1", "X", "2"].forEach((selection) => {
    const price = selection === bet.bet_selection ? Number(bet.odds) : oddsFor(game, selection);
    const button = document.createElement("button");
    button.type = "button";
    button.disabled = !Number.isFinite(price) || price < 1.01;
    button.className = "rounded-2xl border border-slate-700/50 bg-ink/60 px-2 py-2 text-center disabled:opacity-40";
    const label = document.createElement("div");
    label.className = "text-[11px] text-slate-400";
    label.textContent = selection === "1" ? "1 בית" : selection === "2" ? "2 חוץ" : "X תיקו";
    const value = document.createElement("div");
    value.className = "text-base font-extrabold text-mint";
    value.dir = "ltr";
    value.textContent = Number.isFinite(price) ? price.toFixed(2) : "—";
    button.append(label, value);
    button.addEventListener("click", () => {
      if (!state.selected) return;
      state.selected.selection = selection;
      state.selected.price = price;
      $("sheet-selection").textContent = `${SELECTION[selection]} · יחס נעול ${price.toFixed(2)}`;
      markPick(selection);
      updatePayout();
    });
    button.dataset.selection = selection;
    picks.append(button);
  });
  markPick(bet.bet_selection);
}

function markPick(selection) {
  $("sheet-picks").querySelectorAll("button").forEach((button) => {
    button.classList.toggle("ring-2", button.dataset.selection === selection);
    button.classList.toggle("ring-gold", button.dataset.selection === selection);
  });
}

function openSheet(game, selection, price, bet = null) {
  state.selected = {
    id: game.id || bet?.game_id,
    betId: bet ? bet.id : null,
    originalAmount: bet ? Number(bet.bet_amount) : 0,
    selection,
    price: Number(price),
    label: `${game.home_team} נגד ${game.away_team}`,
  };
  $("sheet-match").textContent = state.selected.label;
  $("sheet-selection").textContent = `${SELECTION[selection] || selection} · יחס ${bet ? "נעול" : "מוצג"} ${Number(price).toFixed(2)}`;
  $("sheet-note").textContent = "";
  $("sheet-confirm").textContent = bet ? "עדכון הימור" : "אישור הימור";
  $("sheet-balance").classList.toggle("hidden", !bet);
  if (bet) $("stake").value = String(bet.bet_amount);
  renderSheetPicks(game, bet);
  updatePayout();
  $("sheet-backdrop").classList.remove("hidden");
  $("sheet-backdrop").classList.add("flex");
}

function openMarketSheet(game, market, outcome) {
  openSheet(game, outcome.selection, Number(outcome.price));
  state.selected.marketId = Number(market.id);
  state.selected.marketKey = market.market_key;
  state.selected.marketSelection = outcome.selection;
  state.selected.marketLabel = market.market_label;
  state.selected.marketOutcomeLabel = outcome.label;
  $("sheet-selection").textContent = `${market.market_label} · ${outcome.label} · יחס ${Number(outcome.price).toFixed(2)}`;
  $("sheet-note").textContent = "היחס נבדק ונשמר בעת אישור ההימור";
  $("sheet-picks").classList.add("hidden");
  $("sheet-picks").classList.remove("grid");
}

function closeSheet() {
  state.selected = null;
  $("sheet-backdrop").classList.add("hidden");
  $("sheet-backdrop").classList.remove("flex");
}

function updatePayout() {
  const amount = Number($("stake").value);
  const price = state.selected?.price || 0;
  const payout = Number.isFinite(amount) && amount > 0 ? amount * price : 0;
  $("sheet-payout").textContent = money(payout);
  if (!state.selected?.betId) return;
  const next = state.balance + state.selected.originalAmount - (Number.isFinite(amount) ? amount : 0);
  $("sheet-balance").textContent = `יתרה אחרי האישור: ₪${money(next)}`;
}

async function refreshGames() {
  const [gamesResult, archiveResult, marketsResult, settingsResult] = await Promise.all([
    supabase.from("games").select("*").in("status", ["upcoming", "live"]).order("match_time", { ascending: true }).limit(200),
    supabase.from("games").select("*").in("status", ["finished", "cancelled"]).order("match_time", { ascending: false }).range(0, 49),
    supabase.from("winner_markets").select("id,game_id,market_key,market_label,line,outcomes,active").eq("active", true),
    supabase.rpc("get_market_display_settings")
  ]);
  if (gamesResult.error) {
    toast(cleanError(gamesResult.error), "error");
    return;
  }
  state.games = gamesResult.data || [];
  if (!archiveResult.error) {
    state.archiveGames = archiveResult.data || [];
    state.archiveOffset = state.archiveGames.length;
    state.archiveHasMore = state.archiveGames.length === 50;
  } else if (state.tab === "archive") {
    toast(cleanError(archiveResult.error), "error");
  }
  state.gameMarkets = marketsResult.error ? [] : (marketsResult.data || []);
  state.marketSettings = settingsResult.error
    ? { handicap_ft: true, total_goals_2_5: true, btts: true }
    : { handicap_ft: true, total_goals_2_5: true, btts: true, ...(settingsResult.data || {}) };
  if (state.expandedGameId && !state.games.some((game) => Number(game.id) === state.expandedGameId)) state.expandedGameId = null;
  renderGames();
}

async function refreshBets() {
  if (!state.user) return;
  const { data, error } = await supabase
    .from("bets")
    .select("id, bet_selection, bet_amount, odds, potential_payout, status, game_id, market_id, market_key, market_label, market_selection, market_outcome_label, market_line, games(home_team, away_team, status, home_score, away_score, match_time, home_odds, draw_odds, away_odds), bet_items(game_id, bet_selection, odds, status, market_id, market_key, market_selection, market_label, market_outcome_label, market_line, games(home_team, away_team, status, home_score, away_score, match_time, home_odds, draw_odds, away_odds))")
    .eq("user_id", state.user.id)
    .order("id", { ascending: false })
    .limit(1000);
  if (error) {
    toast(cleanError(error), "error");
    return;
  }
  state.bets = data || [];
  const seenKey = seenSettledStorageKey();
  if (seenKey && !state.settledBadgeInitialized) {
    // Establish a baseline once so old results do not appear as new notifications.
    if (localStorage.getItem(seenKey) === null) markSettledBetsSeen();
    state.settledBadgeInitialized = true;
  }
  renderSettledBadge();
  if (state.tab === "bets") markSettledBetsSeen();
  renderBets();
  renderGames();
}

async function refreshBoard() {
  const { data: groups, error: groupsError } = await supabase.rpc("groups_list");
  if (groupsError) { toast(cleanError(groupsError),"error"); return; }
  state.groups = Array.isArray(groups) ? groups : [];
  if (!state.groups.some((group) => group.id === state.activeGroupId && group.is_member)) {
    state.activeGroupId = "00000000-0000-0000-0000-000000000001";
  }
  const { data, error } = await supabase.rpc("groups_leaderboard", { p_group_id: state.activeGroupId });
  if (error) { toast(cleanError(error),"error"); return; }
  state.board = Array.isArray(data) ? data : [];
  renderBoard();
}

async function refreshAdmin() {
  if (!state.isAdmin) return;
  const root = $("view-admin");
  const { data, error } = await supabase.rpc("admin_list_users");
  if (error) { empty(root, cleanError(error)); return; }
  root.replaceChildren();
  const title = document.createElement("h2"); title.className = "mb-3 text-xl font-extrabold text-gold"; title.textContent = "ניהול משתמשים"; root.append(title);
  const note = document.createElement("p"); note.className = "mb-4 text-xs text-mist"; note.textContent = "איפוס יתרה ל־1,000 ₪ אינו משנה הימורים פתוחים. מחיקת משתמש היא רכה ושומרת היסטוריית הימורים."; root.append(note);
  const marketSettingsResult = await supabase.rpc("admin_get_market_settings");
  if (!marketSettingsResult.error) {
    const marketCard = document.createElement("section");
    marketCard.className = "mb-5 rounded-2xl border border-gold/25 bg-panel p-4";
    const marketTitle = document.createElement("h3");
    marketTitle.className = "mb-1 text-lg font-extrabold text-gold";
    marketTitle.textContent = "ניהול סוגי הימורים";
    const marketNote = document.createElement("p");
    marketNote.className = "mb-3 text-xs text-mist";
    marketNote.textContent = "הפעל או הסתר סוגי הימורים לכל המשחקים. שוק שלא קיים במשחק לא יוצג.";
    marketCard.append(marketTitle, marketNote);
    (marketSettingsResult.data || []).forEach((setting) => {
      const row = document.createElement("label");
      row.className = "flex cursor-pointer items-center justify-between gap-3 border-t border-slate-700/50 py-3";
      const label = document.createElement("span");
      label.className = "text-sm font-semibold";
      label.textContent = setting.label;
      const toggle = document.createElement("input");
      toggle.type = "checkbox";
      toggle.checked = Boolean(setting.enabled);
      toggle.className = "h-5 w-5 accent-amber-400";
      toggle.addEventListener("change", async () => {
        toggle.disabled = true;
        const result = await supabase.rpc("admin_set_market_setting", { p_market_key: setting.key, p_enabled: toggle.checked });
        toggle.disabled = false;
        if (result.error) {
          toggle.checked = !toggle.checked;
          toast(cleanError(result.error), "error");
          return;
        }
        state.marketSettings[setting.key] = toggle.checked;
        toast(toggle.checked ? "סוג ההימור הופעל" : "סוג ההימור הוסתר");
        renderGames();
      });
      row.append(label, toggle);
      marketCard.append(row);
    });
    root.append(marketCard);
  } else {
    const warning = document.createElement("p");
    warning.className = "mb-4 rounded-xl border border-amber-400/30 bg-amber-400/10 p-3 text-xs text-amber-200";
    warning.textContent = "לא ניתן לטעון את הגדרות סוגי ההימורים. בדוק את מיגרציות Winner ב־Supabase.";
    root.append(warning);
  }
  const unsettledResult = await supabase
    .from("winner_markets")
    .select("id,market_key,market_label,outcomes,games!inner(home_team,away_team,status,result_confirmed)")
    .eq("active", true)
    .is("settled_at", null)
    .eq("games.status", "finished")
    .eq("games.result_confirmed", true)
    .order("id", { ascending: false })
    .limit(80);
  const manualMarkets = (unsettledResult.data || []).filter((market) =>
    !["handicap_ft", "total_goals_2_5", "btts"].includes(market.market_key)
  );
  if (!unsettledResult.error && manualMarkets.length) {
    const settleCard = document.createElement("section");
    settleCard.className = "mb-5 rounded-2xl border border-amber-400/30 bg-panel p-4";
    const settleTitle = document.createElement("h3");
    settleTitle.className = "mb-1 text-lg font-extrabold text-amber-200";
    settleTitle.textContent = "הכרעת שווקים שהסתיימו";
    const settleNote = document.createElement("p");
    settleNote.className = "mb-3 text-xs text-mist";
    settleNote.textContent = "שווקים כמו קרנות, מבקיע ראשון ותוצאות מחצית דורשים נתון שלא מגיע מסנכרון התוצאה הרגיל. בחר את התוצאה הזוכה לאחר בדיקה.";
    settleCard.append(settleTitle, settleNote);
    manualMarkets.forEach((market) => {
      const game = market.games || {};
      const item = document.createElement("div");
      item.className = "border-t border-slate-700/60 py-3";
      const heading = document.createElement("p");
      heading.className = "mb-2 text-sm font-bold text-slate-100";
      heading.textContent = (game.home_team || "משחק") + " – " + (game.away_team || "") + " · " + market.market_label;
      item.append(heading);
      const outcomes = document.createElement("div");
      outcomes.className = "grid grid-cols-2 gap-2";
      (Array.isArray(market.outcomes) ? market.outcomes : []).forEach((outcome) => {
        const button = document.createElement("button");
        button.type = "button";
        button.className = "rounded-lg border border-slate-700 bg-ink/50 px-2 py-2 text-xs text-slate-200";
        button.textContent = (outcome.label || outcome.selection) + " · " + Number(outcome.price).toFixed(2);
        button.addEventListener("click", async () => {
          if (!confirm("לקבוע ש-" + (outcome.label || outcome.selection) + " היא התוצאה הזוכה בשוק הזה?")) return;
          button.disabled = true;
          const result = await supabase.rpc("admin_settle_winner_market", {
            p_market_id: Number(market.id),
            p_winning_selection: outcome.selection
          });
          if (result.error) {
            button.disabled = false;
            toast(cleanError(result.error), "error");
            return;
          }
          toast("השוק הוכרע והטפסים עודכנו");
          await refreshAdmin();
          await refreshBets();
          await refreshBoard();
        });
        outcomes.append(button);
      });
      item.append(outcomes);
      settleCard.append(item);
    });
    root.append(settleCard);
  } else if (unsettledResult.error) {
    const warning = document.createElement("p");
    warning.className = "mb-4 text-xs text-rose-300";
    warning.textContent = "לא ניתן לטעון שווקים להכרעה: " + cleanError(unsettledResult.error);
    root.append(warning);
  }
  (Array.isArray(data) ? data : []).forEach(user => {
    const card = document.createElement("article"); card.className = "mb-3 rounded-2xl border border-slate-700/50 bg-panel p-4";
    const head = document.createElement("div"); head.className = "mb-3 flex items-center justify-between gap-2";
    const name = document.createElement("strong"); name.textContent = user.is_deleted ? `${user.username} · נמחק` : user.username;
    const balance = document.createElement("span"); balance.className = "font-bold text-gold"; balance.textContent = `₪${money(user.balance)}`; head.append(name,balance); card.append(head);
    const meta = document.createElement("p"); meta.className = "mb-3 text-xs text-mist"; meta.textContent = `הימורים פתוחים: ${user.pending_bets}`; card.append(meta);
    if (!user.is_deleted) {
      const actionDetails = document.createElement("details"); actionDetails.className = "mt-3 rounded-xl border border-slate-700/60 bg-ink/30 p-2";
      const actionSummary = document.createElement("summary"); actionSummary.className = "cursor-pointer list-none px-2 py-2 text-sm font-bold text-slate-200"; actionSummary.textContent = "פעולות משתמש ▾";
      const actions = document.createElement("div"); actions.className = "mt-2 grid grid-cols-2 gap-2";
      const reset = document.createElement("button"); reset.className = "rounded-xl bg-gold px-3 py-2 text-sm font-bold text-ink"; reset.textContent = "איפוס ל־1,000 ₪";
      reset.addEventListener("click", async () => { if (!confirm(`לאפס את היתרה של ${user.username} ל־1,000 ₪? ההימורים הפתוחים יישארו ללא שינוי.`)) return; const r=await supabase.rpc("admin_set_balance",{p_user_id:user.id,p_balance:1000,p_reason:"reset_to_1000"}); if(r.error) toast(cleanError(r.error),"error"); else { toast("היתרה אופסה; ההימורים נשארו ללא שינוי"); refreshAdmin(); refreshBoard(); } });
      const manual = document.createElement("button"); manual.className = "rounded-xl border border-slate-600 px-3 py-2 text-sm"; manual.textContent = "קביעת יתרה";
      manual.addEventListener("click", async () => { const raw=prompt(`יתרה חדשה עבור ${user.username}:`,String(user.balance)); if(raw===null)return; const amount=Number(raw); if(!Number.isFinite(amount)||amount<0){toast("סכום לא תקין","error");return;} const r=await supabase.rpc("admin_set_balance",{p_user_id:user.id,p_balance:amount,p_reason:"manual_adjustment"}); if(r.error)toast(cleanError(r.error),"error");else{toast("היתרה עודכנה");refreshAdmin();refreshBoard();} });
      const history = document.createElement("button"); history.className = "rounded-xl border border-slate-600 px-3 py-2 text-sm"; history.textContent = "היסטוריית הימורים";
      history.addEventListener("click", async () => { const r=await supabase.rpc("admin_user_bets",{p_user_id:user.id}); if(r.error){toast(cleanError(r.error),"error");return;} const lines=(r.data||[]).slice(0,12).map(b=>`#${b.id} · ₪${money(b.bet_amount)} · ${b.status} · יחס ${b.odds}`).join("\n"); alert(lines||"אין הימורים למשתמש זה"); });
      const del = document.createElement("button"); del.className = "rounded-xl border border-rose-500/50 px-3 py-2 text-sm text-rose-300"; del.textContent = "מחיקת משתמש";
      del.addEventListener("click", async () => { if(!confirm(`לסמן את ${user.username} כמחוק? היסטוריית ההימורים תישמר והוא יוסתר מהטבלה.`))return; const r=await supabase.rpc("admin_soft_delete_user",{p_user_id:user.id}); if(r.error)toast(cleanError(r.error),"error");else{toast("המשתמש סומן כמחוק וההיסטוריה נשמרה");refreshAdmin();refreshBoard();} });
      actions.append(reset,manual,history,del); actionDetails.append(actionSummary,actions); card.append(actionDetails);
    }
    root.append(card);
  });
  const auditTitle = document.createElement("h3"); auditTitle.className = "mb-2 mt-6 text-lg font-bold"; auditTitle.textContent = "יומן פעולות מנהל"; root.append(auditTitle);
  const audit = await supabase.rpc("admin_recent_audit");
  if (!audit.error) {
    (audit.data || []).slice(0,20).forEach(entry => {
      const row=document.createElement("p"); row.className="mb-1 rounded-xl bg-ink/60 px-3 py-2 text-xs text-mist";
      const date=new Date(entry.created_at).toLocaleString("he-IL");
      const details=entry.details||{};
      const description=entry.action==="set_balance" ? `יתרה: ${details.old_balance} ← ${details.new_balance} ₪` : "משתמש סומן כמחוק";
      row.textContent=`${date} · ${description}`; root.append(row);
    });
  }
}

async function refreshProfile() {
  const { data, error } = await supabase.from("profiles").select("username, balance, is_deleted").eq("id", state.user.id).single();
  if (error) {
    toast(cleanError(error), "error");
    return;
  }
  if (data.is_deleted) { toast("החשבון אינו פעיל", "error"); await supabase.auth.signOut(); return; }
  $("hello").textContent = data.username;
  setBalance(data.balance);
}

async function refreshAll() {
  if (state.refreshing) return;
  state.refreshing = true;
  const button = $("refresh");
  if (button) button.disabled = true;
  try {
    await Promise.all([refreshProfile(), refreshGames(), refreshBets(), refreshBoard()]);
  } finally {
    state.refreshing = false;
    if (button) button.disabled = false;
  }
}

function subscribe() {
  if (state.channel) supabase.removeChannel(state.channel);
  let gameTimer;
  let betTimer;
  let boardTimer;
  state.channel = supabase
    .channel(`mw-${state.user.id}`)
    .on("postgres_changes", { event: "*", schema: "public", table: "games" }, () => {
      clearTimeout(gameTimer);
      gameTimer = setTimeout(refreshGames, 250);
    })
    .on("postgres_changes", { event: "*", schema: "public", table: "winner_markets" }, () => {
      clearTimeout(gameTimer);
      gameTimer = setTimeout(refreshGames, 250);
    })
    .on("postgres_changes", { event: "*", schema: "public", table: "bets", filter: `user_id=eq.${state.user.id}` }, () => {
      clearTimeout(betTimer);
      betTimer = setTimeout(refreshBets, 250);
    })
    .on("postgres_changes", { event: "UPDATE", schema: "public", table: "profiles", filter: `id=eq.${state.user.id}` }, (payload) => {
      if (payload.new?.is_deleted) {
        toast("החשבון אינו פעיל", "error");
        void supabase.auth.signOut();
        return;
      }
      if (payload.new && payload.new.balance != null) setBalance(payload.new.balance);
    })
    .on("postgres_changes", { event: "*", schema: "public", table: "profiles" }, () => {
      clearTimeout(boardTimer);
      boardTimer = setTimeout(refreshBoard, 300);
    })
    .subscribe();
}

async function enterApp(session) {
  if (state.user?.id === session.user.id) return;
  state.user = session.user;
  state.settledBadgeInitialized = false;
  state.archiveGames = [];
  state.archiveOffset = 0;
  state.archiveHasMore = false;
  $("auth-view").classList.add("hidden");
  $("app-view").classList.remove("hidden");
  const ensured = await supabase.rpc("ensure_profile");
  if (ensured.error) toast(cleanError(ensured.error), "error");
  const adminCheck = await supabase.rpc("admin_is_admin");
  state.isAdmin = !adminCheck.error && adminCheck.data === true;
  $("admin-nav").classList.toggle("hidden", !state.isAdmin);
  $("admin-nav").classList.toggle("flex", state.isAdmin);
  $("nav-items").classList.toggle("grid-cols-5", state.isAdmin);
  $("nav-items").classList.toggle("grid-cols-4", !state.isAdmin);
  const inviteUrl = new URL(location.href);
  const inviteCode = inviteUrl.searchParams.get("join");
  if (inviteCode) {
    const joined = await supabase.rpc("groups_join", { p_invite_code: inviteCode, p_group_id: null });
    inviteUrl.searchParams.delete("join");
    history.replaceState({}, "", inviteUrl.toString());
    if (joined.error) toast(cleanError(joined.error), "error");
    else toast("הצטרפת לקבוצה בהצלחה");
  }
  await refreshAll();
  subscribe();
  if (!state.clock) state.clock = setInterval(() => { if (state.tab === "games") renderGames(); }, 30000);
}

function leaveApp() {
  if (state.channel) supabase.removeChannel(state.channel);
  if (state.clock) clearInterval(state.clock);
  state.clock = null;
  state.channel = null;
  state.user = null;
  state.settledBadgeInitialized = false;
  state.archiveGames = [];
  state.archiveOffset = 0;
  state.archiveHasMore = false;
  state.isAdmin = false;
  $("admin-nav").classList.add("hidden");
  state.slip = [];
  state.slipOpen = false;
  renderSlip();
  $("app-view").classList.add("hidden");
  $("auth-view").classList.remove("hidden");
  closeSheet();
}

function setAuthMode(mode) {
  state.mode = mode;
  const signup = mode === "signup";
  $("username-wrap").classList.toggle("hidden", !signup);
  $("tab-signup").className = signup ? "rounded-xl bg-gold py-2 font-bold text-ink" : "rounded-xl py-2 font-medium text-slate-300";
  $("tab-login").className = signup ? "rounded-xl py-2 font-medium text-slate-300" : "rounded-xl bg-gold py-2 font-bold text-ink";
  $("auth-submit").textContent = signup ? "יצירת חשבון" : "כניסה";
  $("password").autocomplete = signup ? "new-password" : "current-password";
}

async function submitAuth(event) {
  event.preventDefault();
  const email = $("email").value.trim();
  const password = $("password").value;
  const username = $("username").value.trim();
  if (state.mode === "signup" && username.length < 2) {
    toast("בחרו שם משתמש של 2 תווים לפחות", "error");
    return;
  }
  $("auth-submit").disabled = true;
  try {
    if (state.mode === "signup") {
      const { data, error } = await supabase.auth.signUp({ email, password, options: { data: { username } } });
      if (error) {
        toast(cleanError(error), "error");
        return;
      }
      if (!data.session) {
        const signIn = await supabase.auth.signInWithPassword({ email, password });
        if (signIn.error) {
          toast("החשבון נוצר. אשרו את האימייל ואז התחברו.", "error");
          setAuthMode("login");
          return;
        }
      }
      toast("החשבון מוכן. יתרת פתיחה: ₪1,000.00");
    } else {
      const { error } = await supabase.auth.signInWithPassword({ email, password });
      if (error) toast(cleanError(error), "error");
    }
  } finally {
    $("auth-submit").disabled = false;
  }
}

async function cancelBet(bet) {
  if (!canCancel(bet) || state.submitting) return;
  const approved = window.confirm("לבטל את ההימור ולהחזיר את הסכום ליתרה?");
  if (!approved) return;
  state.submitting = true;
  try {
    const { data, error } = await supabase.rpc("cancel_bet", { p_bet_id: Number(bet.id) });
    if (error) {
      toast(cleanError(error), "error");
      return;
    }
    setBalance(data.balance);
    toast(`ההימור בוטל והסכום הוחזר · יתרה ₪${money(data.balance)}`);
    await refreshBets();
  } finally {
    state.submitting = false;
  }
}

function roundMoney(value) {
  return Math.round(Number(value) * 100) / 100;
}

async function submitTicket(legs, amount) {
  const { data, error } = await supabase.rpc("place_parlay", {
    p_legs: legs.map((leg) => leg.marketId
      ? { game_id: leg.gameId, market_id: leg.marketId, market_selection: leg.marketSelection }
      : { game_id: leg.gameId, selection: leg.selection }),
    p_amount: amount,
  });
  if (error) return { error };
  return { data };
}

async function placeSlip() {
  if (!state.slip.length || state.submitting) return;
  const combined = state.slipTab === "combined";
  const tickets = combined
    ? [{ legs: state.slip, amount: roundMoney($("slip-stake").value) }]
    : state.slip.map((leg) => ({ legs: [leg], amount: roundMoney(leg.stake) }));
  if (tickets.some((ticket) => !Number.isFinite(ticket.amount) || ticket.amount <= 0)) {
    toast("הזינו סכום גדול מאפס", "error");
    return;
  }
  const needed = tickets.reduce((sum, ticket) => sum + ticket.amount, 0);
  if (roundMoney(needed) > state.balance) {
    toast("יתרה לא מספיקה", "error");
    return;
  }
  state.submitting = true;
  $("slip-confirm").disabled = true;
  const placed = new Set();
  try {
    for (const ticket of tickets) {
      const { data, error } = await submitTicket(ticket.legs, ticket.amount);
      if (error) {
        toast(cleanError(error), "error");
        break;
      }
      ticket.legs.forEach((leg) => placed.add(leg.gameId));
      setBalance(data.balance);
      const totalOdds = Number(data.total_odds ?? data.odds);
      toast(`נקלט · יחס ${totalOdds.toFixed(2)} · ₪${money(data.potential_payout)}`);
    }
    state.slip = state.slip.filter((leg) => !placed.has(leg.gameId));
    if (!state.slip.length) state.slipOpen = false;
    renderSlip();
    renderGames();
    if (placed.size) await refreshBets();
  } finally {
    state.submitting = false;
    $("slip-confirm").disabled = false;
  }
}

async function placeBet() {
  if (!state.selected || state.submitting) return;
  const amount = Number($("stake").value);
  if (!Number.isFinite(amount) || amount <= 0) {
    toast("הזינו סכום גדול מאפס", "error");
    return;
  }
  const rounded = Math.round(amount * 100) / 100;
  const available = state.selected.betId ? state.balance + state.selected.originalAmount : state.balance;
  if (rounded > available) {
    toast("יתרה לא מספיקה", "error");
    return;
  }
  state.submitting = true;
  $("sheet-confirm").disabled = true;
  try {
    const { data, error } = state.selected.betId
      ? await supabase.rpc("edit_bet", {
          p_bet_id: Number(state.selected.betId),
          p_selection: state.selected.selection,
          p_amount: rounded,
        })
      : state.selected.marketId
        ? await supabase.rpc("place_market_bet", {
            p_market_id: Number(state.selected.marketId),
            p_selection: state.selected.marketSelection,
            p_amount: rounded,
          })
        : await supabase.rpc("place_bet", {
            p_game_id: Number(state.selected.id),
            p_selection: state.selected.selection,
            p_amount: rounded,
          });
    if (error) {
      toast(cleanError(error), "error");
      return;
    }
    setBalance(data.balance);
    toast(state.selected.betId
      ? `ההימור ${data.bet_id} עודכן · יתרה ₪${money(data.balance)} · תשלום אפשרי ₪${money(data.potential_payout)}`
      : `ההימור נקלט ביחס ${Number(data.odds).toFixed(2)} · תשלום אפשרי ₪${money(data.potential_payout)}`);
    closeSheet();
    await refreshBets();
  } finally {
    state.submitting = false;
    $("sheet-confirm").disabled = false;
  }
}

function registerServiceWorker() {
  if ("serviceWorker" in navigator) {
    navigator.serviceWorker.register("./sw.js").catch(() => {});
  }
}

$("tab-login").addEventListener("click", () => setAuthMode("login"));
$("tab-signup").addEventListener("click", () => setAuthMode("signup"));
$("auth-form").addEventListener("submit", submitAuth);
$("logout").addEventListener("click", () => supabase.auth.signOut());
$("refresh").addEventListener("click", () => refreshAll().then(() => toast("הנתונים עודכנו")));
document.querySelectorAll(".nav-btn").forEach((button) => button.addEventListener("click", () => showTab(button.dataset.tab)));
document.querySelectorAll(".league-tab").forEach((button) => button.addEventListener("click", () => {
  state.league = button.dataset.league;
  paintLeagueTabs();
  button.scrollIntoView({ behavior: "smooth", block: "nearest", inline: "center" });
  renderGames();
}));
$("team-search").addEventListener("input", () => {
  state.query = $("team-search").value;
  renderGames();
});
document.querySelectorAll(".stake").forEach((button) => button.addEventListener("click", () => {
  $("stake").value = button.dataset.stake;
  updatePayout();
}));
$("stake").addEventListener("input", updatePayout);
$("sheet-cancel").addEventListener("click", closeSheet);
$("sheet").addEventListener("click", (event) => event.stopPropagation());
$("sheet-backdrop").addEventListener("click", closeSheet);
$("sheet-confirm").addEventListener("click", placeBet);
$("slip-toggle").addEventListener("click", () => {
  state.slipOpen = true;
  renderSlip();
});
$("slip-drawer").addEventListener("click", (event) => event.stopPropagation());
$("slip-close").addEventListener("click", () => { state.slipOpen = false; renderSlip(); });
$("slip-backdrop").addEventListener("click", () => {
  state.slipOpen = false;
  renderSlip();
});
$("slip-tab-combined").addEventListener("click", () => {
  state.slipTab = "combined";
  renderSlip();
});
$("slip-tab-singles").addEventListener("click", () => {
  state.slipTab = "singles";
  renderSlip();
});
$("slip-clear").addEventListener("click", () => {
  state.slip = [];
  state.slipOpen = false;
  renderSlip();
  renderGames();
});
$("slip-stake").addEventListener("input", renderSlip);
$("slip-confirm").addEventListener("click", placeSlip);


// Winner sync is handled by the extension content script directly through authenticated Supabase RPC.

function updateNetworkStatus() {
  const banner = $("network-status");
  if (!banner) return;
  const offline = !navigator.onLine;
  banner.classList.toggle("hidden", !offline);
  banner.textContent = offline ? "אין חיבור לאינטרנט · מוצגים רק נתונים שמורים" : "";
}
window.addEventListener("offline", updateNetworkStatus);
window.addEventListener("online", updateNetworkStatus);
updateNetworkStatus();

registerServiceWorker();
initVisualPreferences();
supabase.auth.onAuthStateChange((event, session) => {
  if (session?.user) enterApp(session);
  else if (event !== "INITIAL_SESSION") leaveApp();
});
supabase.auth.getSession().then(({ data }) => {
  if (data.session) enterApp(data.session);
});
