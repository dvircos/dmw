"""Read-only Winner cloud probe. Never writes to Supabase or submits any account action."""
from __future__ import annotations

import json
import re
import time
from collections import Counter
from playwright.sync_api import sync_playwright

TARGET = "https://www.winner.co.il/"
LINE_PATH = re.compile(r"/publicapi/Get(?:C|D)MobileLine(?:[/?]|$)", re.I)
captured = []
navigation = {"status": None, "url": None, "title": None, "error": None}


def inspect_response(response):
    url = response.url
    if not LINE_PATH.search(url):
        return
    item = {"url": url, "status": response.status, "rows": 0, "football_rows": 0,
            "market_labels": Counter(), "sport_ids": Counter(), "json": False}
    try:
        payload = response.json()
        item["json"] = True
        rows = payload.get("markets") or (payload.get("lines") or {}).get("u") or payload.get("u") or []
        if isinstance(rows, list):
            item["rows"] = len(rows)
            for market in rows:
                if not isinstance(market, dict):
                    continue
                sid = str(market.get("sId", ""))
                item["sport_ids"][sid] += 1
                if sid in {"240", "1100"}:
                    item["football_rows"] += 1
                    label = str(market.get("mp") or "").strip()
                    if label:
                        item["market_labels"][label[:90]] += 1
    except Exception as exc:
        item["parse_error"] = str(exc)[:160]
    captured.append(item)


with sync_playwright() as p:
    browser = p.chromium.launch(headless=True)
    context = browser.new_context(locale="he-IL", timezone_id="Asia/Jerusalem",
                                  viewport={"width": 1440, "height": 1000})
    page = context.new_page()
    page.on("response", inspect_response)
    try:
        response = page.goto(TARGET, wait_until="domcontentloaded", timeout=45000)
        navigation["status"] = response.status if response else None
        navigation["url"] = page.url
        try:
            page.wait_for_load_state("networkidle", timeout=12000)
        except Exception:
            pass
        # Allow delayed API calls and client-side rendering to complete.
        page.wait_for_timeout(45000)
        navigation["title"] = page.title()[:160]
    except Exception as exc:
        navigation["error"] = str(exc)[:500]
    finally:
        print("WINNER_CLOUD_PROBE_RESULT")
        print(json.dumps({
            "navigation": navigation,
            "captured_line_responses": len(captured),
            "successful_json_responses": sum(1 for x in captured if x["status"] == 200 and x["json"]),
            "total_market_rows": sum(x["rows"] for x in captured),
            "football_market_rows": sum(x["football_rows"] for x in captured),
            "responses": [{
                "status": x["status"], "json": x["json"], "rows": x["rows"],
                "football_rows": x["football_rows"],
                "sport_ids": dict(x["sport_ids"]),
                "market_labels": dict(x["market_labels"].most_common(15)),
                "parse_error": x.get("parse_error")
            } for x in captured]
        }, ensure_ascii=False, indent=2))
        browser.close()
