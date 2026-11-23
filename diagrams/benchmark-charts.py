"""Generate the BENCHMARK.md charts as SVG files.

The numbers below are copied from BENCHMARK.md and the reports in bench/results/.
Edit them here when a result changes, run `python diagrams/benchmark-charts.py`,
then re-render the PNGs as described in diagrams/README.md.
"""
from pathlib import Path

OUT = Path(__file__).resolve().parent

FONT = "'Segoe UI', Inter, -apple-system, 'Helvetica Neue', Arial, sans-serif"
INK = "#0B2545"        # titles
TEXT = "#334155"       # labels
MUTED = "#64748B"      # notes, axis
GRID = "#E2E8F0"
PROC = "#2a78d6"       # this repo's stored procedure
OTHER = "#858480"      # every comparison arm
NOISE = "#F1F5F9"      # noise-floor band
ACCENT = "#2563EB"


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def header(w, h, title, subtitle, desc):
    return [
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} {h}" width="{w}" height="{h}" '
        f'font-family="{FONT}" text-rendering="geometricPrecision">',
        f"  <title>{esc(title)}</title>",
        f"  <desc>{esc(desc)}</desc>",
        "  <defs>",
        '    <pattern id="hatch" width="8" height="8" patternUnits="userSpaceOnUse" patternTransform="rotate(45)">',
        '      <rect width="8" height="8" fill="#FFFFFF"/>',
        '      <line x1="0" y1="0" x2="0" y2="8" stroke="#B6B5AF" stroke-width="3"/>',
        "    </pattern>",
        '    <pattern id="hatchP" width="8" height="8" patternUnits="userSpaceOnUse" patternTransform="rotate(45)">',
        '      <rect width="8" height="8" fill="#FFFFFF"/>',
        '      <line x1="0" y1="0" x2="0" y2="8" stroke="#86b6ef" stroke-width="3"/>',
        "    </pattern>",
        "  </defs>",
        f'  <rect width="{w}" height="{h}" fill="#FFFFFF"/>',
        f'  <text x="40" y="42" font-size="14" font-weight="700" letter-spacing="2.5" fill="{ACCENT}">AISQLTUNER-INDEX-TUNER · BENCHMARK</text>',
        f'  <text x="40" y="86" font-size="38" font-weight="800" fill="{INK}">{esc(title)}</text>',
        f'  <text x="40" y="118" font-size="19" fill="#475569">{esc(subtitle)}</text>',
    ]


def legend(x, y, items):
    out = []
    for fill, label in items:
        out.append(f'  <rect x="{x}" y="{y - 13}" width="16" height="16" rx="3" fill="{fill}"/>')
        out.append(f'  <text x="{x + 24}" y="{y}" font-size="15" fill="{TEXT}">{esc(label)}</text>')
        x += 48 + len(label) * 8.6
    return out


def bar(x, y, length, height, fill):
    """Horizontal bar anchored at x, with a 4px rounded data end."""
    if length <= 0:
        return ""
    r = min(4, length)
    n = lambda v: f"{v:.1f}".rstrip("0").rstrip(".")
    x2 = x + length
    return (f'  <path d="M{n(x)} {n(y)} H{n(x2 - r)} Q{n(x2)} {n(y)} {n(x2)} {n(y + r)} '
            f'V{n(y + height - r)} Q{n(x2)} {n(y + height)} {n(x2 - r)} {n(y + height)} H{n(x)} Z" fill="{fill}"/>')


# ---------------------------------------------------------------------------
# Rows shared by the impact charts. proc=True draws the row in the proc colour.
ARMS = [
    ("proc-create", "CREATE mode (applies itself)", True),
    ("proc-widen", "CREATE mode + widenings (#27)", True),
    ("proc-reviewed", "All proc advice applied", True),
    ("desktop", "AI SQL Tuner desktop app", False),
    ("naive", "Every missing-index suggestion", False),
    ("stats", "Statistics refresh only", False),
]
SCEN = ["challenge", "sqlstorm-oltp", "tpch10-realistic"]
SCEN_NOTE = {
    "challenge": "1.8 GB · 16 known problems",
    "sqlstorm-oltp": "1.9 GB · Stack Overflow OLTP",
    "tpch10-realistic": "22 GB · TPC-H reports",
}


def impact_chart(name, title, subtitle, desc, data, floors, note, hatched):
    """data[scenario][arm] = (reduction %, label, beyond_floor) or None (not run)."""
    W, H = 1600, 900
    s = header(W, H, title, subtitle, desc)
    items = [(PROC, "sp_AIIndexTuner (this repo)"), (OTHER, "Comparison")]
    if hatched:
        items.append(("url(#hatch)", "Inside the noise floor: no claim"))
    s += legend(40, 160, items)
    label_w = 300
    left = 40 + label_w
    panel_w = 380
    gap = 30
    top = 250
    row_h = 78
    bar_h = 34
    scale = (panel_w - 70) / 100.0
    for i, (aid, label, _) in enumerate(ARMS):
        cy = top + i * row_h + row_h / 2
        weight = "700" if aid.startswith("proc") else "400"
        s.append(f'  <text x="{left - 16}" y="{cy + 6}" font-size="17" font-weight="{weight}" '
                 f'fill="{TEXT}" text-anchor="end">{esc(label)}</text>')
    for p, sc in enumerate(SCEN):
        x0 = left + p * (panel_w + gap)
        s.append(f'  <text x="{x0}" y="{top - 46}" font-size="20" font-weight="800" fill="{INK}">{sc}</text>')
        s.append(f'  <text x="{x0}" y="{top - 22}" font-size="14" fill="{MUTED}">{SCEN_NOTE[sc]}</text>')
        bottom = top + len(ARMS) * row_h
        floor = floors[sc]
        if floor is not None and floor >= 1:
            fw = floor * scale
            s.append(f'  <rect x="{x0}" y="{top}" width="{fw:.1f}" height="{bottom - top}" fill="{NOISE}"/>')
            s.append(f'  <text x="{x0 + fw + 4:.1f}" y="{bottom + 22}" font-size="13" fill="{MUTED}">'
                     f'noise floor {floor}%</text>')
        for t in (0, 25, 50, 75, 100):
            gx = x0 + t * scale
            s.append(f'  <line x1="{gx:.1f}" y1="{top}" x2="{gx:.1f}" y2="{bottom}" stroke="{GRID}" stroke-width="1"/>')
            s.append(f'  <text x="{gx:.1f}" y="{bottom + (44 if floor and floor >= 1 else 22)}" font-size="13" '
                     f'fill="{MUTED}" text-anchor="middle">{"0" if t == 0 else f"−{t}%"}</text>')
        for i, (aid, _, is_proc) in enumerate(ARMS):
            y = top + i * row_h + (row_h - bar_h) / 2
            v = data[sc].get(aid)
            if v is None:
                s.append(f'  <text x="{x0 + 6}" y="{y + bar_h / 2 + 5}" font-size="14" fill="#94A3B8">not run</text>')
                continue
            red, text, beyond = v
            fill = (PROC if is_proc else OTHER) if beyond else ("url(#hatchP)" if is_proc else "url(#hatch)")
            length = max(red, 0) * scale
            s.append(bar(x0, y, length, bar_h, fill))
            if not beyond:
                s.append(f'  <rect x="{x0}" y="{y}" width="{max(length, 0):.1f}" height="{bar_h}" fill="none" '
                         f'stroke="{PROC if is_proc else OTHER}" stroke-width="1.5"/>' if length > 0 else "")
            s.append(f'  <text x="{x0 + max(length, 0) + 8:.1f}" y="{y + bar_h / 2 + 6}" font-size="17" '
                     f'font-weight="700" fill="{TEXT}">{esc(text)}</text>')
    s.append(f'  <text x="40" y="{H - 28}" font-size="14" fill="{MUTED}">{esc(note)}</text>')
    s.append("</svg>")
    (OUT / f"{name}.svg").write_text("\n".join(x for x in s if x) + "\n", encoding="utf-8")


# Read logical reads, mean of 5 trials. All changes are far beyond each floor (0.002–0.04%).
READS = {
    "challenge": {"proc-create": (79, "−79%", True), "proc-widen": None, "proc-reviewed": (93, "−93%", True),
                  "desktop": (83, "−83%", True), "naive": (90, "−90%", True), "stats": (0.3, "−0.3%", True)},
    "sqlstorm-oltp": {"proc-create": (32, "−32%", True), "proc-widen": (79, "−79%", True),
                      "proc-reviewed": (79, "−79%", True), "desktop": (78, "−78%", True),
                      "naive": (1, "−1%", True), "stats": (-0.3, "+0.3%", True)},
    "tpch10-realistic": {"proc-create": (86, "−86%", True), "proc-widen": None, "proc-reviewed": (86, "−86%", True),
                         "desktop": (85, "−85%", True), "naive": (86, "−86%", True), "stats": (59, "−59%", True)},
}

# Total execution time. beyond=False where BENCHMARK.md makes no claim.
TIME = {
    "challenge": {"proc-create": (63.9, "−64%", True), "proc-widen": None, "proc-reviewed": (76.6, "−77%", True),
                  "desktop": (72.4, "−72%", True), "naive": (70.7, "−71%", True), "stats": (0, "0%", False)},
    "sqlstorm-oltp": {"proc-create": (25.1, "−25%", True), "proc-widen": (43.1, "−43%", True),
                      "proc-reviewed": (39.2, "−39%", True), "desktop": (38.0, "−38%", True),
                      "naive": (13.9, "−14%", True), "stats": (12.9, "−13%*", False)},
    "tpch10-realistic": {"proc-create": (14.2, "−14%", False), "proc-widen": None,
                         "proc-reviewed": (14.9, "−15%", False), "desktop": (21.1, "−21%", False),
                         "naive": (14.1, "−14%", False), "stats": (16.5, "−17%", False)},
}

impact_chart(
    "benchmark-reads",
    "How much less data the read queries touch",
    "Change in logical reads after tuning, mean of 5 trials. Longer bar = bigger saving.",
    "Logical-read reduction per arm and scenario. The proc's applied advice is at or near the best arm in all "
    "three scenarios; the missing-index baseline is near-best on challenge and useless on sqlstorm-oltp.",
    READS, {"challenge": 0.002, "sqlstorm-oltp": 0.04, "tpch10-realistic": 0.03},
    "Noise floors are 0.002–0.04%, so every bar is a real change. CREATE mode + widenings was measured on sqlstorm-oltp only.",
    hatched=False,
)

impact_chart(
    "benchmark-time",
    "How much faster the whole workload ran",
    "Change in total execution time (reads and writes), mean of 5 trials. Shaded band = noise floor.",
    "Total execution time reduction per arm and scenario, with each scenario's noise floor. challenge and "
    "sqlstorm-oltp show real gains; on tpch10-realistic every arm is inside the 22.2% noise floor.",
    TIME, {"challenge": 10.6, "sqlstorm-oltp": 8.1, "tpch10-realistic": 22.2},
    "* −1.8% without one outlier trial, so no claim is made. tpch10-realistic: all changes are inside its 22.2% floor.",
    hatched=True,
)


# ---------------------------------------------------------------------------
def space_chart():
    W, H = 1600, 760
    s = header(W, H, "Similar read savings, a tenth of the index space",
               "On the challenge scenario: net index space added (bars) and the logical-read saving it bought.",
               "On the challenge scenario, applying all the proc's advice cut reads by 93% with 206 MB of new "
               "index space; creating every missing-index suggestion cut 90% with 2,075 MB.")
    rows = [("All proc advice applied", 206, "−93% reads", True),
            ("CREATE mode (applies itself)", 328, "−79% reads", True),
            ("AI SQL Tuner desktop app", 465, "−83% reads", False),
            ("Every missing-index suggestion", 2075, "−90% reads", False)]
    left, top, row_h, bar_h = 340, 200, 100, 44
    scale = 1000 / 2100
    bottom = top + len(rows) * row_h
    for t in (0, 500, 1000, 1500, 2000):
        gx = left + t * scale
        s.append(f'  <line x1="{gx:.1f}" y1="{top}" x2="{gx:.1f}" y2="{bottom}" stroke="{GRID}"/>')
        s.append(f'  <text x="{gx:.1f}" y="{bottom + 24}" font-size="13" fill="{MUTED}" text-anchor="middle">'
                 f'{t:,} MB</text>')
    for i, (label, mb, red, proc) in enumerate(rows):
        y = top + i * row_h + (row_h - bar_h) / 2
        cy = y + bar_h / 2 + 6
        s.append(f'  <text x="{left - 16}" y="{cy}" font-size="17" font-weight="{"700" if proc else "400"}" '
                 f'fill="{TEXT}" text-anchor="end">{esc(label)}</text>')
        length = mb * scale
        s.append(bar(left, y, length, bar_h, PROC if proc else OTHER))
        s.append(f'  <text x="{left + length + 10:.1f}" y="{cy}" font-size="18" font-weight="700" fill="{TEXT}">'
                 f'{mb:,} MB</text>')
        s.append(f'  <text x="{left + length + 10 + 11 * len(f"{mb:,} MB"):.1f}" y="{cy}" font-size="17" '
                 f'fill="{MUTED}">→ {red}</text>')
    s.append(f'  <text x="40" y="{H - 28}" font-size="14" fill="{MUTED}">Mean of 5 trials. Space is net of any '
             f'indexes the advice dropped. Database size: 1.8 GB.</text>')
    s.append("</svg>")
    (OUT / "benchmark-space.svg").write_text("\n".join(x for x in s if x) + "\n", encoding="utf-8")


def rubric_chart():
    W, H = 1600, 1056
    s = header(W, H, "Are the recommendations right?",
               "Share of rubric checks passed across 5 runs per batch, on 16 known tuning problems.",
               "Rubric scores by batch. Required and forbidden checks: 91.3%, 95.3%, 94.7%, 100% (gpt-6.2-sol), "
               "99.3%, 100% and 100% (gpt-6.2-sol low and high). Preferred checks: 85.7%, 68.6%, 80.0%, 85.7%, "
               "88.6%, 85.7% and 85.7%.")
    s += legend(40, 160, [(PROC, "Must-do and must-never-do checks (the score that matters)"),
                          ("#9ec5f4", "Preferred checks (better among acceptable answers)")])
    batches = [("Batch 2", "build A11117F5", 91.3, 85.7), ("Batch 3", "build D6C7E42C", 95.3, 68.6),
               ("Batch 4", "build D6C7E42C", 94.7, 80.0),
               ("Batch 5", "v1.1.1, gpt-6.2-sol", 100.0, 85.7), ("Batch 6", "v1.1.1", 99.3, 88.6),
               ("Batch 7", "v1.1.1, gpt-6.2-sol low", 100.0, 85.7), ("Batch 8", "v1.1.1, gpt-6.2-sol high", 100.0, 85.7)]
    left, top, group_h, bar_h = 260, 200, 108, 44
    scale = 1150 / 100
    bottom = top + len(batches) * group_h
    for t in (0, 25, 50, 75, 100):
        gx = left + t * scale
        s.append(f'  <line x1="{gx:.1f}" y1="{top}" x2="{gx:.1f}" y2="{bottom}" stroke="{GRID}"/>')
        s.append(f'  <text x="{gx:.1f}" y="{bottom + 24}" font-size="13" fill="{MUTED}" text-anchor="middle">{t}%</text>')
    for i, (b, build, req, pref) in enumerate(batches):
        y = top + i * group_h + 16
        s.append(f'  <text x="{left - 16}" y="{y + bar_h - 4}" font-size="19" font-weight="700" fill="{TEXT}" '
                 f'text-anchor="end">{b}</text>')
        s.append(f'  <text x="{left - 16}" y="{y + bar_h + 18}" font-size="14" fill="{MUTED}" text-anchor="end">{build}</text>')
        s.append(bar(left, y, req * scale, bar_h, PROC))
        s.append(f'  <text x="{left + req * scale + 10:.1f}" y="{y + bar_h / 2 + 7}" font-size="19" font-weight="700" '
                 f'fill="{TEXT}">{req:g}%</text>')
        y2 = y + bar_h + 2 + 8
        s.append(bar(left, y2, pref * scale, 30, "#9ec5f4"))
        s.append(f'  <text x="{left + pref * scale + 10:.1f}" y="{y2 + 21}" font-size="16" fill="{TEXT}">{pref}%</text>')
    s.append(f'  <text x="40" y="{H - 28}" font-size="14" fill="{MUTED}">With 5 runs per check, one run is 20 '
             f'points, so the gap between batches 3 and 4 is run-to-run variance. Batches 5, 7 and 8 use gpt-6.2-sol; the rest gpt-5.6-luna. All at medium unless noted.</text>')
    s.append("</svg>")
    (OUT / "benchmark-rubric.svg").write_text("\n".join(x for x in s if x) + "\n", encoding="utf-8")


space_chart()
rubric_chart()
print("wrote", ", ".join(sorted(p.name for p in OUT.glob("benchmark-*.svg"))))
