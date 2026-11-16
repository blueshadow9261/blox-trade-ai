class_name TradeEngine
extends RefCounted
## Pure calculation engine. Shared by the manual calculator and (later) live analysis.

enum Result { WIN, FAIR, LOSS, UNKNOWN }

static func total(items: Array) -> Dictionary:
	var sum := 0.0
	var missing := 0
	for it in items:
		var v = it.get("value", null)
		if v == null:
			missing += 1
		else:
			sum += float(v)
	return {"sum": sum, "missing": missing}

static func evaluate(mine: Array, theirs: Array, threshold_pct: float = 5.0) -> Dictionary:
	var m := total(mine)
	var t := total(theirs)
	var diff: float = t.sum - m.sum
	var pct = null
	var res: int = Result.UNKNOWN
	var note := ""
	if mine.is_empty() and theirs.is_empty():
		note = "Both offers are empty."
	elif m.missing > 0 or t.missing > 0:
		note = "%d item(s) have no value data, so no verdict is given." % (m.missing + t.missing)
	elif m.sum <= 0.0:
		if t.sum > 0.0:
			res = Result.WIN
		else:
			res = Result.FAIR
	else:
		pct = diff / m.sum * 100.0
		if absf(pct) <= threshold_pct:
			res = Result.FAIR
		elif pct > 0.0:
			res = Result.WIN
		else:
			res = Result.LOSS
	return {"mine": m.sum, "theirs": t.sum, "diff": diff, "pct": pct,
		"result": res, "missing": m.missing + t.missing, "note": note,
		"warnings": warnings(mine + theirs)}

## Data-quality warnings for the items in a trade (market data confidence).
static func warnings(items: Array) -> Array:
	var out: Array = []
	for it in items:
		var st: String = str(it.get("status", ""))
		var nm: String = str(it.get("name", "?"))
		if st == "conflict":
			out.append("%s: sources disagree on its value" % nm)
		elif st == "needs_review":
			out.append("%s: value changed sharply, verify before trading" % nm)
		elif st == "partial" and it.get("variant", "physical") == "physical":
			out.append("%s: only partly verified" % nm)
	return out

static func label(res: int) -> String:
	match res:
		Result.WIN: return "WIN - their offer is worth more"
		Result.FAIR: return "FAIR - offers are close"
		Result.LOSS: return "LOSS - your offer is worth more"
	return "UNKNOWN"
