"""Regenerate level thresholds. Usage: python scripts/gen_levels.py > app/progression/config/levels.json"""

import json

MAX_LEVEL = 50


def thresholds(base: int, growth: int) -> list[int]:
    out = [0]
    for level in range(2, MAX_LEVEL + 1):
        out.append(out[-1] + base + growth * (level - 2))
    return out


if __name__ == "__main__":
    print(json.dumps({"overall": thresholds(250, 100), "class": thresholds(200, 80)}, indent=2))
