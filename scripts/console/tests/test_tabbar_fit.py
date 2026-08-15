"""The tab bar must FIT, and when it cannot, it must SAY SO.

WHY THIS FILE EXISTS
  On 2026-08-15 the tenth pane (Sessions) shipped and the tab bar quietly ran
  out of room: `.tab { min-width: 64px }` x 10 tabs + gaps + the refresh and
  help controls needs 727px of content, but the desktop tab bar only has
  700 - 28 = 672px at its narrowest (the mobile breakpoint is max-width:700px
  and `main` carries 14px of padding each side). `.tabbar` also declared
  `scrollbar-width: none`, so the overflow was **completely unsignalled** — the
  refresh and help controls simply were not there, with nothing to hint that
  the bar scrolled. A silently-clipped nav is the same defect class as a hidden
  failure: CLAUDE.md, "a check that has never been proven to fail is not a
  check", and its sibling "fail-closed, never silent".

  Eyeballing it once is not a gate. This module turns "it fitted when we
  looked" into arithmetic that CI re-derives from the CSS and from PANES, so
  **adding an 11th tab without adjusting the CSS goes red**.

WHAT IS ASSERTED
  1. WIDTH BUDGET  — N*min-width + (N+1)*gap + controls <= 672px.
  2. LABEL FIT     — a tab at its floor width is wide enough for the longest
                     label, so labels never truncate or overlap.
  3. OVERFLOW IS SIGNALLED — the bar may still scroll (11 tabs one day, a
                     phone today); it may not scroll *invisibly*.

FONT PROVENANCE (this is a measurement, not a guess)
  LABEL_EM below is the rendered advance width of each label divided by the
  font-size, measured in headless Chromium at font-weight 600 with the
  console's own declared stack:

      system-ui, -apple-system, "Segoe UI", sans-serif

  Width is exactly linear in font-size (checked at 11.5/12/12.5/13/13.5px —
  the ratio was stable to 4 decimal places), so one em-ratio per label is the
  whole model. LABEL_SAFETY carries a margin on top for sub-pixel rounding and
  ordinary metric variation between hosts.

  A label NOT in the table fails this test on purpose. Guessing a text width
  is how the bar overflowed in the first place; measure the new one and add it.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

from app.main import PANES

STATIC = Path(__file__).resolve().parent.parent / "static" / "style.css"

# ---- the fixed budget --------------------------------------------------------
# style.css puts the phone's bottom nav behind `@media (max-width: 700px)`, so
# 700px is the narrowest viewport the DESKTOP bar has to serve, and `main`
# (padding: 14px) is its containing block.
MOBILE_BREAKPOINT_PX = 700
MAIN_PADDING_X_PX = 14
DESKTOP_BUDGET_PX = MOBILE_BREAKPOINT_PX - 2 * MAIN_PADDING_X_PX  # 672

# Measured in headless Chromium against the real markup (a `.ghost.tab-refresh`
# button holding "⟳" plus the opacity-0-but-still-laid-out "…" spinner, and the
# "?" help link, which is an <a> and so gets no button padding or border).
REFRESH_GLYPHS_PX = 29  # "⟳…" content box
REFRESH_BORDER_PX = 2  # button border: 1px a side, transparent but laid out
HELP_LINK_PX = 7  # "?"

# Rendered width / font-size, font-weight 600, console stack. See FONT PROVENANCE.
LABEL_EM = {
    "Review": 3.5320,
    "Fleet": 2.4700,
    "Issues": 3.1281,
    "Todo": 2.3800,
    "Demo": 2.9320,
    "Backups": 4.1970,
    "CI": 1.0261,
    "Quokka": 3.9161,
    "Visuals": 3.5150,
    "Sessions": 4.2141,
}
LABEL_SAFETY = 1.05


# ---- a very small CSS reader -------------------------------------------------
# Deliberately not a CSS parser: it reads the handful of declarations this
# contract is about, and FAILS when it cannot find one. A budget computed from
# a declaration we silently failed to read would be the "swallowed verdict"
# shape — a literal standing in for a measurement never taken.


def _css() -> str:
    if not STATIC.is_file():
        pytest.fail(f"CANNOT VERIFY: no stylesheet at {STATIC}")
    return STATIC.read_text(encoding="utf-8")


def _block(css: str, selector: str) -> str:
    """The declarations of the first top-level `selector { ... }` rule."""
    m = re.search(r"(?m)^" + re.escape(selector) + r"\s*\{([^}]*)\}", css)
    if not m:
        pytest.fail(
            f"CANNOT VERIFY: no top-level rule `{selector} {{ … }}` in {STATIC.name}. "
            "The tab-bar fit contract reads real declarations; if the rule was "
            "renamed, update this test in the same MR rather than dropping the check."
        )
    return m.group(1)


def _px(block: str, prop: str, selector: str) -> float:
    m = re.search(r"(?:^|;)\s*" + re.escape(prop) + r"\s*:\s*(-?[\d.]+)px", block)
    if not m:
        pytest.fail(
            f"CANNOT VERIFY: `{selector}` declares no `{prop}: <n>px`. "
            f"Found: {block.strip()!r}"
        )
    return float(m.group(1))


def _padding_x(block: str, prop_owner: str) -> float:
    """Horizontal padding from a `padding: <v> <h>` / `padding: <v>` shorthand."""
    m = re.search(r"(?:^|;)\s*padding\s*:\s*([^;}]+)", block)
    if not m:
        pytest.fail(f"CANNOT VERIFY: `{prop_owner}` declares no `padding`.")
    parts = [p for p in m.group(1).split() if p.endswith("px")]
    if not parts:
        pytest.fail(f"CANNOT VERIFY: `{prop_owner}` padding is not in px: {m.group(1)!r}")
    # padding: A            -> horizontal = A
    # padding: A B [C [D]]  -> horizontal = B
    return float(parts[min(1, len(parts) - 1)][:-2])


def _refresh_control_px(css: str) -> float:
    """Width of the ⟳ button: its own padding rule if it has one, else `button`."""
    m = re.search(r"(?m)^button\.tab-refresh\s*\{([^}]*)\}", css)
    block, owner = (m.group(1), "button.tab-refresh") if m else (_block(css, "button"), "button")
    return 2 * _padding_x(block, owner) + REFRESH_BORDER_PX + REFRESH_GLYPHS_PX


def _controls_px(css: str) -> float:
    return _refresh_control_px(css) + HELP_LINK_PX


def _budget_report(css: str) -> tuple[float, str]:
    n = len(PANES)
    gap = _px(_block(css, ".tabbar"), "gap", ".tabbar")
    tab = _block(css, ".tab")
    min_w = _px(tab, "min-width", ".tab")
    controls = _controls_px(css)
    total = n * min_w + (n + 1) * gap + controls
    report = (
        f"{n} tabs x {min_w:g}px min-width = {n * min_w:g}px\n"
        f"  + {n + 1} gaps x {gap:g}px          = {(n + 1) * gap:g}px\n"
        f"  + refresh ⟳ and help ? controls = {controls:g}px\n"
        f"  = {total:g}px of content in a {DESKTOP_BUDGET_PX}px bar "
        f"({MOBILE_BREAKPOINT_PX}px viewport - 2x{MAIN_PADDING_X_PX}px of `main` padding)"
    )
    return total, report


# ---- 1. width budget ---------------------------------------------------------


def test_all_tabs_fit_the_desktop_bar():
    """Every pane's tab, plus the refresh and help controls, fits at 700px.

    This is the assertion the Sessions tab broke. It is written against
    `len(PANES)`, so an 11th pane fails it without anyone remembering to look.
    """
    css = _css()
    total, report = _budget_report(css)
    assert total <= DESKTOP_BUDGET_PX, (
        "TAB BAR OVERFLOWS at the narrowest desktop width — tabs will be clipped:\n"
        f"  {report}\n"
        f"  OVER BUDGET BY {total - DESKTOP_BUDGET_PX:g}px.\n"
        "Fix by shrinking `.tab { min-width }` / `.tab { padding }` / `.tabbar { gap }` "
        "or `.tab .tab-label { font-size }` in static/style.css — and keep "
        "test_tab_floor_fits_the_longest_label green, so nothing truncates."
    )


def test_budget_has_no_room_for_another_tab():
    """The gate is live, not merely satisfied.

    Proves that one more pane at today's numbers would exceed the budget — i.e.
    that `test_all_tabs_fit_the_desktop_bar` is load-bearing rather than
    trivially true with acres of slack. If a future MR legitimately makes room
    for more tabs, this assertion is the one to update, deliberately.
    """
    css = _css()
    gap = _px(_block(css, ".tabbar"), "gap", ".tabbar")
    min_w = _px(_block(css, ".tab"), "min-width", ".tab")
    total, _ = _budget_report(css)
    with_one_more = total + min_w + gap
    assert with_one_more > DESKTOP_BUDGET_PX, (
        f"{len(PANES) + 1} tabs would still fit ({with_one_more:g}px <= "
        f"{DESKTOP_BUDGET_PX}px). That is fine, but it means the fit gate has "
        "slack it is not asserting. Update this test in the same MR."
    )


# ---- 2. labels never truncate ------------------------------------------------


def test_tab_floor_fits_the_longest_label():
    """A tab squeezed to its floor is still wide enough for its own text."""
    css = _css()
    tab = _block(css, ".tab")
    min_w = _px(tab, "min-width", ".tab")
    pad_x = _padding_x(tab, ".tab")
    font = _px(_block(css, ".tab .tab-label"), "font-size", ".tab .tab-label")

    unmeasured = sorted({label for _, label in PANES} - set(LABEL_EM))
    assert not unmeasured, (
        f"unmeasured tab label(s): {unmeasured}. This test refuses to guess a text "
        "width. Measure the rendered width at font-weight 600 with the console's "
        'stack (system-ui, -apple-system, "Segoe UI", sans-serif), divide by the '
        "font-size, and add the ratio to LABEL_EM."
    )

    content_px = min_w - 2 * pad_x
    widest_label, widest_em = max(
        ((label, LABEL_EM[label]) for _, label in PANES), key=lambda kv: kv[1]
    )
    needed = widest_em * font * LABEL_SAFETY
    assert content_px >= needed, (
        f"tab label {widest_label!r} does not fit its own tab at the floor width:\n"
        f"  .tab min-width {min_w:g}px - 2x{pad_x:g}px padding = {content_px:g}px of content\n"
        f"  {widest_label!r} at {font:g}px needs {widest_em * font:.2f}px "
        f"(x{LABEL_SAFETY} safety = {needed:.2f}px)\n"
        "The label would overflow its tab and crowd its neighbour. Raise min-width, "
        "cut padding, or cut the label font-size."
    )


# ---- 3. overflow is never silent ---------------------------------------------


def test_overflow_is_signalled():
    """The bar may scroll; it may not scroll invisibly.

    `scrollbar-width: none` on a scroll container is exactly the "hidden
    failure" shape: below the desktop budget (and on every phone, where 10 tabs
    cannot fit at any sane size) tabs go off the edge with no scrollbar, no
    fade, nothing. Keep an affordance.
    """
    css = _css()
    bar = _block(css, ".tabbar")

    assert re.search(r"overflow-x\s*:\s*auto", bar), (
        "`.tabbar` no longer scrolls. If tabs can exceed the bar width they must "
        "be reachable somehow — do not simply clip them."
    )
    assert not re.search(r"scrollbar-width\s*:\s*none", bar), (
        "`.tabbar` hides its scrollbar (`scrollbar-width: none`) — that is how the "
        "Sessions tab went missing with no hint that the bar scrolled at all."
    )

    thin = re.search(r"scrollbar-width\s*:\s*thin", bar)
    # Touch platforms use overlay scrollbars that are invisible at rest, so a
    # scrollbar alone is not enough: the scroll-shadow layers (background-
    # attachment: local + scroll) show a fade only while there is content off
    # that edge, on every platform and with no JS.
    fade = re.search(r"background-attachment\s*:[^;}]*\blocal\b", bar)
    assert thin and fade, (
        "`.tabbar` must signal that it scrolls, both with a visible scrollbar "
        "(`scrollbar-width: thin`) and with the edge fade "
        "(`background-attachment: local, …` scroll shadows) that touch platforms "
        "can also show.\n"
        f"  scrollbar-width: thin -> {'yes' if thin else 'MISSING'}\n"
        f"  edge fade             -> {'yes' if fade else 'MISSING'}"
    )
