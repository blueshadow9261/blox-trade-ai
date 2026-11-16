import json, os, tempfile, unittest
from collector import config, egg, merge, parse, providers, run as runner, validate

def card(slug, name, rarity, ftype, value, trend, demand, beli):
    return ('<div><a href="/values/%s"><img src="/fruits/%s.webp" alt=""><span>%s</span></a>'
            '<a href="/values/%s">%s</a><p>%s</p><div><span>Regular</span><span>Permanent</span></div>'
            '<div>%s<b>%s</b></div><div>Demand<span>%s/10</span><i>Demand %s out of 10</i></div>'
            '<div>Dealer<span>$%s</span></div></div>') % (
            slug, slug, rarity, slug, name, ftype, value, trend, demand, demand, beli)

def list_page(cards, n=None):
    return "<html><body><h1>x</h1><p>%s items</p>%s<script>var a='Regular Permanent';</script></body></html>" % (
        len(cards) if n is None else n, "".join(cards))

MAGMA = card("magma", "Magma", "Rare", "Elemental", "1.15M", "Overpaid", 7, "960K")
QUAKE = card("quake", "Quake", "Legendary", "Natural", "1M", "Stable", 3, "1M")   # value == dealer price
DRAGON = card("dragon-west", "West Dragon", "Mythical", "Beast", "2.75B", "Stable", 8, "15M")

def detail_page(summary, body):
    return ('<html><head><meta name="description" content="%s"></head><body>%s</body></html>' % (summary, body))

KIT = detail_page(
    "Kitsune is worth 3.95B permanent and 450M physical in Blox Fruits, with 10/10 demand. See more.",
    "<h1>Kitsune</h1><div>450M</div><div>450,000,000 exactly</div><div>Dealer price<span>$8,000,000</span></div>"
    "<div>Robux<span>R$4,000</span></div><p>Kitsune is worth 3.95B permanent and 450M physical, last revised on November 5, 2026.</p>")

class Amounts(unittest.TestCase):
    def test_ok(self):
        self.assertEqual(parse.parse_amount("2.75B"), 2_750_000_000)
        self.assertEqual(parse.parse_amount("800K"), 800_000)
        self.assertEqual(parse.parse_amount("1.15M"), 1_150_000)
        self.assertEqual(parse.parse_amount("450,000,000"), 450_000_000)
    def test_rejects(self):
        for bad in ("-5M", "abc", "", None, "1.5", "$5M", "5MM"):
            self.assertIsNone(parse.parse_amount(bad), bad)

class ListParsing(unittest.TestCase):
    def test_cards(self):
        c = parse.parse_list_page(list_page([MAGMA, DRAGON]), "rare")
        self.assertEqual([x["id"] for x in c], ["magma", "dragon-west"])
        self.assertEqual(c[1]["name"], "West Dragon")
        self.assertEqual(c[1]["physical_value"], 2_750_000_000)
        self.assertEqual(c[1]["rarity"], "mythical")
        self.assertEqual(c[0]["market_trend"], "overpaid")
        self.assertEqual(c[0]["image"], "https://bloxfruitsvalues.gg/fruits/magma.webp")
    def test_dealer_price_never_becomes_value(self):
        q = parse.parse_list_page(list_page([card("quake", "Quake", "Legendary", "Natural", "2M", "Stable", 3, "9M")]), "legendary")[0]
        self.assertEqual(q["physical_value"], 2_000_000)
        self.assertEqual(q["beli_price"], 9_000_000)
    def test_count_mismatch_fails_closed(self):
        with self.assertRaises(parse.ParseError):
            parse.parse_list_page(list_page([MAGMA], n=4), "rare")
    def test_layout_change_fails_closed(self):
        with self.assertRaises(parse.ParseError):
            parse.parse_list_page("<html><body>3 items <div>different layout</div></body></html>", "rare")

class DetailParsing(unittest.TestCase):
    def test_full(self):
        d = parse.parse_detail_page(KIT, "kitsune")
        self.assertEqual((d["physical_value"], d["permanent_value"]), (450_000_000, 3_950_000_000))
        self.assertEqual((d["beli_price"], d["robux_price"]), (8_000_000, 4000))
        self.assertEqual(d["last_updated"], "2026-11-05")
        self.assertEqual(d["physical_demand"], 10)
    def test_missing_permanent_is_null(self):
        h = detail_page("Foo is worth 5M physical in Blox Fruits, with 3/10 demand.", "<p>x</p>")
        self.assertIsNone(parse.parse_detail_page(h, "foo")["permanent_value"])
    def test_inconsistent_values_noted(self):
        h = detail_page("Foo is worth 5M physical in Blox Fruits, with 3/10 demand.", "<p>9,000,000 exactly</p>")
        self.assertTrue(parse.parse_detail_page(h, "foo")["notes"])
    def test_summary_missing_raises(self):
        with self.assertRaises(parse.ParseError):
            parse.parse_detail_page("<html><body>nothing</body></html>", "foo")

def rec(**kw):
    r = {"id": "kitsune", "name": "Kitsune", "image": "https://x/y.webp", "rarity": "mythical",
         "fruit_type": "beast", "physical_value": 100, "permanent_value": None, "physical_demand": 5,
         "permanent_demand": None, "beli_price": 8, "robux_price": None, "market_trend": "stable",
         "last_updated": "2026-11-05", "source": "a", "confidence_status": "verified"}
    r.update(kw); return r

class Validation(unittest.TestCase):
    def test_valid(self): self.assertEqual(validate.validate_fruit(rec()), [])
    def test_negative_rejected(self):
        self.assertTrue(validate.validate_fruit(rec(physical_value=-1)))
        self.assertTrue(validate.validate_fruit(rec(permanent_value=-5)))
    def test_bool_and_float_rejected(self):
        self.assertTrue(validate.validate_fruit(rec(physical_value=True)))
        self.assertTrue(validate.validate_fruit(rec(physical_value=1.5)))
    def test_null_permanent_ok_null_physical_not(self):
        self.assertEqual(validate.validate_fruit(rec(permanent_value=None)), [])
        self.assertTrue(validate.validate_fruit(rec(physical_value=None)))
    def test_missing_field(self):
        r = rec(); del r["rarity"]; self.assertTrue(validate.validate_fruit(r))
    def test_demand_range(self): self.assertTrue(validate.validate_fruit(rec(physical_demand=11)))
    def test_duplicate_and_partial_scrape(self):
        self.assertTrue(validate.validate_batch([rec(), rec()], 0))
        many = [rec(id="f%d" % i) for i in range(3)]
        self.assertTrue(validate.validate_batch(many, 10))
    def test_large_change_flagged(self):
        new = {"kitsune": rec(physical_value=300)}
        flagged = validate.flag_large_changes(new, {"kitsune": rec(physical_value=100)})
        self.assertEqual(flagged, ["kitsune"]); self.assertEqual(new["kitsune"]["confidence_status"], "needs_review")

class MergeDiff(unittest.TestCase):
    def test_conflict_is_reported_not_averaged(self):
        recs, conf = merge.merge_sources([rec(physical_value=100)], {"b": [rec(physical_value=200, source="b")]})
        self.assertEqual(recs[0]["physical_value"], 100)
        self.assertEqual(recs[0]["confidence_status"], "conflict")
        self.assertEqual(conf[0]["values"], {"a": 100, "b": 200})
    def test_within_tolerance_no_conflict(self):
        _, conf = merge.merge_sources([rec(physical_value=1000)], {"b": [rec(physical_value=1005)]})
        self.assertEqual(conf, [])
    def test_diff_events(self):
        old = {"a": rec(id="a", name="A"), "gone": rec(id="gone", name="Gone"), "r": rec(id="r", name="Old")}
        new = {"a": rec(id="a", name="A", physical_value=150, physical_demand=7, market_trend="rising"),
               "new": rec(id="new", name="New"), "r": rec(id="r", name="Renamed")}
        types = sorted((e["type"], e["id"]) for e in merge.diff(old, new, "t"))
        self.assertEqual(types, [("added", "new"), ("demand", "a"), ("removed", "gone"),
                                 ("renamed", "r"), ("trend", "a"), ("value", "a")])

class FakeProvider:
    name = "fake"
    def __init__(self, ok, fruits=None, error=None): self.r = providers.ProviderResult("fake", ok, fruits, error)
    def collect(self, prev, now): return self.r

class RunFlow(unittest.TestCase):
    def test_failure_keeps_cache(self):
        with tempfile.TemporaryDirectory() as d:
            code, _ = runner.run(d, FakeProvider(True, [rec(id="a"), rec(id="b")]), [], "2026-11-15T00:00:00Z")
            self.assertEqual(code, 0)
            before = open(os.path.join(d, "latest.json")).read()
            code, st = runner.run(d, FakeProvider(False, error="HTTP 503"), [], "2026-11-15T00:30:00Z", fallback=None)
            self.assertEqual(code, 1)
            self.assertEqual(open(os.path.join(d, "latest.json")).read(), before)
            self.assertFalse(json.load(open(os.path.join(d, "status.json")))["ok"])
    def test_invalid_data_rejected(self):
        with tempfile.TemporaryDirectory() as d:
            runner.run(d, FakeProvider(True, [rec(id="a"), rec(id="b")]), [], "2026-11-15T00:00:00Z")
            before = open(os.path.join(d, "latest.json")).read()
            code, _ = runner.run(d, FakeProvider(True, [rec(id="a", physical_value=-3), rec(id="b")]), [], "2026-11-15T00:30:00Z")
            self.assertEqual(code, 1); self.assertEqual(open(os.path.join(d, "latest.json")).read(), before)
    def test_history_written_and_flag(self):
        with tempfile.TemporaryDirectory() as d:
            runner.run(d, FakeProvider(True, [rec(id="a"), rec(id="b")]), [], "2026-11-15T00:00:00Z")
            runner.run(d, FakeProvider(True, [rec(id="a", physical_value=400), rec(id="b")]), [], "2026-11-15T00:30:00Z")
            ev = json.load(open(os.path.join(d, "history.json"), encoding="utf-8"))["events"]
            self.assertEqual(ev[0]["type"], "value")
            snap = json.load(open(os.path.join(d, "latest.json")))
            self.assertEqual(snap["review"], ["a"]); self.assertEqual(snap["data_freshness"], "periodic_snapshot")

class Robots(unittest.TestCase):
    def _fetcher(self, robots_status, robots_body):
        f = providers.Fetcher("https://example.test"); f.delay = 0
        def raw(url, accept="text/html"):
            return (robots_status, robots_body) if url.endswith("/robots.txt") else (200, "ok")
        f._raw = raw; return f
    def test_disallowed(self):
        with self.assertRaises(providers.FetchError):
            self._fetcher(200, "User-agent: *\nDisallow: /values").get("/values/rarity/rare")
    def test_missing_robots_allows(self):
        self.assertEqual(self._fetcher(404, "").get("/values"), "ok")
    def test_robots_server_error_fails_closed(self):
        with self.assertRaises(providers.FetchError):
            self._fetcher(503, "").get("/values")
    def test_http_rejected(self):
        with self.assertRaises(providers.FetchError): providers.Fetcher("http://example.test")

class ProviderBuild(unittest.TestCase):
    def test_end_to_end_with_fake_fetcher(self):
        pages = {"/values/rarity/mythical": list_page([DRAGON]), "/values/rarity/legendary": list_page([QUAKE]),
                 "/values/rarity/rare": list_page([MAGMA]), "/values/rarity/uncommon": list_page([], 0) ,
                 "/values/rarity/common": list_page([], 0), "/values/dragon-west": detail_page(
                     "West Dragon is worth 9B permanent and 2.75B physical in Blox Fruits, with 8/10 demand.",
                     "<div>2,750,000,000 exactly</div><div>Dealer price<span>$15,000,000</span></div>"
                     "<p>last revised on November 5, 2026.</p>")}
        class F:
            count = 0
            def get(self, p):
                self.count += 1
                if p not in pages: raise providers.FetchError("HTTP 404 " + p)
                return pages[p]
        r = providers.BloxFruitsValuesProvider(F()).collect({}, "2026-11-15T10:00:00Z")
        self.assertTrue(r.ok, r.error)
        by = {f["id"]: f for f in r.fruits}
        self.assertEqual(by["dragon-west"]["permanent_value"], 9_000_000_000)
        self.assertEqual(by["dragon-west"]["confidence_status"], "verified")
        self.assertIsNone(by["quake"]["permanent_value"])          # detail page 404 -> null, not invented
        self.assertEqual(by["quake"]["confidence_status"], "partial")
        self.assertEqual(by["quake"]["beli_price"], 1_000_000)     # Beli stays separate from value
        self.assertEqual(validate.validate_batch(r.fruits, 0), [])
    def test_list_detail_mismatch_flagged(self):
        pages = {"/values/rarity/mythical": list_page([DRAGON])}
        pages["/values/dragon-west"] = KIT   # 450M detail vs 2.75B list
        for t in ("legendary", "rare", "uncommon", "common"): pages["/values/rarity/" + t] = list_page([], 0)
        class F:
            count = 0
            def get(self, p): return pages[p]
        r = providers.BloxFruitsValuesProvider(F()).collect({}, "2026-11-15T10:00:00Z")
        self.assertEqual(r.fruits[0]["confidence_status"], "needs_review")
    def test_one_bad_tier_fails_whole_run(self):
        class F:
            count = 0
            def get(self, p): return "<html>3 items</html>"
        self.assertFalse(providers.BloxFruitsValuesProvider(F()).collect({}, "2026-11-15T10:00:00Z").ok)


EGG_PAGE = """<html><body><table><tr><th>Fruit</th><th>Type</th><th>Physical value</th><th>Physical demand</th>
<th>Permanent value</th><th>Permanent demand</th></tr>
<tr><td><a href="/x">Dragon (West)</a></td><td>Beast</td><td>2.76B Lists disagree</td><td>9/10</td><td>5.04B</td><td>9/10</td></tr>
<tr><td>Venom</td><td>Natural</td><td>120M</td><td>10/10</td><td>Not published</td><td>4/10</td></tr>
<tr><td>Brand New</td><td>Natural</td><td>1M</td><td>1/10</td><td>2M</td><td>1/10</td></tr>
<tr><td>Broken</td><td>Natural</td><td>n/a</td><td>1/10</td><td>2M</td><td>1/10</td></tr></table></body></html>"""

REAL_EGG = ('<div class="tblwrap"><table><thead><tr><th>Fruit</th><th>Type</th><th class="num">Physical value</th>'
 '<th>Physical demand</th><th class="num">Permanent value</th><th>Permanent demand</th></tr></thead><tbody>'
 '<tr><td><img class="thumb" src="/a.webp" alt=""> <a href="/blox-fruits/fruits/dragon/">Dragon (West form)</a> '
 '<span class="chip">Lists disagree</span></td><td>Beast</td><td class="num gold">2.76B</td><td>9/10</td>'
 '<td class="num">5.04B</td><td>9/10</td></tr>'
 '<tr><td><a href="/x/venom/">Venom</a> <span class="chip">Lists disagree</span></td><td>Natural</td>'
 '<td class="num gold">120M</td><td>10/10</td><td class="num">Not published *</td><td>4/10</td></tr>'
 '<tr><td><a href="/x/gas/">Gas</a></td><td>Elemental</td><td class="num gold">60M</td><td>10/10</td>'
 '<td class="num">2.31B</td><td>7/10</td></tr></tbody></table></div>')

class RealEggMarkup(unittest.TestCase):
    def test_real_layout(self):
        rows = egg.parse_values_page(REAL_EGG)
        self.assertEqual([r["name"] for r in rows], ["Dragon (West form)", "Venom", "Gas"])
        self.assertEqual(rows[0]["permanent_value"], 5_040_000_000)
        self.assertIsNone(rows[1]["permanent_value"])
        self.assertIn("eggvalues: lists disagree", rows[1]["flags"])
        self.assertEqual(egg.name_key("Dragon (West form)"), egg.name_key("West Dragon"))

REAL_CARD = ('<div class="group"><a class="art-wash" tabindex="-1" aria-hidden="true" href="/values/dragon-west">'
 '<img src="/fruits/dragon-west.webp" alt="" width="112" height="112" loading="lazy" class="x"/>'
 '<span class="chip"><span class="dot" aria-hidden="true"></span>Mythical</span></a>'
 '<div class="p"><div class="min-w-0"><a class="block truncate" href="/values/dragon-west">West Dragon</a><p class="t">Beast</p></div>'
 '<div role="group" aria-label="Price West Dragon as a regular or permanent copy"><button type="button">Regular</button>'
 '<button type="button">Permanent</button></div>'
 '<div class="flex"><span class="animate-pop">2.75B</span><span class="inline-flex"><svg width="15"><path d="M3.5 12h16"></path>'
 '<path d="M15.5 8l4 4-4 4"></path></svg>Stable</span></div>'
 '<div class="d"><span class="x">Demand</span><span title="Demand 8 out of 10"><span aria-hidden="true"><span class="b"></span></span>'
 '<span class="x">8<!-- -->/10</span><span class="sr-only">Demand <!-- -->8<!-- --> out of 10</span></span></div>'
 '<p class="mt-auto" title="$15,000,000"><span>Dealer</span><span>$<!-- -->15M</span></p></div></div>')

class RealSiteMarkup(unittest.TestCase):
    """Card markup copied from the live bloxfruitsvalues.gg page (Nov 2026): React splits '8/10' and '$15M'."""
    def test_real_card(self):
        page = '<html><body><span>1<!-- --> <!-- -->items</span>' + REAL_CARD + '</body></html>'
        c = parse.parse_list_page(page, "mythical")
        self.assertEqual(len(c), 1)
        self.assertEqual((c[0]["id"], c[0]["name"], c[0]["fruit_type"]), ("dragon-west", "West Dragon", "beast"))
        self.assertEqual((c[0]["physical_value"], c[0]["physical_demand"], c[0]["beli_price"]),
                         (2_750_000_000, 8, 15_000_000))
        self.assertEqual((c[0]["market_trend"], c[0]["rarity"]), ("stable", "mythical"))

class FakeFetcher:
    count = 1
    def __init__(self, body=None, err=None): self.body, self.err = body, err
    def get(self, path):
        if self.err: raise providers.FetchError(self.err)
        return self.body

class EggFallback(unittest.TestCase):
    def prev(self):
        return {"dragon-west": rec(id="dragon-west", name="West Dragon"), "venom": rec(id="venom", name="Venom"),
                "magma": rec(id="magma", name="Magma")}
    def test_parse_rows(self):
        rows = egg.parse_values_page(EGG_PAGE)
        self.assertEqual([r["name"] for r in rows], ["Dragon (West)", "Venom", "Brand New"])  # 'Broken' skipped
        self.assertEqual(rows[0]["physical_value"], 2_760_000_000)
        self.assertIn("eggvalues: lists disagree", rows[0]["flags"])
        self.assertIsNone(rows[1]["permanent_value"])
        self.assertEqual(rows[1]["permanent_demand"], 4)
    def test_no_table_fails_closed(self):
        with self.assertRaises(parse.ParseError):
            egg.parse_values_page("<html><body><p>layout changed</p></body></html>")
    def test_provider_matches_and_keeps_stale(self):
        r = providers.EggValuesProvider(FakeFetcher(EGG_PAGE)).collect(self.prev(), "2026-11-15T00:00:00Z")
        self.assertTrue(r.ok)
        by = {f["id"]: f for f in r.fruits}
        self.assertEqual(set(by), {"dragon-west", "venom", "magma"})      # 'Brand New' unknown -> skipped
        self.assertEqual(by["dragon-west"]["physical_value"], 2_760_000_000)   # name_key match
        self.assertEqual(by["dragon-west"]["source"], "eggvalues.com")
        self.assertEqual(by["magma"]["source"], rec(id="magma")["source"])
        self.assertIn("not refreshed by fallback", by["magma"]["flags"])
        self.assertEqual(validate.validate_batch(r.fruits, 3), [])
    def test_needs_previous_snapshot(self):
        self.assertFalse(providers.EggValuesProvider(FakeFetcher(EGG_PAGE)).collect({}, "2026-11-15T00:00:00Z").ok)
    def test_run_uses_fallback_only_when_primary_fails(self):
        with tempfile.TemporaryDirectory() as d:
            runner.run(d, FakeProvider(True, [rec(id="venom", name="Venom"), rec(id="magma", name="Magma")]), [], "2026-11-15T00:00:00Z", fallback=None)
            ok = providers.EggValuesProvider(FakeFetcher(EGG_PAGE))
            runner.run(d, FakeProvider(True, [rec(id="venom", name="Venom"), rec(id="magma", name="Magma")]), [], "2026-11-15T00:30:00Z", fallback=ok)
            self.assertNotEqual(json.load(open(d + "/latest.json"))["sources"][0]["name"], "eggvalues.com")
            code, st = runner.run(d, FakeProvider(False, error="HTTP 503"), [], "2026-11-15T01:00:00Z", fallback=ok)
            snap = json.load(open(d + "/latest.json"))
            self.assertEqual((code, st["fallback"]), (0, "eggvalues.com"))
            self.assertEqual(snap["sources"][0]["name"], "eggvalues.com")
            self.assertTrue(any("fallback" in n for n in snap["notes"]))
    def test_both_fail_keeps_cache(self):
        with tempfile.TemporaryDirectory() as d:
            runner.run(d, FakeProvider(True, [rec(id="venom", name="Venom"), rec(id="magma", name="Magma")]), [], "2026-11-15T00:00:00Z", fallback=None)
            before = open(d + "/latest.json").read()
            code, st = runner.run(d, FakeProvider(False, error="HTTP 503"), [],
                                  "2026-11-15T01:00:00Z", fallback=providers.EggValuesProvider(FakeFetcher(err="blocked")))
            self.assertEqual(code, 1)
            self.assertEqual(open(d + "/latest.json").read(), before)
            self.assertIn("fallback eggvalues.com", st["error"])

if __name__ == "__main__":
    unittest.main()
