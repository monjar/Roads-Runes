"""/admin: the developer's page. Off unless ADMIN_TOKEN is set.

Signed in with HTTP Basic (any user name, ADMIN_TOKEN as the password), never with a
player's sign-in: developer sign-in lets anyone with the URL claim any dev account, so
`users.is_admin` cannot guard anything while it is on. Forms carry a token derived
from ADMIN_TOKEN, since a browser resends Basic credentials on a cross-site post.
"""

from __future__ import annotations

import hashlib
import hmac
import math
from pathlib import Path
from typing import Annotated

from fastapi import APIRouter, Depends, Form, HTTPException, Query, Request
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse, Response
from fastapi.security import HTTPBasic, HTTPBasicCredentials
from fastapi.templating import Jinja2Templates

from app import __version__
from app.admin import flags, stats
from app.core.config import ALL_FEATURE_FLAGS
from app.core.deps import DBDep, SettingsDep

basic = HTTPBasic(auto_error=False)
templates = Jinja2Templates(directory=Path(__file__).parent / "templates")

HEADERS = {
    "Cache-Control": "no-store",
    "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'",
    "Referrer-Policy": "no-referrer",
    "X-Frame-Options": "DENY",
    "X-Robots-Tag": "noindex",
}
ACTIONS = {"on": True, "off": False, "clear": None}
WINDOWS = (7, 30, 90)


def require_admin(settings: SettingsDep, credentials: Annotated[HTTPBasicCredentials | None, Depends(basic)]) -> None:
    if not settings.admin_token:
        raise HTTPException(404, "Not Found")
    if credentials is None or not hmac.compare_digest(credentials.password.encode(), settings.admin_token.encode()):
        raise HTTPException(401, "Admin sign-in needed.", headers={"WWW-Authenticate": 'Basic realm="admin"'})


def form_token(admin_token: str) -> str:
    return hmac.new(admin_token.encode(), b"admin-form", hashlib.sha256).hexdigest()


router = APIRouter(prefix="/admin", include_in_schema=False, dependencies=[Depends(require_admin)])

Days = Annotated[int, Query(ge=1, le=90)]


@router.get("", response_class=HTMLResponse)
async def page(request: Request, db: DBDep, settings: SettingsDep, days: Days = 7) -> Response:
    numbers = await stats.collect(db, days)
    overrides = await flags.load(db)
    daily = numbers["daily"]
    labels = [d["date"] for d in daily]
    context = {
        "days": days,
        "windows": WINDOWS,
        "s": numbers,
        "charts": [
            ("Outings per day", bar_chart([d["outings"] for d in daily], labels)),
            ("Active riders per day", bar_chart([d["riders"] for d in daily], labels)),
        ],
        "flags": flags.table(settings, overrides),
        "feature_flags_env": settings.feature_flags,
        "refresh_seconds": int(flags.REFRESH_SECONDS),
        "form_token": form_token(settings.admin_token),
        "server": {
            "version": __version__,
            "environment": settings.environment,
            "routing": getattr(getattr(request.app.state, "router", None), "name", "?"),
            "jobs": settings.job_queue,
            "llm": bool(getattr(getattr(request.app.state, "llm", None), "enabled", False)),
            "devAuth": settings.dev_auth_enabled,
        },
    }
    return templates.TemplateResponse(request, "admin.html", context, headers=HEADERS)


@router.get("/stats.json")
async def stats_json(db: DBDep, days: Days = 7) -> Response:
    return JSONResponse(await stats.collect(db, days), headers=HEADERS)


@router.post("/flags")
async def set_flag(
    db: DBDep,
    settings: SettingsDep,
    name: Annotated[str, Form()],
    action: Annotated[str, Form()],
    token: Annotated[str, Form()],
    note: Annotated[str, Form()] = "",
    days: Annotated[int, Form(ge=1, le=90)] = 7,
) -> Response:
    if not hmac.compare_digest(token.encode(), form_token(settings.admin_token).encode()):
        raise HTTPException(403, "That form is stale. Reload the page and try again.")
    if name not in ALL_FEATURE_FLAGS or action not in ACTIONS:
        raise HTTPException(400, "No such flag or action.")
    await flags.save(db, name, ACTIONS[action], note.strip()[:200] or None)
    return RedirectResponse(f"/admin?days={days}#flags", status_code=303, headers=HEADERS)


# A bar chart drawn on the server: no script on the page, so nothing for the CSP to allow.

PLOT_W, PLOT_H, LEFT, TOP, BOTTOM = 720, 120, 36, 10, 22


def _nice(top: float) -> float:
    if top <= 0:
        return 1
    step = 10 ** math.floor(math.log10(top))
    return next(m * step for m in (1, 2, 5, 10) if m * step >= top)


def _bar(x: float, w: float, h: float) -> str:
    """A column from the baseline, rounded at its data end only."""
    base, y = TOP + PLOT_H, TOP + PLOT_H - h
    r = min(4.0, w / 2, h)
    return (
        f"M{x:.1f},{base:.1f}V{y + r:.1f}Q{x:.1f},{y:.1f} {x + r:.1f},{y:.1f}"
        f"H{x + w - r:.1f}Q{x + w:.1f},{y:.1f} {x + w:.1f},{y + r:.1f}V{base:.1f}Z"
    )


def bar_chart(values: list[float], labels: list[str]) -> dict:
    top = _nice(max(values, default=0))
    slot = PLOT_W / max(len(values), 1)
    width = min(24.0, max(1.0, slot - 2))  # at least a 2px gap between neighbours
    marks = []
    for i, (value, label) in enumerate(zip(values, labels, strict=True)):
        h = value / top * PLOT_H
        x = LEFT + i * slot
        marks.append(
            {
                "slot_x": round(x, 1),
                "slot_w": round(slot, 1),
                "path": _bar(x + (slot - width) / 2, width, h) if h > 0 else None,
                "label": label,
                "value": value,
            }
        )
    return {
        "view_w": LEFT + PLOT_W + 8,
        "view_h": TOP + PLOT_H + BOTTOM,
        "left": LEFT,
        "right": LEFT + PLOT_W,
        "top_y": TOP,
        "base_y": TOP + PLOT_H,
        "top": int(top) if float(top).is_integer() else top,
        "marks": marks,
        "first": labels[0] if labels else "",
        "last": labels[-1] if labels else "",
    }
