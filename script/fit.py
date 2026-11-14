#!/usr/bin/env python3
"""Fits how a provider's meter counts tokens to Sluice's histories, for the formula in its provider's code.

  script/fit.py                      what a million tokens of each kind and model raise each meter by
  script/fit.py --output 5 --cache-write 1.25 --cache-read 0.025 --model fable=3.3
                                     what a point of each meter holds under that formula, and how far it varies

Accounts are shown by made-up names. Needs a mix of work that varies: kinds of token that always come
together cannot be told apart, and the ranges say so by being wide.
"""
import argparse, bisect, collections, datetime, json, math, os, random, statistics

KINDS = ("output", "input", "cacheWrite", "cacheRead")
parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument("--history", default=os.path.expanduser("~/Library/Application Support/Sluice"))
parser.add_argument("--output", type=float)
parser.add_argument("--cache-write", type=float)
parser.add_argument("--cache-read", type=float)
parser.add_argument("--model", action="append", default=[], metavar="PART=WEIGHT")
args = parser.parse_args()

def lines(name):
    with open(os.path.join(args.history, name)) as file:
        rows = [json.loads(line) for line in file if line.strip()]
    for row in rows: row["t"] = datetime.datetime.fromisoformat(row["at"].replace("Z", "+00:00")).timestamp()
    return sorted(rows, key=lambda row: row["t"])

readings, requests = lines("readings.jsonl"), lines("requests.jsonl")
key = lambda row: (row["provider"], row["account"])
names = {account: f"{account[0]} {index + 1}" for index, account in enumerate(sorted({key(row) for row in readings}))}

def rises(account, meter):
    """Between one rise of a meter and the next within one window: the points, and the tokens answered meanwhile."""
    own = [row for row in requests if key(row) == account]
    times, out, last = [row["t"] for row in own], [], None
    for reading in (row for row in readings if key(row) == account):
        for window in reading["windows"] + (reading.get("scoped") or []):
            if window["name"] != meter: continue
            now = (reading["t"], window["used"], window["resetsAt"][:15])
            if last is None or now[2] != last[2] or now[1] < last[1] - 0.025: last = now
            elif now[1] > last[1] + 0.005:
                between, tokens = own[bisect.bisect_right(times, last[0]):bisect.bisect_right(times, now[0])], collections.Counter()
                for row in between:
                    for kind in KINDS: tokens[(row["spend"].get("model") or "?", kind)] += row["spend"].get(kind, 0)
                # A rise almost nothing was answered in was use outside Sluice.
                if len(between) >= 3: out.append((round((now[1] - last[1]) * 100), tokens))
                last = now
    return out

def fit(rows, points, rounds=3000):
    """Least squares with no weight below nought, a weight at a time."""
    width = len(rows[0])
    gram = [[sum(row[a] * row[b] for row in rows) for b in range(width)] for a in range(width)]
    aim, weights = [sum(row[a] * point for row, point in zip(rows, points)) for a in range(width)], [0.0] * width
    for _ in range(rounds):
        for a in range(width):
            if gram[a][a]: weights[a] = max(0.0, (aim[a] - sum(gram[a][b] * weights[b] for b in range(width) if b != a)) / gram[a][a])
    return weights

random.seed(1)
for account, name in names.items():
    meters = sorted({window["name"] for row in readings if key(row) == account for window in row["windows"] + (row.get("scoped") or [])})
    for meter in meters:
        seen = rises(account, meter)
        if len(seen) < 10: continue
        print(f"{name}  {meter}: {len(seen)} rises, {sum(points for points, _ in seen)} points")
        if args.output is None:
            columns = sorted({column for _, tokens in seen for column, count in tokens.items() if count})
            rows, points = [[tokens[column] / 1e6 for column in columns] for _, tokens in seen], [points for points, _ in seen]
            weights, again = fit(rows, points), []
            for _ in range(40):
                picked = [random.randrange(len(rows)) for _ in rows]
                again.append(fit([rows[i] for i in picked], [points[i] for i in picked], 800))
            for index, (model, kind) in enumerate(columns):
                spread = sorted(weights[index] for weights in again)
                print(f"    {model:24} {kind:10} {weights[index]:8.3f} points a million  [{spread[4]:.3f} to {spread[35]:.3f}]  {sum(row[index] for row in rows):9.1f}M seen")
        else:
            models = dict(part.split("=") for part in args.model)
            def weigh(tokens):
                total = 0.0
                for (model, kind), count in tokens.items():
                    times = next((float(weight) for part, weight in models.items() if part in model), 1.0)
                    total += times * count * {"output": args.output, "input": 1, "cacheWrite": args.cache_write, "cacheRead": args.cache_read}[kind]
                return total
            each = sorted(weigh(tokens) / points for points, tokens in seen)
            size = statistics.median(each)
            print(f"    a point holds {size / 1e6:.2f}M weighed tokens ±{(each[len(each) * 3 // 4] - each[len(each) // 4]) / 2 / size * 100:.0f}%")
