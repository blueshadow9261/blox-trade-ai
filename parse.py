"""Pure parsing functions (no network). Built against the rendered text of
bloxfruitsvalues.gg list/rarity pages and fruit detail pages. If the site layout changes the
parsers return nothing / raise ParseError and the run fails closed (cache untouched)."""
import re
from datetime import datetime
from decimal import Decimal, InvalidOperation
from html.parser import HTMLParser

class ParseError(Exception):
    pass

_SUFFIX = {"": 1, "K": 10**3, "M": 10**6, "B": 10**9, "T": 10**12}
NUM = r"\d[\d.,]*[KMBT]?"
RARITIES = ("common", "uncommon", "rare", "legendary", "mythical")
TRENDS = {"stable": "stable", "overpaid": "overpaid", "rising": "rising", "dropping": "dropping", "unstable": "unstable"}

def parse_amount(text):
    """'2.75B' -> 2750000000, '450,000,000' -> 450000000. Returns int or None.
    Never accepts negatives or non-numeric text."""
    if text is None:
        return None
    t = text.strip().replace(",", "").upper()
    m = re.fullmatch(r"(\d+(?:\.\d+)?)([KMBT]?)", t)
    if not m:
        return None
    try:
        v = Decimal(m.group(1)) * _SUFFIX[m.group(2)]
    except InvalidOperation:
        return None
    if v != v.to_integral_value():
        return None
    return int(v)

class _Stream(HTMLParser):
    """Flattens a page into one text stream, with markers for card links and images."""
    LINK = re.compile(r"^(?:https://bloxfruitsvalues\.gg)?/values/([a-z0-9][a-z0-9-]*)/?$")
    IMG = re.compile(r"^(?:https://bloxfruitsvalues\.gg)?/fruits/[A-Za-z0-9._-]+\.webp$")

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.parts, self.meta, self._skip = [], {}, 0

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag in ("script", "style", "noscript"):
            self._skip += 1
        elif tag == "meta":
            key = a.get("name") or a.get("property")
            if key and a.get("content"):
                self.meta[key] = a["content"]
        elif tag == "a" and a.get("href"):
            m = self.LINK.match(a["href"])
            if m and m.group(1) != "rarity":
                self.parts.append(" @@SLUG:%s@@ " % m.group(1))
        elif tag == "img" and a.get("src") and self.IMG.match(a["src"]):
            src = a["src"] if a["src"].startswith("http") else "https://bloxfruitsvalues.gg" + a["src"]
            self.parts.append(" @@IMG:%s@@ " % src)

    def handle_endtag(self, tag):
        if tag in ("script", "style", "noscript") and self._skip:
            self._skip -= 1
        self.parts.append(" ")

    def handle_data(self, data):
        if not self._skip:
            self.parts.append(" " + data + " ")

def page_stream(html):
    p = _Stream()
    p.feed(html)
    p.close()
    return re.sub(r"\s+", " ", "".join(p.parts)).strip(), p.meta

_CARD = re.compile(
    r"@@SLUG:(?P<slug>[a-z0-9-]+)@@ (?:@@IMG:(?P<img>\S+?)@@ )?"
    r"(?:(?P<rarity>Common|Uncommon|Rare|Legendary|Mythical) )?"
    r"(?:@@SLUG:(?P=slug)@@ )?(?:@@IMG:\S+?@@ )?"
    r"(?P<name>[^@]+?) (?P<ftype>[A-Za-z]+) Regular Permanent "
    r"(?P<value>" + NUM + r")\s*(?P<trend>Stable|Overpaid|Rising|Dropping)? ?"
    r"Demand\s*(?P<demand>\d{1,2})\s*/\s*10(?: Demand \d+ out of 10)?"
    r"(?: Dealer \$\s*(?P<beli>" + NUM + r"))?")

_LIMITED = re.compile(
    r"@@SLUG:(?P<slug>[a-z0-9-]+)@@ (?:@@IMG:(?P<img>\S+?)@@ )?Limited "
    r"@@SLUG:(?P=slug)@@ (?:@@IMG:\S+?@@ )?(?P<name>[^@]+?) Limited "
    r"(?P<value>" + NUM + r")\s*(?P<trend>Stable|Overpaid|Rising|Dropping|Unstable)? ?"
    r"Demand\s*(?P<demand>\d{1,2})\s*/\s*10")

def parse_limited_cards(html):
    """Cards labelled 'Limited' on the main /values page (no Regular/Permanent toggle). Returns [] if none."""
    text, _ = page_stream(html)
    out, seen = [], set()
    for m in _LIMITED.finditer(text):
        slug = m.group("slug")
        value = parse_amount(m.group("value"))
        if slug in seen or value is None or int(m.group("demand")) > 10:
            continue
        seen.add(slug)
        out.append({"id": slug, "name": m.group("name").strip(), "image": m.group("img"),
                    "physical_value": value, "physical_demand": int(m.group("demand")),
                    "market_trend": TRENDS.get((m.group("trend") or "").lower(), "unknown")})
    return out

def parse_list_page(html, tier):
    """Return list of raw cards for one rarity page. Raises ParseError if the card count does
    not match the page's own 'N items' counter (guards against partial/changed layouts)."""
    text, _ = page_stream(html)
    cards, seen = [], set()
    for m in _CARD.finditer(text):
        slug = m.group("slug")
        if slug in seen:
            continue
        seen.add(slug)
        value = parse_amount(m.group("value"))
        cards.append({
            "id": slug,
            "name": m.group("name").strip(),
            "image": m.group("img"),
            "rarity": (m.group("rarity") or tier).lower(),
            "fruit_type": m.group("ftype").lower(),
            "physical_value": value,
            "market_trend": TRENDS.get((m.group("trend") or "").lower()),
            "physical_demand": int(m.group("demand")),
            "beli_price": parse_amount(m.group("beli")) if m.group("beli") else None,
        })
    n = re.search(r"\b(\d+) items\b", text)
    if not n:
        raise ParseError("rarity/%s: item counter not found" % tier)
    if int(n.group(1)) != len(cards):
        raise ParseError("rarity/%s: page says %s items, parsed %d" % (tier, n.group(1), len(cards)))
    return cards

def parse_detail_page(html, slug):
    """Detail enrichment: exact physical value, permanent value, Robux price, revision date."""
    text, meta = page_stream(html)
    desc = meta.get("description") or meta.get("og:description") or ""
    out = {"id": slug, "permanent_value": None, "physical_value": None,
           "robux_price": None, "beli_price": None, "last_updated": None,
           "physical_demand": None, "exact_value": None, "notes": []}
    d = re.search(r"is worth (?:(?P<perm>" + NUM + r") permanent and )?(?P<phys>" + NUM +
                  r") physical.*?with (?P<dem>\d{1,2})/10 demand", desc)
    if not d:
        raise ParseError("detail/%s: summary sentence not found" % slug)
    out["permanent_value"] = parse_amount(d.group("perm")) if d.group("perm") else None
    out["physical_value"] = parse_amount(d.group("phys"))
    out["physical_demand"] = int(d.group("dem"))
    ex = re.search(r"(\d[\d,]*) exactly", text)
    if ex:
        out["exact_value"] = parse_amount(ex.group(1))
    b = re.search(r"Dealer price \$(\d[\d,]*)", text)
    if b:
        out["beli_price"] = parse_amount(b.group(1))
    r = re.search(r"Robux R\$(\d[\d,]*)", text)
    if r:
        out["robux_price"] = parse_amount(r.group(1))
    lr = re.search(r"last revised on ([A-Z][a-z]+ \d{1,2}, \d{4})", text)
    if lr:
        try:
            out["last_updated"] = datetime.strptime(lr.group(1), "%B %d, %Y").strftime("%Y-%m-%d")
        except ValueError:
            pass
    # in-page consistency: compact summary value must agree with the exact value
    if out["exact_value"] and out["physical_value"]:
        if abs(out["exact_value"] - out["physical_value"]) > 0.01 * out["exact_value"]:
            out["notes"].append("summary and exact physical value disagree")
        else:
            out["physical_value"] = out["exact_value"]
    return out
