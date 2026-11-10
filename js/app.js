import { createClient } from "https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.49.1/+esm";
import { SUPABASE_ANON_KEY, SUPABASE_URL } from "./config.js";
import { BET_STATUS, GAME_STATUS, SELECTION, canBet, money, when } from "./format.js";
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
  img.className = "h-8 w-8 rounded-full bg-white/10 object-cover";
  img.referrerPolicy = "no-referrer";
  if (typeof url === "string" && url.startsWith("https://")) img.src = url;
  return img;
}

function empty(parent, text) {
  parent.replaceChildren();
  const p = document.createElement("p");
  p.className = "rounded-3xl border border-dashed border-white/10 px-4 py-10 text-center text-sm text-slate-400";
  p.textContent = text;
  parent.appendChild(p);
}

function showTab(tab) {
  state.tab = tab;
  $("view-games").classList.toggle("hidden", tab !== "games");
  $("view-bets").classList.toggle("hidden", tab !== "bets");
  $("view-board").classList.toggle("hidden", tab !== "board");
  document.querySelectorAll(".nav-btn").forEach((button) => {
    const active = button.dataset.tab === tab;
    button.classList.toggle("text-gold", active);
    button.classList.toggle("text-slate-400", !active);
  });
}

function renderGames() {
  const root = $("view-games");
  const rank = { live: 0, upcoming: 1, finished: 2, cancelled: 3 };
  const games = [...state.games].sort((a, b) => {
    const byStatus = (rank[a.status] ?? 9) - (rank[b.status] ?? 9);
    if (byStatus) return byStatus;
    return new Date(a.match_time) - new Date(b.match_time);
  });
  if (!games.length) {
    empty(root, "אין משחקים להצגה כרגע");
    return;
  }
  root.replaceChildren();
  games.forEach((game) => {
    const card = document.createElement("article");
    card.className = "mb-3 rounded-3xl border border-white/10 bg-panel p-4";
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
    if (Number(game.fixture_id) >= 900000) {
      const demo = document.createElement("span");
      demo.className = "rounded-full bg-white/10 px-2 py-0.5 text-[10px] text-gold";
      demo.textContent = "הדגמה";
      head.append(time, demo, badge);
    } else {
      head.append(time, badge);
    }

    const teams = document.createElement("div");
    teams.className = "grid grid-cols-[1fr_auto_1fr] items-center gap-2";
    const home = teamColumn(game.home_flag, game.home_team);
    const away = teamColumn(game.away_flag, game.away_team);
    const score = document.createElement("div");
    score.className = "min-w-14 text-center text-xl font-extrabold";
    score.dir = "ltr";
    score.textContent = game.status === "live" || game.status === "finished" ? `${game.home_score} - ${game.away_score}` : "VS";
    teams.append(home, score, away);

    const odds = document.createElement("div");
    odds.className = "mt-4 grid grid-cols-3 gap-2";
    const open = canBet(game);
    [["1", game.home_odds], ["X", game.draw_odds], ["2", game.away_odds]].forEach(([selection, price]) => {
      const button = document.createElement("button");
      button.type = "button";
      button.className = "rounded-2xl bg-black/30 px-2 py-2 text-center disabled:opacity-40";
      button.disabled = !open;
      const label = document.createElement("div");
      label.className = "text-[11px] text-slate-400";
      label.textContent = selection === "1" ? "1 בית" : selection === "2" ? "2 חוץ" : "X תיקו";
      const value = document.createElement("div");
      value.className = "text-base font-extrabold text-emerald-300";
      value.dir = "ltr";
      value.textContent = price ? Number(price).toFixed(2) : "—";
      button.append(label, value);
      if (open) {
        button.addEventListener("click", () => openSheet(game, selection, price));
      }
      odds.append(button);
    });
    card.append(head, teams, odds);
    root.append(card);
  });
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
  if (!state.bets.length) {
    empty(root, "עדיין אין הימורים");
    return;
  }
  root.replaceChildren();
  state.bets.forEach((bet) => {
    const game = bet.games || {};
    const card = document.createElement("article");
    card.className = "mb-3 rounded-3xl border border-white/10 bg-panel p-4";
    const title = document.createElement("p");
    title.className = "font-bold";
    title.textContent = `${game.home_team || "משחק"} נגד ${game.away_team || ""}`;
    const meta = document.createElement("p");
    meta.className = "mt-1 text-sm text-slate-300";
    meta.textContent = `${SELECTION[bet.bet_selection] || bet.bet_selection} · יחס ${Number(bet.odds).toFixed(2)} · סכום ₪${money(bet.bet_amount)}`;
    const foot = document.createElement("div");
    foot.className = "mt-2 flex items-center justify-between text-sm";
    const payout = document.createElement("span");
    payout.dir = "ltr";
    payout.textContent = `₪${money(bet.potential_payout)}`;
    const status = document.createElement("span");
    status.className = bet.status === "won" ? "font-bold text-emerald-300" : bet.status === "lost" ? "text-rose-300" : "text-gold";
    status.textContent = BET_STATUS[bet.status] || bet.status;
    foot.append(payout, status);
    card.append(title, meta, foot);
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
}

function openSheet(game, selection, price) {
  state.selected = { id: game.id, selection, price: Number(price), label: `${game.home_team} נגד ${game.away_team}` };
  $("sheet-match").textContent = state.selected.label;
  $("sheet-selection").textContent = `${SELECTION[selection]} · יחס מוצג ${Number(price).toFixed(2)}`;
  updatePayout();
  $("sheet-backdrop").classList.remove("hidden");
  $("sheet").classList.add("open");
  $("sheet").classList.remove("translate-y-full");
}

function closeSheet() {
  state.selected = null;
  $("sheet").classList.add("translate-y-full");
  $("sheet").classList.remove("open");
  $("sheet-backdrop").classList.add("hidden");
}

function updatePayout() {
  const amount = Number($("stake").value);
  const price = state.selected?.price || 0;
  const payout = Number.isFinite(amount) && amount > 0 ? amount * price : 0;
  $("sheet-payout").textContent = money(payout);
}

async function refreshGames() {
  const { data, error } = await supabase.from("games").select("*").order("match_time", { ascending: true }).limit(200);
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
    .select("id, bet_selection, bet_amount, odds, potential_payout, status, game_id, games(home_team, away_team, status, home_score, away_score)")
    .eq("user_id", state.user.id)
    .order("id", { ascending: false })
    .limit(100);
  if (error) {
    toast(cleanError(error), "error");
    return;
  }
  state.bets = data || [];
  renderBets();
}

async function refreshBoard() {
  const { data, error } = await supabase.from("profiles").select("id, username, balance").order("balance", { ascending: false }).limit(50);
  if (error) {
    toast(cleanError(error), "error");
    return;
  }
  state.board = data || [];
  renderBoard();
}

async function refreshProfile() {
  const { data, error } = await supabase.from("profiles").select("username, balance").eq("id", state.user.id).single();
  if (error) {
    toast(cleanError(error), "error");
    return;
  }
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
  await refreshAll();
  subscribe();
}

function leaveApp() {
  if (state.channel) supabase.removeChannel(state.channel);
  state.channel = null;
  state.user = null;
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

async function placeBet() {
  if (!state.selected || state.submitting) return;
  const amount = Number($("stake").value);
  if (!Number.isFinite(amount) || amount <= 0) {
    toast("הזינו סכום גדול מאפס", "error");
    return;
  }
  if (amount > state.balance) {
    toast("יתרה לא מספיקה", "error");
    return;
  }
  state.submitting = true;
  $("sheet-confirm").disabled = true;
  try {
    const { data, error } = await supabase.rpc("place_bet", {
      p_game_id: Number(state.selected.id),
      p_selection: state.selected.selection,
      p_amount: Math.round(amount * 100) / 100,
    });
    if (error) {
      toast(cleanError(error), "error");
      return;
    }
    setBalance(data.balance);
    toast(`ההימור נקלט ביחס ${Number(data.odds).toFixed(2)} · תשלום אפשרי ₪${money(data.potential_payout)}`);
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
document.querySelectorAll(".stake").forEach((button) => button.addEventListener("click", () => {
  $("stake").value = button.dataset.stake;
  updatePayout();
}));
$("stake").addEventListener("input", updatePayout);
$("sheet-cancel").addEventListener("click", closeSheet);
$("sheet-backdrop").addEventListener("click", closeSheet);
$("sheet-confirm").addEventListener("click", placeBet);

registerServiceWorker();
supabase.auth.onAuthStateChange((event, session) => {
  if (session?.user) enterApp(session);
  else if (event !== "INITIAL_SESSION") leaveApp();
});
supabase.auth.getSession().then(({ data }) => {
  if (data.session) enterApp(data.session);
});
