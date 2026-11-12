const kickoff = new Intl.DateTimeFormat("he-IL", {
  timeZone: "Asia/Jerusalem",
  weekday: "short",
  day: "2-digit",
  month: "2-digit",
  hour: "2-digit",
  minute: "2-digit",
});

export function money(value) {
  const number = Number(value);
  if (!Number.isFinite(number)) return "0.00";
  return new Intl.NumberFormat("he-IL", {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  }).format(number);
}

export function when(value) {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "";
  return kickoff.format(date);
}

export const GAME_STATUS = {
  upcoming: "טרם התחיל",
  live: "חי",
  finished: "90 דק׳",
  cancelled: "בוטל",
};

export const BET_STATUS = {
  pending: "ממתין",
  won: "זכייה",
  lost: "הפסד",
  void: "הוחזר",
  cancelled: "בוטל",
};

export const SELECTION = {
  1: "ניצחון בית",
  X: "תיקו",
  2: "ניצחון חוץ",
};

export function canBet(game) {
  if (!game || game.status !== "upcoming") return false;
  if (!game.home_odds || !game.draw_odds || !game.away_odds) return false;
  const kick = new Date(game.match_time).getTime();
  return kick > Date.now() + 5 * 60 * 1000;
}

export function slipLegs(bet) {
  if (Array.isArray(bet?.bet_items) && bet.bet_items.length) return bet.bet_items;
  if (bet?.game_id) {
    return [{
      game_id: bet.game_id,
      bet_selection: bet.bet_selection,
      market_id: bet.market_id,
      market_key: bet.market_key,
      market_selection: bet.market_selection,
      market_label: bet.market_label,
      market_outcome_label: bet.market_outcome_label,
      market_line: bet.market_line,
      odds: bet.odds,
      status: bet.status,
      games: bet.games,
    }];
  }
  return [];
}

export function combinedOdds(prices) {
  return prices.reduce((product, price) => product * Number(price || 0), 1);
}

export function canEdit(bet) {
  const legs = slipLegs(bet);
  const game = legs[0]?.games || bet?.games;
  if (!bet || bet.status !== "pending" || legs.length !== 1 || !game?.match_time) return false;
  return new Date(game.match_time).getTime() > Date.now();
}

export function leagueKey(game) {
  const name = String(game?.round_name || "");
  const code = name.split("|")[0];
  if (["israel", "ucl", "spain", "england", "nations"].includes(code)) return code;
  const text = name.toLowerCase();
  if (text.includes("nations league") || text.includes("אומות")) return "nations";
  if (text.includes("champions league") || text.includes("צ'מפיונס")) return "ucl";
  if (text.includes("la liga") || text.includes("laliga") || text.includes("ספרד")) return "spain";
  if (text.includes("premier league") || text.includes("אנגליה")) return "england";
  if (text.includes("israeli") || text.includes("ליגת העל")) return "israel";
  return "";
}

export function countdownLabel(game, now = Date.now()) {
  if (!game || game.status !== "upcoming" || !game.match_time) return "";
  const remaining = new Date(game.match_time).getTime() - now;
  if (remaining <= 0 || remaining > 6 * 60 * 60 * 1000) return "";
  const minutes = Math.max(1, Math.ceil(remaining / 60000));
  const hours = Math.floor(minutes / 60);
  const rest = minutes % 60;
  if (hours > 0) return `עוד ${hours} שע׳ ו־${rest} דק׳`;
  return `עוד ${rest} דק׳`;
}

export function canCancel(bet) {
  const legs = slipLegs(bet);
  if (!bet || bet.status !== "pending" || !legs.length) return false;
  return legs.every((leg) => {
    const game = leg.games || bet.games;
    return game?.status === "upcoming" && game.match_time && new Date(game.match_time).getTime() > Date.now();
  });
}
