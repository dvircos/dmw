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
  void: "בוטל",
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

export function canEdit(bet) {
  const game = bet?.games;
  if (!bet || bet.status !== "pending" || !game?.match_time) return false;
  return new Date(game.match_time).getTime() > Date.now();
}
