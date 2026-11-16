"""Fallback parser for eggvalues.com/blox-fruits/values/ (public HTML tables, no API).

Written from the page's described layout, NOT against saved raw HTML (the build sandbox could not
reach the site). It is header-driven: it finds the table whose header row has 'Physical value' and
'Permanent value' and reads columns by header text, so column order does not matter. If the headers
are missing it raises ParseError and the run fails closed. Verify with `python -m collector.run --diagnose`.
"""
import re
from html.parser import HTMLParser
from . import parse

class _Tables(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.tables, self._t, self._row, self._cell, self._skip = [], None, None, None, 0

    def handle_starttag(self, tag, attrs):
        if tag in ("script", "style", "noscript"):
            self._skip += 1
        elif tag == "table":
            self._t = []
        elif tag == "tr" and self._t is not None:
            self._row = []
        elif tag in ("td", "th") and self._row is not None:
            self._cell = []

    def handle_endtag(self, tag):
        if tag in ("script", "style", "noscript") and self._skip:
            self._skip -= 1
        elif tag in ("td", "th") and self._cell is not None and self._row is not None:
            self._row.append(" ".join("".join(self._cell).split()))
            self._cell = None
        elif tag == "tr" and self._row is not None and self._t is not None:
            if self._row:
                self._t.append(self._row)
            self._row = None
        elif tag == "table" and self._t is not None:
            self.tables.append(self._t)
            self._t = None

    def handle_data(self, data):
        if not self._skip and self._cell is not None:
            self._cell.append(data)

def slugify(name):
    s = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")
    return s

def name_key(name):
    """Order-insensitive key so 'Dragon (West)' matches 'West Dragon'."""
    return " ".join(sorted(re.findall(r"[a-z0-9]+", name.lower())))

def _amount(cell):
    m = re.match(r"\s*(\d[\d.,]*[KMBT]?)\b", cell or "", re.I)
    return parse.parse_amount(m.group(1)) if m else None

def _demand(cell):
    m = re.match(r"\s*(\d{1,2})\s*/\s*10\b", cell or "")
    return int(m.group(1)) if m and int(m.group(1)) <= 10 else None

def parse_values_page(html):
    """Returns [{name, physical_value, permanent_value, physical_demand, permanent_demand, fruit_type, flags}]."""
    p = _Tables()
    p.feed(html)
    for t in p.tables:
        head = [c.lower() for c in t[0]]
        def col(*words):
            for i, h in enumerate(head):
                if all(w in h for w in words):
                    return i
            return None
        pv, mv = col("physical", "value"), col("permanent", "value")
        if pv is None or mv is None:
            continue
        pd, md, ty = col("physical", "demand"), col("permanent", "demand"), col("type")
        out = []
        for r in t[1:]:
            if len(r) <= max(pv, mv) or not r[0].strip():
                continue
            phys = _amount(r[pv])
            if phys is None:
                continue                       # no usable physical value -> skip the row
            flags = ["fallback source: eggvalues.com"]
            if any("disagree" in c.lower() for c in r):
                flags.append("eggvalues: lists disagree")
            out.append({
                "name": r[0].strip(), "physical_value": phys, "permanent_value": _amount(r[mv]),
                "physical_demand": _demand(r[pd]) if pd is not None and pd < len(r) else None,
                "permanent_demand": _demand(r[md]) if md is not None and md < len(r) else None,
                "fruit_type": r[ty].strip() if ty is not None and ty < len(r) else None,
                "flags": flags})
        if out:
            return out
    raise parse.ParseError("eggvalues: no fruit table with Physical/Permanent value columns found")
