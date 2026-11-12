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
  bets: [],
  board: [],
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
};

const $ = (id) => document.getElementById(id);

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
  img.className = "h-10 w-10 rounded-xl bg-white/5 object-contain p-0.5";
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
  $("games-tools").classList.toggle("hidden", tab !== "games");
  $("view-games").classList.toggle("hidden", tab !== "games");
  $("view-bets").classList.toggle("hidden", tab !== "bets");
  $("view-board").classList.toggle("hidden", tab !== "board");
  $("view-admin").classList.toggle("hidden", tab !== "admin");
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

function isPriorityMatch(game) {
  const priorityTeams = new Set([
    "ריאל מדריד",
    "ברצלונה",
    "מנצ'סטר יונייטד",
    "מנצ'סטר סיטי",
    "ארסנל",
    "ליברפול",
    "צ'לסי",
  ]);
  const normalize = (name) => String(name || "").trim().replace(/[׳']/g, "'");
  return priorityTeams.has(normalize(game.home_team)) || priorityTeams.has(normalize(game.away_team));
}

function renderGames() {
  const root = $("view-games");
  const rank = { live: 0, upcoming: 1, finished: 2, cancelled: 3 };
  const query = state.query.trim().toLowerCase();
  const now = Date.now();
  const horizon = now + 7 * 24 * 60 * 60 * 1000;
  const games = state.games
    .filter((game) => game.status === "live" || (new Date(game.match_time).getTime() >= now && new Date(game.match_time).getTime() <= horizon))
    .filter((game) => state.league === "all" || leagueKey(game) === state.league)
    .filter((game) => {
      if (!query) return true;
      return `${game.home_team || ""} ${game.away_team || ""}`.toLowerCase().includes(query);
    })
    .sort((a, b) => {
      const byPriority = Number(isPriorityMatch(b)) - Number(isPriorityMatch(a));
      if (byPriority) return byPriority;
      const byStatus = (rank[a.status] ?? 9) - (rank[b.status] ?? 9);
      if (byStatus) return byStatus;
      return new Date(a.match_time) - new Date(b.match_time);
    });
  if (!games.length) {
    empty(root, query ? "לא נמצאה קבוצה" : state.league === "all" ? "אין משחקים להצגה" : "אין משחקים בליגה הזו");
    return;
  }
  root.replaceChildren();
  games.forEach((game) => {
    const card = document.createElement("article");
    card.className = "mb-3 rounded-2xl border border-slate-700/50 bg-panel p-4";
    const head = document.createElement("div");
    head.className = "mb-3 flex items-center justify-between text-xs text-slate-400";
    const time = document.createElement("span");
    time.textContent = when(game.match_time);
    const badge = document.createElement("span");
    badge.className = game.status === "live" ? "inline-flex items-center gap-1 font-bold text-rose-400" : "text-slate-400";
    if (game.status === "live") {
      const dot = document.createElement("span");
      dot.className = "live-dot inline-block h-2 w-2 rounded-full bg-rose-400";
      badge.append(dot, document.createTextNode(" חי"));
    } else {
      badge.textContent = GAME_STATUS[game.status] || game.status;
    }
    const marks = document.createElement("div");
    marks.className = "flex items-center gap-2";
    const soon = countdownLabel(game);
    if (soon) {
      const clock = document.createElement("span");
      clock.className = "rounded-full bg-gold/15 px-2 py-0.5 font-bold text-gold";
      clock.textContent = soon;
      marks.append(clock);
    }
    marks.append(badge);
    head.append(time, marks);

    const teams = document.createElement("div");
    teams.className = "grid grid-cols-[1fr_auto_1fr] items-center gap-2";
    const home = teamColumn(game.home_flag, game.home_team);
    const away = teamColumn(game.away_flag, game.away_team);
    const score = document.createElement("div");
    score.className = "min-w-14 text-center text-xl font-extrabold";
    score.dir = "ltr";
    score.textContent = game.status === "live" || game.status === "finished" ? `${game.away_score} - ${game.home_score}` : "VS";
    teams.append(home, score, away);

    const odds = document.createElement("div");
    odds.className = "mt-4 grid grid-cols-3 gap-2";
    const open = canBet(game);
    [["1", game.home_odds], ["X", game.draw_odds], ["2", game.away_odds]].forEach(([selection, price]) => {
      const button = document.createElement("button");
      button.type = "button";
      const picked = state.slip.some((leg) => leg.gameId === Number(game.id) && leg.selection === selection);
      button.className = `rounded-2xl border px-2 py-2 text-center disabled:opacity-40 ${picked ? "border-gold bg-gold/20 ring-2 ring-gold" : "border-slate-700/50 bg-ink/60"}`;
      button.disabled = !open;
      const label = document.createElement("div");
      label.className = "text-[11px] text-slate-400";
      label.textContent = selection === "1" ? "1 בית" : selection === "2" ? "2 חוץ" : "X תיקו";
      const value = document.createElement("div");
      value.className = "text-base font-extrabold text-mint";
      value.dir = "ltr";
      value.textContent = price ? Number(price).toFixed(2) : "—";
      button.append(label, value);
      if (open) {
        button.addEventListener("click", () => toggleSlip(game, selection, price));
      }
      odds.append(button);
    });
    card.append(head, teams);
    const stake = pendingStake(game);
    if (stake > 0) {
      const openBet = document.createElement("p");
      openBet.className = "mt-3 inline-flex rounded-full bg-gold/15 px-2 py-0.5 text-[11px] font-bold text-gold";
      const shown = Number.isInteger(stake) ? String(stake) : money(stake);
      openBet.textContent = `המרת ₪${shown}`;
      card.append(openBet);
    }
    card.append(odds);
    root.append(card);
  });
}

function teamColumn(url, name) {
  const wrap = document.createElement("div");
  wrap.className = "flex min-w-0 flex-col items-center gap-1 text-center";
  const title = document.createElement("span");
  title.className = "max-w-full whitespace-normal break-words text-sm font-bold leading-tight";
  title.textContent = name;
  wrap.append(flag(url), title);
  return wrap;
}

function renderBets() {
  const root = $("view-bets");
  if (!state.bets.length) {
    empty(root, "עדיין אין הימורים");
    return;
  }
  root.replaceChildren();
  state.bets.forEach((bet) => {
    const legs = slipLegs(bet);
    const game = legs[0]?.games || bet.games || {};
    const card = document.createElement("article");
    card.className = "mb-3 rounded-2xl border border-slate-700/50 bg-panel p-4";
    const title = document.createElement("p");
    title.className = "font-bold";
    title.textContent = legs.length > 1
      ? `טופס משולב · ${legs.length} משחקים`
      : `${game.home_team || "משחק"} נגד ${game.away_team || ""}`;
    card.append(title);
    if (legs.length > 1) {
      legs.forEach((leg) => {
        const row = document.createElement("p");
        row.className = "mt-1 text-sm text-slate-300";
        const match = leg.games || {};
        const legStatus = bet.status === "pending" || bet.status === "won" || bet.status === "lost" ? ` · ${BET_STATUS[leg.status] || ""}` : "";
        row.textContent = `${match.home_team || "משחק"} נגד ${match.away_team || ""} · ${SELECTION[leg.bet_selection] || leg.bet_selection} · ${Number(leg.odds).toFixed(2)}${legStatus}`;
        card.append(row);
      });
    }
    const meta = document.createElement("p");
    meta.className = "mt-1 text-sm text-slate-300";
    meta.textContent = legs.length > 1
      ? `יחס משולב ${Number(bet.odds).toFixed(2)} · סכום ₪${money(bet.bet_amount)}`
      : `${when(game.match_time)} · ${SELECTION[bet.bet_selection || legs[0]?.bet_selection] || ""} · יחס ${Number(bet.odds).toFixed(2)} · סכום ₪${money(bet.bet_amount)}`;
    const foot = document.createElement("div");
    foot.className = "mt-2 flex items-center justify-between text-sm";
    const payout = document.createElement("span");
    payout.dir = "ltr";
    payout.textContent = `₪${money(bet.potential_payout)}`;
    const status = document.createElement("span");
    status.className = bet.status === "won" ? "font-bold text-mint" : bet.status === "lost" || bet.status === "cancelled" ? "text-rose-300" : "text-gold";
    status.textContent = BET_STATUS[bet.status] || bet.status;
    foot.append(payout, status);
    card.append(meta, foot);
    if (bet.status === "pending") {
      const editable = canEdit(bet);
      const cancellable = canCancel(bet);
      const actions = document.createElement("div");
      actions.className = legs.length > 1 ? "mt-3" : "mt-3 grid grid-cols-2 gap-2";
      if (legs.length === 1) {
        const edit = document.createElement("button");
        edit.type = "button";
        edit.className = "rounded-2xl border border-white/10 py-2 text-sm font-bold disabled:opacity-40";
        edit.textContent = editable ? "עריכת הימור" : "ההימור נעול";
        edit.disabled = !editable;
        if (editable) {
          edit.addEventListener("click", () => openSheet(game, bet.bet_selection || legs[0].bet_selection, bet.odds, bet));
        }
        actions.append(edit);
      }
      if (cancellable) {
        const cancel = document.createElement("button");
        cancel.type = "button";
        cancel.className = "w-full rounded-2xl border border-rose-400/40 py-2 text-sm font-bold text-rose-300";
        cancel.textContent = "בטל הימור";
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
  if (!state.board.length) {
    empty(root, "עדיין אין שחקנים בטבלה");
    return;
  }
  root.replaceChildren();
  state.board.forEach((row, index) => {
    const item = document.createElement("div");
    const mine = row.id === state.user?.id;
    item.className = `mb-2 flex items-center justify-between rounded-2xl px-4 py-3 ${mine ? "bg-gold/15 ring-1 ring-gold" : "bg-panel"}`;
    const who = document.createElement("div");
    who.className = "flex items-center gap-3";
    const place = document.createElement("span");
    place.className = "w-6 text-center font-extrabold text-gold";
    place.textContent = String(index + 1);
    const name = document.createElement("span");
    name.className = "font-medium";
    name.textContent = row.username;
    who.append(place, name);
    const balance = document.createElement("span");
    balance.className = "font-bold";
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
  meta.textContent = `${SELECTION[leg.selection]} · ${Number(leg.odds).toFixed(2)}`;
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
  if (index >= 0 && state.slip[index].selection === selection) {
    state.slip.splice(index, 1);
  } else if (index >= 0) {
    state.slip[index] = { ...state.slip[index], selection, odds: Number(price), home: game.home_team, away: game.away_team };
  } else {
    if (state.slip.length >= 8) {
      toast("אפשר עד 8 משחקים בטופס");
      return;
    }
    state.slip.push({ gameId, selection, odds: Number(price), home: game.home_team, away: game.away_team, stake: "25" });
  }
  renderSlip();
  renderGames();
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
  $("sheet-selection").textContent = `${SELECTION[selection]} · יחס ${bet ? "נעול" : "מוצג"} ${Number(price).toFixed(2)}`;
  $("sheet-note").textContent = "";
  $("sheet-confirm").textContent = bet ? "עדכון הימור" : "אישור הימור";
  $("sheet-balance").classList.toggle("hidden", !bet);
  if (bet) $("stake").value = String(bet.bet_amount);
  renderSheetPicks(game, bet);
  updatePayout();
  $("sheet-backdrop").classList.remove("hidden");
  $("sheet-backdrop").classList.add("flex");
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
  const now = new Date();
  const horizon = new Date(now.getTime() + 7 * 24 * 60 * 60 * 1000);
  const { data, error } = await supabase.from("games").select("*")
    .or(`status.eq.live,and(match_time.gte.${now.toISOString()},match_time.lte.${horizon.toISOString()})`)
    .order("match_time", { ascending: true }).limit(200);
  if (error) {
    toast(cleanError(error), "error");
    return;
  }
  state.games = data || [];
  renderGames();
}

async function refreshBets() {
  if (!state.user) return;
  const { data, error } = await supabase
    .from("bets")
    .select("id, bet_selection, bet_amount, odds, potential_payout, status, game_id, games(home_team, away_team, status, home_score, away_score, match_time, home_odds, draw_odds, away_odds), bet_items(game_id, bet_selection, odds, status, games(home_team, away_team, status, home_score, away_score, match_time, home_odds, draw_odds, away_odds))")
    .eq("user_id", state.user.id)
    .order("id", { ascending: false })
    .limit(1000);
  if (error) {
    toast(cleanError(error), "error");
    return;
  }
  state.bets = data || [];
  renderBets();
  renderGames();
}

async function refreshBoard() {
  const { data, error } = await supabase.from("profiles").select("id, username, balance").eq("is_deleted", false).order("balance", { ascending: false }).limit(50);
  if (error) {
    toast(cleanError(error), "error");
    return;
  }
  state.board = data || [];
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
  (Array.isArray(data) ? data : []).forEach(user => {
    const card = document.createElement("article"); card.className = "mb-3 rounded-2xl border border-slate-700/50 bg-panel p-4";
    const head = document.createElement("div"); head.className = "mb-3 flex items-center justify-between gap-2";
    const name = document.createElement("strong"); name.textContent = user.is_deleted ? `${user.username} · נמחק` : user.username;
    const balance = document.createElement("span"); balance.className = "font-bold text-gold"; balance.textContent = `₪${money(user.balance)}`; head.append(name,balance); card.append(head);
    const meta = document.createElement("p"); meta.className = "mb-3 text-xs text-mist"; meta.textContent = `הימורים פתוחים: ${user.pending_bets}`; card.append(meta);
    if (!user.is_deleted) {
      const actions = document.createElement("div"); actions.className = "grid grid-cols-2 gap-2";
      const reset = document.createElement("button"); reset.className = "rounded-xl bg-gold px-3 py-2 text-sm font-bold text-ink"; reset.textContent = "איפוס ל־1,000 ₪";
      reset.addEventListener("click", async () => { if (!confirm(`לאפס את היתרה של ${user.username} ל־1,000 ₪? ההימורים הפתוחים יישארו ללא שינוי.`)) return; const r=await supabase.rpc("admin_set_balance",{p_user_id:user.id,p_balance:1000,p_reason:"reset_to_1000"}); if(r.error) toast(cleanError(r.error),"error"); else { toast("היתרה אופסה; ההימורים נשארו ללא שינוי"); refreshAdmin(); refreshBoard(); } });
      const manual = document.createElement("button"); manual.className = "rounded-xl border border-slate-600 px-3 py-2 text-sm"; manual.textContent = "קביעת יתרה";
      manual.addEventListener("click", async () => { const raw=prompt(`יתרה חדשה עבור ${user.username}:`,String(user.balance)); if(raw===null)return; const amount=Number(raw); if(!Number.isFinite(amount)||amount<0){toast("סכום לא תקין","error");return;} const r=await supabase.rpc("admin_set_balance",{p_user_id:user.id,p_balance:amount,p_reason:"manual_adjustment"}); if(r.error)toast(cleanError(r.error),"error");else{toast("היתרה עודכנה");refreshAdmin();refreshBoard();} });
      const history = document.createElement("button"); history.className = "rounded-xl border border-slate-600 px-3 py-2 text-sm"; history.textContent = "היסטוריית הימורים";
      history.addEventListener("click", async () => { const r=await supabase.rpc("admin_user_bets",{p_user_id:user.id}); if(r.error){toast(cleanError(r.error),"error");return;} const lines=(r.data||[]).slice(0,12).map(b=>`#${b.id} · ₪${money(b.bet_amount)} · ${b.status} · יחס ${b.odds}`).join("\n"); alert(lines||"אין הימורים למשתמש זה"); });
      const del = document.createElement("button"); del.className = "rounded-xl border border-rose-500/50 px-3 py-2 text-sm text-rose-300"; del.textContent = "מחיקת משתמש";
      del.addEventListener("click", async () => { if(!confirm(`לסמן את ${user.username} כמחוק? היסטוריית ההימורים תישמר והוא יוסתר מהטבלה.`))return; const r=await supabase.rpc("admin_soft_delete_user",{p_user_id:user.id}); if(r.error)toast(cleanError(r.error),"error");else{toast("המשתמש סומן כמחוק וההיסטוריה נשמרה");refreshAdmin();refreshBoard();} });
      actions.append(reset,manual,history,del); card.append(actions);
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
  await Promise.all([refreshProfile(), refreshGames(), refreshBets(), refreshBoard()]);
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
    .on("postgres_changes", { event: "*", schema: "public", table: "bets", filter: `user_id=eq.${state.user.id}` }, () => {
      clearTimeout(betTimer);
      betTimer = setTimeout(refreshBets, 250);
    })
    .on("postgres_changes", { event: "UPDATE", schema: "public", table: "profiles", filter: `id=eq.${state.user.id}` }, (payload) => {
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
  $("auth-view").classList.add("hidden");
  $("app-view").classList.remove("hidden");
  const ensured = await supabase.rpc("ensure_profile");
  if (ensured.error) toast(cleanError(ensured.error), "error");
  const adminCheck = await supabase.rpc("admin_is_admin");
  state.isAdmin = !adminCheck.error && adminCheck.data === true;
  $("admin-nav").classList.toggle("hidden", !state.isAdmin);
  $("admin-nav").classList.toggle("flex", state.isAdmin);
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
    p_legs: legs.map((leg) => ({ game_id: leg.gameId, selection: leg.selection })),
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

registerServiceWorker();
supabase.auth.onAuthStateChange((event, session) => {
  if (session?.user) enterApp(session);
  else if (event !== "INITIAL_SESSION") leaveApp();
});
supabase.auth.getSession().then(({ data }) => {
  if (data.session) enterApp(data.session);
});
