#!/usr/bin/env python3
"""
Step 0 - data acquisition for the cross-asset trend-persistence screen.

Descriptive only. No strategy, no parameters, no entries. Pulls long daily
history for a basket chosen to match the instruments actually available on the
prop firm's server (FundingPips-SIM1), and caches the raw JSON so the screen
can be re-run without re-fetching.

Public source: Yahoo Finance chart API. Proxies are cash indices and continuous
front-month futures, NOT the broker's CFDs. Good enough to answer "does trend
persistence exist in this asset class" - not good enough to backtest against.
"""
import json
import os
import sys
import time
import urllib.request

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "step0_data")

# yahoo symbol -> (label, asset class, prop-firm symbol it stands in for)
BASKET = [
    ("%5EGSPC",    "SPX500",  "equity_index", "SPX500"),
    ("%5ENDX",     "NDX100",  "equity_index", "NDX100"),
    ("%5EDJI",     "DJI30",   "equity_index", "DJI30"),
    ("%5EGDAXI",   "GER40",   "equity_index", "GER40"),
    ("%5EFTSE",    "FTSE100", "equity_index", "FTSE100"),
    ("%5ESTOXX50E","STX50",   "equity_index", "STX50"),
    ("%5EN225",    "JP225",   "equity_index", "JP225"),
    ("GC%3DF",     "XAUUSD",  "metal",        "XAUUSD"),
    ("SI%3DF",     "XAGUSD",  "metal",        "XAGUSD"),
    ("HG%3DF",     "COPPER",  "metal",        "(not offered)"),
    ("CL%3DF",     "USOIL",   "energy",       "USOIL"),
    ("BZ%3DF",     "UKOIL",   "energy",       "UKOIL"),
    ("NG%3DF",     "NATGAS",  "energy",       "(not offered)"),
    ("ZN%3DF",     "US10Y",   "rates",        "(not offered)"),
    ("BTC-USD",    "BTCUSD",  "crypto",       "BTCUSD"),
    ("EURUSD%3DX", "EURUSD",  "fx_control",   "EURUSD"),
    ("USDJPY%3DX", "USDJPY",  "fx_control",   "USDJPY"),
    ("AUDUSD%3DX", "AUDUSD",  "fx_control",   "AUDUSD"),
    ("GBPUSD%3DX", "GBPUSD",  "fx_control",   "GBPUSD"),
]

P1 = 631152000      # 1990-01-01
P2 = 1790000000     # comfortably past today


def fetch(ysym):
    url = ("https://query1.finance.yahoo.com/v8/finance/chart/%s"
           "?period1=%d&period2=%d&interval=1d" % (ysym, P1, P2))
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(req, timeout=45) as r:
        return json.loads(r.read().decode("utf-8"))


def main():
    os.makedirs(OUT, exist_ok=True)
    for ysym, label, cls, prop in BASKET:
        path = os.path.join(OUT, label + ".json")
        if os.path.exists(path) and os.path.getsize(path) > 5000:
            print("  cached  %-8s" % label)
            continue
        try:
            d = fetch(ysym)
            res = d.get("chart", {}).get("result")
            if not res:
                print("  FAILED  %-8s  %s" % (label, d.get("chart", {}).get("error")))
                continue
            with open(path, "w") as fh:
                json.dump(d, fh)
            n = len(res[0].get("timestamp") or [])
            print("  ok      %-8s  %6d daily bars" % (label, n))
        except Exception as e:
            print("  ERROR   %-8s  %s" % (label, e))
        time.sleep(1.0)


if __name__ == "__main__":
    main()
