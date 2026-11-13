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
  expandedMarketKey: null,
  adminSection: "home",
  adminSelectedUserId: null,
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
  if (state.tab !== tab) {
    if (state.selected) closeSheet();
    if (state.slipOpen) {
      state.slipOpen = false;
      renderSlip();
    }
  }
  if (tab === "admin" && state.tab !== "admin") { state.adminSection = "home"; state.adminSelectedUserId = null; }
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
    .filter((game) => !query || (String(game.home_team || "") + " " + String(game.away_team || "")).toLowerCase().includes(query))
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
    count.textContent = state.archiveGames.length + " משחקים נטענו";
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
    const gameId = Number(game.id);
    const expanded = !isArchive && state.expandedGameId === gameId;
    const card = document.createElement("article");
    card.className = "game-card mb-2 overflow-hidden rounded-2xl border border-slate-700/60 bg-panel shadow-lg" + (expanded ? " is-expanded" : "");

    const body = document.createElement("div");
    body.className = "game-card-body";

    const head = document.createElement("div");
    head.className = "game-match-meta-row";
    const time = document.createElement("span");
    const countdown = !isArchive ? countdownLabel(game) : "";
    time.className = "game-match-time";
    time.textContent = [when(game.match_time), countdown].filter(Boolean).join(" · ");

    const badge = document.createElement("span");
    badge.className = game.status === "live"
      ? "game-status is-live"
      : game.status === "finished"
        ? "game-status is-finished"
        : "game-status";
    const liveLabel = game.live_status_text === "HT"
      ? "מחצית"
      : game.live_status_text
        ? "● חי · " + game.live_status_text + "׳"
        : "● חי";
    badge.textContent = game.status === "live" ? liveLabel : (GAME_STATUS[game.status] || game.status);

    const matchToggle = document.createElement(isArchive ? "div" : "button");
    if (!isArchive) {
      matchToggle.type = "button";
      matchToggle.className = "game-match-toggle";
      matchToggle.setAttribute("aria-expanded", expanded ? "true" : "false");
      matchToggle.setAttribute("aria-label", (expanded ? "סגירת" : "פתיחת") + " הימורים: " + game.home_team + " נגד " + game.away_team);
    } else {
      matchToggle.className = "game-match-toggle is-static";
    }

    const metaRow = document.createElement("div");
    metaRow.className = "game-match-meta-row";
    metaRow.append(time, badge);
    const chevron = document.createElement("span");
    chevron.className = "game-match-chevron";
    chevron.textContent = expanded ? "⌃" : "⌄";
    if (!isArchive) metaRow.append(chevron);

    const teams = document.createElement("div");
    teams.className = "game-teams-row";
    teams.dir = "rtl";

    const home = document.createElement("div");
    home.className = "game-team-inline";
    const homeName = document.createElement("span");
    homeName.className = "game-team-name";
    homeName.textContent = game.home_team || "קבוצה ביתית";
    home.append(homeName, flag(game.home_flag));

    const away = document.createElement("div");
    away.className = "game-team-inline away";
    away.append(flag(game.away_flag));
    const awayName = document.createElement("span");
    awayName.className = "game-team-name";
    awayName.textContent = game.away_team || "קבוצת חוץ";
    away.append(awayName);

    const score = document.createElement("span");
    score.className = "game-versus";
    score.dir = "ltr";
    score.textContent = game.status === "live" || game.status === "finished"
      ? game.away_score + " - " + game.home_score
      : "VS";
    teams.append(home, score, away);
    matchToggle.append(metaRow, teams);

    if (!isArchive) {
      matchToggle.addEventListener("click", () => {
        state.expandedGameId = expanded ? null : gameId;
        state.expandedMarketKey = null;
        renderGames();
      });
    }
    body.append(matchToggle);
    card.append(body);

    const enabledMarkets = isArchive ? [] : state.gameMarkets.filter((market) =>
      Number(market.game_id) === gameId &&
      market.active !== false &&
      state.marketSettings[market.market_key] !== false
    );
    const canPlaceBet = !isArchive &&
      game.status === "upcoming" &&
      new Date(game.match_time).getTime() > Date.now() + 5 * 60 * 1000;
    const hasMainOdds = !isArchive && [game.home_odds, game.draw_odds, game.away_odds]
      .some((value) => Number(value) >= 1.01);

    if (expanded) {
      const panel = document.createElement("div");
      panel.className = "game-expanded-panel";

      const mainOdds = document.createElement("section");
      mainOdds.className = "game-main-odds";
      const title = document.createElement("h3");
      title.className = "game-main-odds-title";
      title.textContent = "תוצאת המשחק";
      mainOdds.append(title);

      if (hasMainOdds) {
        const grid = document.createElement("div");
        grid.className = "game-main-odds-grid";
        [["1", game.home_odds, "1 · בית"], ["X", game.draw_odds, "X · תיקו"], ["2", game.away_odds, "2 · חוץ"]]
          .forEach(([selection, price, label]) => {
            const numericPrice = Number(price);
            const picked = state.slip.some((leg) => leg.gameId === gameId && !leg.marketId && leg.selection === selection);
            const button = document.createElement("button");
            button.type = "button";
            button.disabled = !canPlaceBet || !Number.isFinite(numericPrice) || numericPrice < 1.01;
            button.setAttribute("aria-pressed", picked ? "true" : "false");
            button.className = "game-odds-button" + (picked ? " is-picked" : "");
            const outcomeLabel = document.createElement("span");
            outcomeLabel.className = "game-odds-label";
            outcomeLabel.textContent = label;
            const value = document.createElement("strong");
            value.className = "game-odds-value";
            value.dir = "ltr";
            value.textContent = numericPrice >= 1.01 ? numericPrice.toFixed(2) : "—";
            button.append(outcomeLabel, value);
            if (!button.disabled) button.addEventListener("click", () => toggleSlip(game, selection, numericPrice));
            grid.append(button);
          });
        mainOdds.append(grid);
      } else {
        const unavailable = document.createElement("p");
        unavailable.className = "game-no-odds";
        unavailable.textContent = "אין כרגע יחסים זמינים לתוצאת המשחק";
        mainOdds.append(unavailable);
      }
      panel.append(mainOdds);

      enabledMarkets.forEach((market) => {
        const marketKey = gameId + ":" + market.id;
        const marketExpanded = state.expandedMarketKey === marketKey;
        const group = document.createElement("section");
        group.className = "game-market-group";

        const marketToggle = document.createElement("button");
        marketToggle.type = "button";
        marketToggle.className = "game-market-toggle";
        marketToggle.setAttribute("aria-expanded", marketExpanded ? "true" : "false");
        const marketTitle = document.createElement("span");
        marketTitle.textContent = market.market_key === "handicap_ft" && market.line != null
          ? (market.market_label || "הפרשי שערים") + " (" + (Number(market.line) > 0 ? "+" : "") + Number(market.line) + ")"
          : market.market_label || "אפשרויות הימור";
        const marketChevron = document.createElement("span");
        marketChevron.className = "game-market-chevron";
        marketChevron.textContent = marketExpanded ? "⌃" : "⌄";
        marketToggle.append(marketTitle, marketChevron);
        marketToggle.addEventListener("click", () => {
          state.expandedMarketKey = marketExpanded ? null : marketKey;
          renderGames();
        });
        group.append(marketToggle);

        if (marketExpanded) {
          const outcomes = Array.isArray(market.outcomes) ? market.outcomes : [];
          const grid = document.createElement("div");
          grid.className = "game-market-outcomes";
          outcomes.forEach((outcome) => {
            const price = Number(outcome.price);
            const button = document.createElement("button");
            button.type = "button";
            button.disabled = !canPlaceBet || !Number.isFinite(price) || price < 1.01;
            const picked = state.slip.some((leg) => leg.gameId === gameId && Number(leg.marketId) === Number(market.id) && leg.marketSelection === outcome.selection);
            button.setAttribute("aria-pressed", picked ? "true" : "false");
            button.className = "game-odds-button game-secondary-odds" + (picked ? " is-picked" : "");
            const label = document.createElement("span");
            label.className = "game-odds-label";
            label.textContent = outcome.label || outcome.selection;
            const value = document.createElement("strong");
            value.className = "game-odds-value";
            value.dir = "ltr";
            value.textContent = Number.isFinite(price) ? price.toFixed(2) : "—";
            button.append(label, value);
            if (!button.disabled) button.addEventListener("click", () => toggleMarketSlip(game, market, outcome));
            grid.append(button);
          });
          group.append(grid);
        }
        panel.append(group);
      });

      if (!enabledMarkets.length) {
        const none = document.createElement("p");
        none.className = "game-no-odds";
        none.textContent = "אין שווקים נוספים זמינים למשחק הזה";
        panel.append(none);
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

  const settledBets = historyBets.filter((bet) => ["won", "lost", "void"].includes(bet.status));
  const totalNet = settledBets.reduce((total, bet) => {
    const stake = Number(bet.bet_amount) || 0;
    if (bet.status === "won") return total + (Number(bet.potential_payout) || 0) - stake;
    if (bet.status === "lost") return total - stake;
    return total;
  }, 0);
  const appendSummary = () => {
    const panel = document.createElement("section");
    panel.className = "mt-5 mb-4 flex items-center justify-between gap-3 rounded-2xl border border-slate-600/80 bg-[#1b2b40] px-4 py-4 shadow-lg";
    const label = document.createElement("div");
    label.className = "min-w-0";
    const title = document.createElement("p");
    title.className = "text-sm font-bold text-slate-100";
    title.textContent = "סיכום ההימורים";
    const count = document.createElement("p");
    count.className = "mt-1 text-xs text-slate-400";
    count.textContent = `${settledBets.length} הימורים הסתיימו`;
    label.append(title, count);
    const total = document.createElement("div");
    total.className = "shrink-0 text-left";
    const totalLabel = document.createElement("p");
    totalLabel.className = "text-xs text-slate-400";
    totalLabel.textContent = totalNet > 0 ? "רווח כולל" : totalNet < 0 ? "הפסד כולל" : "מאזן כולל";
    const amount = document.createElement("strong");
    amount.className = `mt-1 block text-xl font-extrabold tabular-nums ${totalNet > 0 ? "text-emerald-300" : totalNet < 0 ? "text-rose-300" : "text-slate-200"}`;
    amount.textContent = `${totalNet > 0 ? "+" : totalNet < 0 ? "−" : ""}₪${money(Math.abs(totalNet))}`;
    total.append(totalLabel, amount);
    panel.append(label, total);
    root.append(panel);
  };
  tabs.querySelectorAll("button").forEach((button, index) => {
    const key = filters[index][0];
    if (key === "pending") button.textContent = `פתוחים · ${counts.pending}`;
    if (key === "settled") button.textContent = `הסתיימו · ${counts.settled}`;
  });

  if (!visible.length) {
    const placeholder = document.createElement("p");
    placeholder.className = "rounded-2xl border border-dashed border-slate-700/50 px-4 py-10 text-center text-sm text-mist";
    placeholder.textContent = historyBets.length ? "אין הימורים בקטגוריה הזו" : "עדיין אין הימורים";
    root.append(placeholder);
    appendSummary();
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
    metrics.className = "mt-3 grid grid-cols-3 items-center gap-2 border-t border-slate-700/60 bg-[#152238] px-4 py-3";
    const stake = document.createElement("div");
    stake.innerHTML = '<span class="block text-[11px] text-slate-400">סכום הימור</span>';
    const stakeValue = document.createElement("strong");
    stakeValue.className = "mt-0.5 block text-base font-extrabold text-slate-100";
    stakeValue.textContent = `₪${money(bet.bet_amount)}`;
    stake.append(stakeValue);

    const oddsBox = document.createElement("div");
    oddsBox.className = "text-center";
    oddsBox.innerHTML = `<span class="block text-[11px] text-slate-400">${combined ? "יחס משולב" : "יחס"}</span>`;
    const oddsValue = document.createElement("strong");
    oddsValue.className = "mt-0.5 block text-base font-semibold text-slate-100";
    oddsValue.textContent = Number(bet.odds).toFixed(2);
    oddsBox.append(oddsValue);

    const resultBox = document.createElement("div");
    resultBox.className = "text-left";
    const resultLabel = document.createElement("span");
    resultLabel.className = "block text-[11px] text-slate-400";
    const resultValue = document.createElement("strong");
    resultValue.className = "mt-1 inline-flex max-w-full items-center justify-center whitespace-nowrap rounded-lg px-2 py-1 text-sm font-bold leading-tight tabular-nums";
    resultValue.dir = "ltr";
    const stakeAmount = Number(bet.bet_amount) || 0;
    const payoutAmount = Number(bet.potential_payout) || 0;
    if (bet.status === "won") {
      const net = payoutAmount - stakeAmount;
      resultLabel.textContent = "רווח נטו";
      resultValue.className += net >= 0 ? " bg-emerald-500/20 text-emerald-300" : " bg-rose-500/20 text-rose-300";
      resultValue.textContent = `${net >= 0 ? "+" : "−"}₪${money(Math.abs(net))}`;
    } else if (bet.status === "lost") {
      resultLabel.textContent = "הפסד נטו";
      resultValue.className += " bg-rose-500/20 text-rose-300";
      resultValue.textContent = `−₪${money(stakeAmount)}`;
    } else if (bet.status === "void") {
      resultLabel.textContent = "החזר";
      resultValue.className += " bg-slate-500/20 text-slate-300";
      resultValue.textContent = `₪${money(0)}`;
    } else {
      resultLabel.textContent = "רווח אפשרי";
      resultValue.className += " bg-amber-400/15 text-amber-200";
      resultValue.textContent = `+₪${money(Math.max(0, payoutAmount - stakeAmount))}`;
    }
    resultBox.append(resultLabel, resultValue);
    metrics.append(stake, oddsBox, resultBox);
    card.append(metrics);

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

  appendSummary();
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
    const placeholder = document.createElement("p");
    placeholder.className = "rounded-2xl border border-dashed border-slate-700/50 px-4 py-8 text-center text-sm text-mist";
    placeholder.textContent = "עדיין אין שחקנים בקבוצה הזו";
    root.append(placeholder);
    return;
  }

  const table = document.createElement("div");
  table.className = "overflow-hidden rounded-2xl border border-slate-700/50 bg-panel shadow-sm";
  const headerRow = document.createElement("div");
  headerRow.className = "grid grid-cols-[2.5rem_minmax(0,1fr)_auto] items-center gap-2 border-b border-slate-700/40 bg-ink/40 px-3 py-3 text-xs font-bold text-slate-400";
  const rankHeading = document.createElement("span");
  rankHeading.textContent = "#";
  const userHeading = document.createElement("span");
  userHeading.textContent = "משתמש";
  const profitHeading = document.createElement("span");
  profitHeading.className = "text-left";
  profitHeading.textContent = "רווח / הפסד מהימורים שהסתיימו";
  headerRow.append(rankHeading, userHeading, profitHeading);
  table.append(headerRow);

  state.board.forEach((row, index) => {
    const mine = row.id === state.user?.id;
    const net = Number(row.net_profit || 0);
    const line = document.createElement("div");
    line.className = `grid grid-cols-[2.5rem_minmax(0,1fr)_auto] items-center gap-2 border-b border-slate-700/30 px-3 py-3 last:border-b-0 ${mine ? "bg-gold/10" : ""}`;

    const rank = document.createElement("span");
    rank.className = "text-center text-sm font-bold text-slate-400";
    rank.textContent = String(index + 1);

    const username = document.createElement("span");
    username.className = "min-w-0 truncate text-sm font-semibold text-slate-100";
    username.textContent = row.username + (mine ? " · אתה" : "");

    const result = document.createElement("strong");
    result.className = `whitespace-nowrap text-left text-sm font-extrabold tabular-nums ${net > 0 ? "text-emerald-400" : net < 0 ? "text-rose-400" : "text-slate-300"}`;
    result.dir = "ltr";
    result.textContent = `${net > 0 ? "+" : net < 0 ? "−" : ""}₪${money(Math.abs(net))}`;

    line.append(rank, username, result);
    table.append(line);
  });
  root.append(table);

  const note = document.createElement("p");
  note.className = "mt-2 text-[11px] text-slate-400";
  note.textContent = "מוצגים רק רווחים והפסדים מהימורים שהסתיימו. הימורים פתוחים אינם נכללים.";
  root.append(note);
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
  const gamesVisible = state.tab === "games" || state.tab === "archive";
  if (!state.slip.length) {
    slip.classList.add("hidden");
    backdrop.classList.add("hidden");
    state.slipOpen = false;
    app.classList.remove("pb-44");
    app.classList.add("pb-28");
    return;
  }
  // Keep the selected legs, but show the floating slip dock only on games/archive.
  slip.classList.toggle("hidden", !gamesVisible);
  if (gamesVisible) {
    app.classList.remove("pb-28");
    app.classList.add("pb-44");
  } else {
    app.classList.remove("pb-44");
    app.classList.add("pb-28");
  }
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

function adminHeader(root, titleText, backSection = "home") {
  const header = document.createElement("div");
  header.className = "mb-4 flex items-center gap-3";
  const back = document.createElement("button");
  back.type = "button";
  back.className = "flex h-10 w-10 shrink-0 items-center justify-center rounded-xl border border-slate-600/60 bg-panel text-lg";
  back.textContent = "→";
  back.setAttribute("aria-label", "חזרה לניהול");
  back.addEventListener("click", () => {
    if (state.adminSection === "users" && state.adminSelectedUserId) {
      state.adminSelectedUserId = null;
    } else {
      state.adminSection = backSection;
    }
    refreshAdmin();
  });
  const title = document.createElement("h2");
  title.className = "text-xl font-extrabold text-gold";
  title.textContent = titleText;
  header.append(back, title);
  root.append(header);
}

function adminSectionButton(root, title, subtitle, icon, section) {
  const button = document.createElement("button");
  button.type = "button";
  button.className = "admin-section-card";
  const symbol = document.createElement("span");
  symbol.className = "admin-section-icon";
  symbol.textContent = icon;
  const copy = document.createElement("span");
  copy.className = "min-w-0 flex-1 text-right";
  const heading = document.createElement("strong");
  heading.className = "block text-base font-extrabold";
  heading.textContent = title;
  const description = document.createElement("span");
  description.className = "mt-1 block text-xs text-mist";
  description.textContent = subtitle;
  copy.append(heading, description);
  const arrow = document.createElement("span");
  arrow.className = "text-xl text-gold";
  arrow.textContent = "←";
  button.append(symbol, copy, arrow);
  button.addEventListener("click", () => {
    state.adminSection = section;
    state.adminSelectedUserId = null;
    refreshAdmin();
  });
  root.append(button);
}

async function renderAdminHome(root) {
  const heading = document.createElement("h2");
  heading.className = "mb-1 text-2xl font-extrabold text-gold";
  heading.textContent = "מרכז ניהול";
  const intro = document.createElement("p");
  intro.className = "mb-4 text-sm text-mist";
  intro.textContent = "בחר אזור לניהול ולבקרה";
  root.append(heading, intro);

  const [users, requests, games] = await Promise.all([
    supabase.rpc("admin_list_users"),
    supabase.rpc("admin_recent_api_requests", { p_limit: 100 }),
    supabase.from("games").select("id", { count: "exact", head: true })
  ]);
  const userRows = Array.isArray(users.data) ? users.data : [];
  const requestRows = Array.isArray(requests.data) ? requests.data : [];
  const failed = requestRows.filter((row) => Number(row.status_code) >= 400).length;
  const stats = document.createElement("div");
  stats.className = "mb-5 grid grid-cols-3 gap-2";
  [
    [userRows.length, "משתמשים"],
    [games.count ?? "—", "משחקים"],
    [failed, "פניות שנכשלו"]
  ].forEach(([value, label]) => {
    const tile = document.createElement("div");
    tile.className = "rounded-xl border border-slate-700/50 bg-panel p-3 text-center";
    const number = document.createElement("strong");
    number.className = "block text-xl font-extrabold text-gold";
    number.textContent = String(value);
    const caption = document.createElement("span");
    caption.className = "mt-1 block text-[11px] text-mist";
    caption.textContent = label;
    tile.append(number, caption);
    stats.append(tile);
  });
  root.append(stats);
  adminSectionButton(root, "בקרה", "תמונת מצב של המערכת", "◉", "control");
  adminSectionButton(root, "משתמשים", "רשימה קצרה ופעולות משתמש", "♙", "users");
  adminSectionButton(root, "שווקים", "הפעלה והסתרה של סוגי הימורים", "▦", "markets");
  adminSectionButton(root, "הכרעות", "שווקים שממתינים לתוצאה", "✓", "settlements");
  adminSectionButton(root, "דוחות ריצות", "כל פנייה לספק, שעה, סטטוס ותשובה", "↻", "runs");
  adminSectionButton(root, "יומן מנהל", "מעקב אחר שינויים שבוצעו בניהול", "☷", "audit");
}

async function renderAdminControl(root) {
  adminHeader(root, "בקרה");
  const [requests, games, users] = await Promise.all([
    supabase.rpc("admin_recent_api_requests", { p_limit: 100 }),
    supabase.from("games").select("id", { count: "exact", head: true }),
    supabase.rpc("admin_list_users")
  ]);
  if (requests.error) {
    const warning = document.createElement("p");
    warning.className = "rounded-xl bg-rose-500/10 p-3 text-sm text-rose-300";
    warning.textContent = "לא ניתן לטעון נתוני ריצות: " + cleanError(requests.error);
    root.append(warning);
  }
  const rows = Array.isArray(requests.data) ? requests.data : [];
  const failed = rows.filter((row) => Number(row.status_code) >= 400);
  const success = rows.filter((row) => Number(row.status_code) >= 200 && Number(row.status_code) < 300);
  const last = rows[0];
  const tiles = document.createElement("div");
  tiles.className = "grid grid-cols-2 gap-3";
  [
    [String(Array.isArray(users.data) ? users.data.length : "—"), "משתמשים"],
    [String(games.count ?? "—"), "משחקים במערכת"],
    [String(success.length), "פניות מוצלחות · 100 אחרונות"],
    [String(failed.length), "פניות שנכשלו · 100 אחרונות"]
  ].forEach(([value, label]) => {
    const tile = document.createElement("div");
    tile.className = "rounded-2xl border border-slate-700/50 bg-panel p-4";
    const strong = document.createElement("strong");
    strong.className = "block text-2xl font-extrabold text-gold";
    strong.textContent = value;
    const caption = document.createElement("span");
    caption.className = "mt-1 block text-xs text-mist";
    caption.textContent = label;
    tile.append(strong, caption);
    tiles.append(tile);
  });
  root.append(tiles);
  const lastRun = document.createElement("div");
  lastRun.className = "mt-4 rounded-2xl border border-slate-700/50 bg-panel p-4";
  const lastTitle = document.createElement("h3");
  lastTitle.className = "mb-2 font-bold";
  lastTitle.textContent = "הפנייה האחרונה";
  const lastText = document.createElement("p");
  lastText.className = "text-sm text-mist";
  lastText.textContent = last
    ? new Date(last.called_at).toLocaleString("he-IL") + " · " + (last.purpose || last.endpoint) + " · HTTP " + (last.status_code ?? "—")
    : "עדיין אין פניות מתועדות";
  lastRun.append(lastTitle, lastText);
  root.append(lastRun);
  const go = document.createElement("button");
  go.type = "button";
  go.className = "mt-4 w-full rounded-xl bg-gold px-4 py-3 font-bold text-ink";
  go.textContent = "פתיחת דוחות ריצות";
  go.addEventListener("click", () => { state.adminSection = "runs"; refreshAdmin(); });
  root.append(go);
}

async function renderAdminUsers(root) {
  const { data, error } = await supabase.rpc("admin_list_users");
  if (error) { empty(root, cleanError(error)); return; }
  const users = Array.isArray(data) ? data : [];
  const selected = users.find((user) => String(user.id) === String(state.adminSelectedUserId));
  if (!selected) {
    adminHeader(root, "משתמשים");
    const note = document.createElement("p");
    note.className = "mb-3 text-xs text-mist";
    note.textContent = users.length + " משתמשים · לחיצה על שם פותחת פעולות";
    root.append(note);
    const list = document.createElement("div");
    list.className = "overflow-hidden rounded-2xl border border-slate-700/60 bg-panel";
    users.forEach((user) => {
      const row = document.createElement("button");
      row.type = "button";
      row.className = "flex w-full items-center justify-between gap-3 border-b border-slate-700/50 px-4 py-3 text-right last:border-b-0";
      const name = document.createElement("span");
      name.className = "min-w-0 truncate text-sm font-bold";
      name.textContent = (user.username || "ללא שם") + (user.is_deleted ? " · נמחק" : "");
      const balance = document.createElement("span");
      balance.className = "shrink-0 text-sm font-bold text-gold";
      balance.textContent = "₪" + money(user.balance);
      row.append(name, balance);
      row.addEventListener("click", () => { state.adminSelectedUserId = user.id; refreshAdmin(); });
      list.append(row);
    });
    root.append(list);
    return;
  }

  adminHeader(root, selected.username || "פרטי משתמש", "users");
  const info = document.createElement("div");
  info.className = "mb-4 rounded-2xl border border-slate-700/50 bg-panel p-4";
  const balance = document.createElement("p");
  balance.className = "text-lg font-extrabold text-gold";
  balance.textContent = "יתרה: ₪" + money(selected.balance);
  const pending = document.createElement("p");
  pending.className = "mt-1 text-xs text-mist";
  pending.textContent = "הימורים פתוחים: " + selected.pending_bets;
  info.append(balance, pending);
  root.append(info);
  if (selected.is_deleted) return;

  const actions = document.createElement("div");
  actions.className = "grid grid-cols-2 gap-2";
  const actionButton = (label, style, handler) => {
    const button = document.createElement("button");
    button.type = "button";
    button.className = style;
    button.textContent = label;
    button.addEventListener("click", handler);
    actions.append(button);
    return button;
  };
  actionButton("שינוי שם משתמש", "rounded-xl border border-gold/50 px-3 py-3 text-sm font-semibold text-gold", async (event) => {
    const nextName = prompt("שם משתמש חדש:", selected.username);
    if (nextName === null) return;
    const username = nextName.trim();
    if (username === selected.username) return;
    const result = await supabase.rpc("admin_update_username", { p_user_id: selected.id, p_username: username });
    if (result.error) { toast(cleanError(result.error), "error"); return; }
    toast("שם המשתמש עודכן");
    await refreshAdmin();
    await refreshBoard();
    await refreshProfile();
  });
  actionButton("איפוס ל־1,000 ₪", "rounded-xl bg-gold px-3 py-3 text-sm font-bold text-ink", async () => {
    if (!confirm("לאפס את היתרה של " + selected.username + " ל־1,000 ₪? ההימורים הפתוחים יישארו ללא שינוי.")) return;
    const result = await supabase.rpc("admin_set_balance", { p_user_id: selected.id, p_balance: 1000, p_reason: "reset_to_1000" });
    if (result.error) toast(cleanError(result.error), "error");
    else { toast("היתרה אופסה"); refreshAdmin(); refreshBoard(); }
  });
  actionButton("קביעת יתרה", "rounded-xl border border-slate-600 px-3 py-3 text-sm", async () => {
    const raw = prompt("יתרה חדשה:", String(selected.balance));
    if (raw === null) return;
    const amount = Number(raw);
    if (!Number.isFinite(amount) || amount < 0) { toast("סכום לא תקין", "error"); return; }
    const result = await supabase.rpc("admin_set_balance", { p_user_id: selected.id, p_balance: amount, p_reason: "manual_adjustment" });
    if (result.error) toast(cleanError(result.error), "error");
    else { toast("היתרה עודכנה"); refreshAdmin(); refreshBoard(); }
  });
  actionButton("היסטוריית הימורים", "rounded-xl border border-slate-600 px-3 py-3 text-sm", async () => {
    const result = await supabase.rpc("admin_user_bets", { p_user_id: selected.id });
    if (result.error) { toast(cleanError(result.error), "error"); return; }
    const lines = (result.data || []).slice(0, 12).map((bet) => "#" + bet.id + " · ₪" + money(bet.bet_amount) + " · " + bet.status + " · יחס " + bet.odds).join("\n");
    alert(lines || "אין הימורים למשתמש זה");
  });
  actionButton("מחיקת משתמש", "col-span-2 rounded-xl border border-rose-500/50 px-3 py-3 text-sm text-rose-300", async () => {
    if (!confirm("לסמן את " + selected.username + " כמחוק? היסטוריית ההימורים תישמר והוא יוסתר מהטבלה.")) return;
    const result = await supabase.rpc("admin_soft_delete_user", { p_user_id: selected.id });
    if (result.error) toast(cleanError(result.error), "error");
    else { state.adminSelectedUserId = null; toast("המשתמש סומן כמחוק וההיסטוריה נשמרה"); refreshAdmin(); refreshBoard(); }
  });
  root.append(actions);
}

async function renderAdminMarkets(root) {
  adminHeader(root, "שווקים");
  const result = await supabase.rpc("admin_get_market_settings");
  if (result.error) { empty(root, cleanError(result.error)); return; }
  const card = document.createElement("section");
  card.className = "rounded-2xl border border-slate-700/50 bg-panel p-4";
  const note = document.createElement("p");
  note.className = "mb-3 text-xs text-mist";
  note.textContent = "הפעל או הסתר סוגי הימורים לכל המשחקים. שוק שלא קיים במשחק לא יוצג.";
  card.append(note);
  (result.data || []).forEach((setting) => {
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
      const savedValue = toggle.checked;
      const update = await supabase.rpc("admin_set_market_setting", { p_market_key: setting.key, p_enabled: savedValue });
      toggle.disabled = false;
      if (update.error) {
        toggle.checked = !savedValue;
        toast(cleanError(update.error), "error");
        return;
      }
      state.marketSettings[setting.key] = savedValue;
      toast(savedValue ? "סוג ההימור הופעל" : "סוג ההימור הוסתר");
      renderGames();
    });
    row.append(label, toggle);
    card.append(row);
  });
  root.append(card);
}

async function renderAdminSettlements(root) {
  adminHeader(root, "הכרעות");
  const result = await supabase
    .from("winner_markets")
    .select("id,market_key,market_label,outcomes,games!inner(home_team,away_team,status,result_confirmed)")
    .eq("active", true)
    .is("settled_at", null)
    .eq("games.status", "finished")
    .eq("games.result_confirmed", true)
    .order("id", { ascending: false })
    .limit(80);
  if (result.error) { empty(root, "לא ניתן לטעון שווקים להכרעה: " + cleanError(result.error)); return; }
  const markets = (result.data || []).filter((market) =>
    !["handicap_ft", "total_goals_2_5", "btts"].includes(market.market_key)
  );
  if (!markets.length) {
    const none = document.createElement("p");
    none.className = "rounded-2xl border border-slate-700/50 bg-panel p-4 text-sm text-mist";
    none.textContent = "אין כרגע שווקים שממתינים להכרעה ידנית.";
    root.append(none);
    return;
  }
  const note = document.createElement("p");
  note.className = "mb-3 text-xs text-mist";
  note.textContent = "שווקים כמו קרנות, מבקיע ראשון ותוצאות מחצית דורשים נתון שלא מגיע מסנכרון התוצאה הרגיל. בחר את התוצאה הזוכה לאחר בדיקה.";
  root.append(note);
  markets.forEach((market) => {
    const game = market.games || {};
    const item = document.createElement("section");
    item.className = "mb-3 rounded-2xl border border-amber-400/30 bg-panel p-4";
    const heading = document.createElement("h3");
    heading.className = "mb-3 text-sm font-bold";
    heading.textContent = (game.home_team || "משחק") + " – " + (game.away_team || "") + " · " + market.market_label;
    const outcomes = document.createElement("div");
    outcomes.className = "grid grid-cols-2 gap-2";
    (Array.isArray(market.outcomes) ? market.outcomes : []).forEach((outcome) => {
      const button = document.createElement("button");
      button.type = "button";
      button.className = "rounded-lg border border-slate-700 bg-ink/50 px-2 py-3 text-xs text-slate-200";
      button.textContent = (outcome.label || outcome.selection) + " · " + Number(outcome.price).toFixed(2);
      button.addEventListener("click", async () => {
        if (!confirm("לקבוע ש-" + (outcome.label || outcome.selection) + " היא התוצאה הזוכה בשוק הזה?")) return;
        button.disabled = true;
        const settle = await supabase.rpc("admin_settle_winner_market", { p_market_id: Number(market.id), p_winning_selection: outcome.selection });
        if (settle.error) {
          button.disabled = false;
          toast(cleanError(settle.error), "error");
          return;
        }
        toast("השוק הוכרע והטפסים עודכנו");
        await refreshAdmin();
        await refreshBets();
        await refreshBoard();
      });
      outcomes.append(button);
    });
    item.append(heading, outcomes);
    root.append(item);
  });
}

async function renderAdminRuns(root) {
  adminHeader(root, "דוחות ריצות");
  const result = await supabase.rpc("admin_recent_api_requests", { p_limit: 200 });
  if (result.error) { empty(root, cleanError(result.error)); return; }
  const rows = Array.isArray(result.data) ? result.data : [];
  const summary = document.createElement("p");
  summary.className = "mb-3 text-xs text-mist";
  summary.textContent = rows.length + " פניות אחרונות · מסודרות מהחדשה לישנה";
  root.append(summary);
  if (!rows.length) {
    const none = document.createElement("p");
    none.className = "rounded-xl bg-panel p-4 text-sm text-mist";
    none.textContent = "עדיין לא נרשמו פניות.";
    root.append(none);
    return;
  }
  rows.forEach((entry) => {
    const card = document.createElement("article");
    card.className = "mb-2 rounded-2xl border border-slate-700/50 bg-panel p-3";
    const top = document.createElement("div");
    top.className = "flex items-center justify-between gap-2";
    const time = document.createElement("time");
    time.className = "text-xs text-mist";
    time.dateTime = entry.called_at;
    time.textContent = new Date(entry.called_at).toLocaleString("he-IL");
    const status = document.createElement("span");
    const code = Number(entry.status_code);
    status.className = "rounded-lg px-2 py-1 text-xs font-extrabold " + (code >= 400 ? "bg-rose-500/15 text-rose-300" : code >= 200 && code < 300 ? "bg-emerald-500/15 text-emerald-300" : "bg-amber-400/15 text-amber-200");
    status.textContent = "HTTP " + (entry.status_code ?? "—");
    top.append(time, status);
    const endpoint = document.createElement("p");
    endpoint.className = "mt-2 break-all text-sm font-bold";
    endpoint.textContent = entry.endpoint || "פנייה ללא כתובת";
    const purpose = document.createElement("p");
    purpose.className = "mt-1 text-xs text-mist";
    purpose.textContent = "מטרה: " + (entry.purpose || "לא צוינה") + (entry.duration_ms != null ? " · " + entry.duration_ms + "ms" : "");
    card.append(top, endpoint, purpose);
    const details = document.createElement("details");
    details.className = "mt-2 rounded-xl border border-slate-700/50 bg-ink/30 p-2";
    const summaryLine = document.createElement("summary");
    summaryLine.className = "cursor-pointer text-xs font-bold text-gold";
    summaryLine.textContent = "פרטי הפנייה והתשובה";
    const requestTitle = document.createElement("p");
    requestTitle.className = "mt-2 text-[11px] font-bold text-slate-300";
    requestTitle.textContent = "פרמטרים שנשלחו / פרטי הבדיקה";
    const requestData = document.createElement("pre");
    requestData.className = "mt-1 max-h-48 overflow-auto whitespace-pre-wrap break-words text-[11px] text-mist";
    requestData.textContent = JSON.stringify(entry.params || {}, null, 2);
    const responseTitle = document.createElement("p");
    responseTitle.className = "mt-2 text-[11px] font-bold text-slate-300";
    responseTitle.textContent = "תשובת הספק";
    const responseData = document.createElement("pre");
    responseData.className = "mt-1 max-h-56 overflow-auto whitespace-pre-wrap break-words text-[11px] text-mist";
    responseData.textContent = entry.response_summary
      ? JSON.stringify(entry.response_summary, null, 2)
      : "תוכן התשובה לא נשמר ברישום המקורי. נשמרו קוד הסטטוס והפרמטרים בלבד.";
    details.append(summaryLine, requestTitle, requestData, responseTitle, responseData);
    card.append(details);
    root.append(card);
  });
}

async function renderAdminAudit(root) {
  adminHeader(root, "יומן מנהל");
  const result = await supabase.rpc("admin_recent_audit");
  if (result.error) { empty(root, cleanError(result.error)); return; }
  const entries = Array.isArray(result.data) ? result.data : [];
  if (!entries.length) {
    const none = document.createElement("p");
    none.className = "rounded-xl bg-panel p-4 text-sm text-mist";
    none.textContent = "אין עדיין פעולות מנהל ביומן.";
    root.append(none);
    return;
  }
  entries.forEach((entry) => {
    const row = document.createElement("p");
    row.className = "mb-2 rounded-xl bg-panel px-3 py-3 text-xs text-mist";
    const date = new Date(entry.created_at).toLocaleString("he-IL");
    const details = entry.details || {};
    const description = entry.action === "set_balance"
      ? "יתרה: " + details.old_balance + " ← " + details.new_balance + " ₪"
      : entry.action === "soft_delete_user" ? "משתמש סומן כמחוק" : entry.action;
    row.textContent = date + " · " + description;
    root.append(row);
  });
}

async function refreshAdmin() {
  if (!state.isAdmin) return;
  const root = $("view-admin");
  root.replaceChildren();
  const sections = {
    home: renderAdminHome,
    control: renderAdminControl,
    users: renderAdminUsers,
    markets: renderAdminMarkets,
    settlements: renderAdminSettlements,
    runs: renderAdminRuns,
    audit: renderAdminAudit
  };
  const render = sections[state.adminSection] || renderAdminHome;
  try {
    await render(root);
  } catch (error) {
    empty(root, cleanError(error));
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
  banner.textContent = offline ? "אין חיבור לאינטרנט · טעינת נתונים ופעולות אינן זמינות" : "";
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
