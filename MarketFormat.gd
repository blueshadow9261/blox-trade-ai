class_name MarketFormat
extends RefCounted
## Display helpers shared by all tabs.

static func compact(v) -> String:
	if v == null:
		return "n/a"
	var f := float(v)
	if f < 0.0:
		return "-" + compact(-f)
	var units := [[1e12, "T"], [1e9, "B"], [1e6, "M"], [1e3, "K"]]
	for u in units:
		if f >= u[0]:
			var s := "%.2f" % (f / u[0])
			s = s.rstrip("0").rstrip(".") if s.contains(".") else s
			return s + u[1]
	return str(int(f))

static func ago(unix: int) -> String:
	if unix <= 0:
		return "never"
	var s := int(Time.get_unix_time_from_system()) - unix
	if s < 0:
		s = 0
	if s < 60:
		return "just now"
	if s < 3600:
		return "%d min ago" % int(s / 60.0)
	if s < 86400:
		return "%d h ago" % int(s / 3600.0)
	return "%d d ago" % int(s / 86400.0)

static func trend_glyph(t: String) -> String:
	match t:
		"rising": return "▲"
		"dropping": return "▼"
		"overpaid": return "◆"
		"stable": return "■"
	return "?"

static func trend_color(t: String) -> Color:
	match t:
		"rising": return Color("34d399")
		"dropping": return Color("f87171")
		"overpaid": return Color("fbbf24")
	return Color("93a1c0")

static func pct_text(p) -> String:
	return "" if p == null else "%+.1f%%" % float(p)

static func status_badge(s: String) -> String:
	match s:
		"needs_review": return "⚠ review"
		"conflict": return "⚠ sources disagree"
		"partial": return "partial"
	return ""
