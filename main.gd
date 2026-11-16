extends Control
## Landscape, neon "game" look: Home menu of tiles -> pages with a header bar (back arrow + title).
## Fruits are chosen through a tap-to-add picker overlay.

const SURFACE := Color("130f36")
const SURFACE_2 := Color("1d1855")
const SURFACE_3 := Color("2c2678")
const BORDER := Color("5a3fd8")
const ACCENT := Color("2f7bff")
const ACCENT_DARK := Color("1f5fd8")
const PINK := Color("d946ef")
const CYAN := Color("38bdf8")
const ORANGE := Color("fb923c")
const TEXT := Color("f1ecff")
const MUTED := Color("a79fd6")
const GOOD := Color("22e07a")
const WARN := Color("fbbf24")
const BAD := Color("ff5a6e")

const P_HOME := 0
const P_TRADE := 1
const P_VALUES := 2
const P_LIVE := 3
const P_HISTORY := 4
const P_MARKET := 5
const P_SETTINGS := 6
const SORT_KEYS := ["value", "demand", "name"]

# ---- state ----
var mine: Array = []
var theirs: Array = []
var threshold := 5.0
var current_page := P_HOME
var last_update_line := ""
var selected_id := ""
var selected_hist := -1
var val_mode := 0                # 0 all, 1 physical, 2 permanent
var card_by_id: Dictionary = {}

# ---- shell ----
var pages: Array = []
var status_lbls: Array = []
var refresh_btns: Array = []

# ---- market page ----
var home_left: RichTextLabel
var home_right: RichTextLabel

# ---- trade ----
var mine_list: VBoxContainer
var theirs_list: VBoxContainer
var mine_sum_lbl: Label
var theirs_sum_lbl: Label
var pct_lbl: Label
var verdict_lbl: Label
var verdict_sub_lbl: Label
var stats_lbl: Label
var detail_lbl: Label
var warn_lbl: Label
var thr_lbl: Label

# ---- picker ----
var picker: Control
var picker_title: Label
var picker_search: LineEdit
var picker_list: ItemList
var picker_perm: CheckButton
var picker_note: Label
var picker_ids: Array = []
var picker_is_mine := true

# ---- values ----
var val_search: LineEdit
var val_rarity: OptionButton
var val_sort: OptionButton
var val_scroll: ScrollContainer
var val_cards: VBoxContainer
var val_detail: RichTextLabel
var val_fav: Button
var val_status: Label
var val_spin: SpinBox
var manual_box: VBoxContainer

# ---- history / live / settings ----
var hist_list: ItemList
var hist_detail: RichTextLabel
var live_market_lbl: Label
var live_status: Label
var settings_source_lbl: Label
var _last_sub: Label


func _ready() -> void:
	theme = _make_theme()
	add_child(_build_background())

	var m := _safe_margins()
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", m["left"])
	margin.add_theme_constant_override("margin_right", m["right"])
	margin.add_theme_constant_override("margin_top", m["top"])
	margin.add_theme_constant_override("margin_bottom", m["bottom"])
	add_child(margin)

	var content := VBoxContainer.new()
	margin.add_child(content)
	pages = [
		_build_home(),
		_page("Trade Calculator", "🧮", _build_calc()),
		_page("Fruit Values", "🍎", _build_values()),
		_page("Live Assistant", "🤖", _build_live()),
		_page("Trade History", "🕘", _build_history()),
		_page("Market Trends", "📈", _build_market(), _refresh_button()),
		_page("Settings", "⚙", _build_settings()),
	]
	for p in pages:
		p.size_flags_vertical = Control.SIZE_EXPAND_FILL
		p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		content.add_child(p)

	add_child(_build_picker())   # last child = drawn on top
	_show_page(P_HOME)

	MarketDataManager.refresh_started.connect(func(_m): _on_refresh_started())
	MarketDataManager.refresh_finished.connect(func(_ok, _s): _on_refresh_finished())
	MarketDataManager.market_updated.connect(_on_market_updated)
	MarketDataManager.offline_mode_changed.connect(func(_o): _update_banner())
	FruitDatabase.database_changed.connect(_on_database_changed)
	var tick := Timer.new()      # relative-time text only; no network
	tick.wait_time = 60.0
	tick.timeout.connect(_update_banner)
	add_child(tick)
	tick.start()
	_on_database_changed()
	_update_banner()


## Keeps content clear of camera cut-outs / rounded corners on phones.
func _safe_margins() -> Dictionary:
	var m := {"left": 18, "right": 18, "top": 12, "bottom": 12}
	if OS.has_feature("mobile"):
		var win := Vector2(DisplayServer.window_get_size())
		var area := DisplayServer.get_display_safe_area()
		var vp := get_viewport().get_visible_rect().size
		if win.x > 0.0 and win.y > 0.0:
			var sx := vp.x / win.x
			var sy := vp.y / win.y
			m["left"] += int(maxf(0.0, area.position.x) * sx)
			m["top"] += int(maxf(0.0, area.position.y) * sy)
			m["right"] += int(maxf(0.0, win.x - area.end.x) * sx)
			m["bottom"] += int(maxf(0.0, win.y - area.end.y) * sy)
	return m


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:   # Android back button
		if picker != null and picker.visible:
			_close_picker()
		elif current_page != P_HOME:
			_show_page(P_HOME)
		else:
			get_tree().quit()


func _unhandled_input(event: InputEvent) -> void:
	if picker != null and picker.visible and event.is_action_pressed("ui_cancel"):
		_close_picker()
		get_viewport().set_input_as_handled()


func _show_page(i: int) -> void:
	current_page = i
	for n in pages.size():
		pages[n].visible = (n == i)


# ---- background + theme ------------------------------------------------------------------------------

func _glow_tex(d: int, col: Color) -> ImageTexture:
	var img := Image.create(d, d, false, Image.FORMAT_RGBA8)
	var c := (d - 1) / 2.0
	var r := d / 2.0
	for y in d:
		for x in d:
			var k := clampf(1.0 - Vector2(x - c, y - c).length() / r, 0.0, 1.0)
			img.set_pixel(x, y, Color(col.r, col.g, col.b, col.a * k * k))
	return ImageTexture.create_from_image(img)


func _circle_tex(d: int, col: Color) -> ImageTexture:
	var img := Image.create(d, d, false, Image.FORMAT_RGBA8)
	var c := (d - 1) / 2.0
	var r := d / 2.0
	for y in d:
		for x in d:
			var dist := Vector2(x - c, y - c).length()
			img.set_pixel(x, y, Color(col.r, col.g, col.b, clampf(r - dist, 0.0, 1.0)))
	return ImageTexture.create_from_image(img)


func _build_background() -> Control:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var g := Gradient.new()
	g.colors = PackedColorArray([Color("1a0b45"), Color("0d0a30"), Color("060a24")])
	g.offsets = PackedFloat32Array([0.0, 0.5, 1.0])
	var gt := GradientTexture2D.new()
	gt.gradient = g
	gt.fill_from = Vector2(0, 0)
	gt.fill_to = Vector2(0.4, 1)
	gt.width = 64
	gt.height = 64
	var base := TextureRect.new()
	base.texture = gt
	base.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	base.stretch_mode = TextureRect.STRETCH_SCALE
	base.set_anchors_preset(Control.PRESET_FULL_RECT)
	base.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(base)
	for spec in [[Vector2(-220, -260), 820, Color(0.55, 0.25, 1.0, 0.45)], [Vector2(760, 280), 760, Color(0.15, 0.45, 1.0, 0.35)]]:
		var gl := TextureRect.new()
		gl.texture = _glow_tex(256, spec[2])
		gl.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		gl.stretch_mode = TextureRect.STRETCH_SCALE
		gl.position = spec[0]
		gl.size = Vector2(spec[1], spec[1])
		gl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		root.add_child(gl)
	return root


func _box(bg: Color, radius := 14, border := Color(0, 0, 0, 0), bw := 0, mx := 14, my := 10, glow := 0) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.set_corner_radius_all(radius)
	s.set_border_width_all(bw)
	s.border_color = border
	s.content_margin_left = mx
	s.content_margin_right = mx
	s.content_margin_top = my
	s.content_margin_bottom = my
	if glow > 0:
		s.shadow_color = Color(border.r, border.g, border.b, 0.5)
		s.shadow_size = glow
	return s


func _style_button(th: Theme, type: String, normal: Color, hover: Color, pressed: Color, font: Color, font_pressed: Color, border := BORDER, bw := 1, radius := 14) -> void:
	th.set_stylebox("normal", type, _box(normal, radius, border, bw, 16, 12))
	th.set_stylebox("hover", type, _box(hover, radius, border, bw, 16, 12))
	th.set_stylebox("pressed", type, _box(pressed, radius, border, bw, 16, 12))
	th.set_stylebox("hover_pressed", type, _box(pressed, radius, border, bw, 16, 12))
	th.set_stylebox("disabled", type, _box(SURFACE, radius, BORDER, bw, 16, 12))
	th.set_stylebox("focus", type, StyleBoxEmpty.new())
	th.set_color("font_color", type, font)
	th.set_color("font_hover_color", type, font)
	th.set_color("font_pressed_color", type, font_pressed)
	th.set_color("font_hover_pressed_color", type, font_pressed)
	th.set_color("font_focus_color", type, font)
	th.set_color("font_disabled_color", type, MUTED)


func _make_theme() -> Theme:
	var th := Theme.new()
	th.default_font_size = 22
	th.set_constant("separation", "VBoxContainer", 10)
	th.set_constant("separation", "HBoxContainer", 10)
	th.set_color("font_color", "Label", TEXT)

	th.set_stylebox("panel", "PanelContainer", _box(SURFACE, 20, BORDER, 2, 16, 14, 8))
	var pv := {
		"RowPanel": _box(SURFACE_2, 14, Color("3a3290"), 1, 14, 8),
		"BannerPanel": _box(SURFACE, 16, BORDER, 1, 14, 6),
		"HeaderPanel": _box(SURFACE, 18, BORDER, 2, 12, 8, 8),
		"MinePanel": _box(SURFACE, 20, ACCENT, 2, 16, 14, 12),
		"TheirsPanel": _box(SURFACE, 20, PINK, 2, 16, 14, 12),
	}
	for k in pv:
		th.set_type_variation(k, "PanelContainer")
		th.set_stylebox("panel", k, pv[k])

	_style_button(th, "Button", SURFACE_2, SURFACE_3, ACCENT_DARK, TEXT, Color.WHITE)
	_style_button(th, "OptionButton", SURFACE_2, SURFACE_3, SURFACE_3, TEXT, TEXT)
	th.set_type_variation("AccentButton", "Button")
	_style_button(th, "AccentButton", ACCENT, Color("5a98ff"), ACCENT_DARK, Color.WHITE, Color.WHITE, Color("8fb8ff"), 2)
	th.set_type_variation("Pill", "Button")
	_style_button(th, "Pill", SURFACE_2, SURFACE_3, ACCENT, MUTED, Color.WHITE, BORDER, 1, 26)
	th.set_type_variation("Card", "Button")
	_style_button(th, "Card", SURFACE_2, SURFACE_3, SURFACE_3, TEXT, TEXT, Color("3a3290"), 1, 16)
	th.set_type_variation("CardSel", "Button")
	_style_button(th, "CardSel", SURFACE_3, SURFACE_3, SURFACE_3, TEXT, TEXT, ACCENT, 3, 16)
	var tiles := {"TileOrange": Color("f97316"), "TileBlue": Color("2f7bff"), "TilePurple": Color("7c3aed"),
		"TileGreen": Color("16a34a"), "TileCyan": Color("0891b2"), "TileSlate": Color("3b3f80")}
	for k in tiles:
		var c: Color = tiles[k]
		th.set_type_variation(k, "Button")
		_style_button(th, k, c, c.lightened(0.12), c.darkened(0.15), Color.WHITE, Color.WHITE, c.lightened(0.4), 2, 20)

	for cls in ["CheckButton", "CheckBox"]:
		th.set_stylebox("focus", cls, StyleBoxEmpty.new())
		for cname in ["font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color", "font_focus_color"]:
			th.set_color(cname, cls, TEXT)

	th.set_stylebox("normal", "LineEdit", _box(SURFACE_2, 14, BORDER, 1, 14, 12))
	th.set_stylebox("focus", "LineEdit", _box(SURFACE_2, 14, ACCENT, 2, 14, 12))
	th.set_stylebox("read_only", "LineEdit", _box(SURFACE, 14, BORDER, 1, 14, 12))
	th.set_color("font_color", "LineEdit", TEXT)
	th.set_color("font_placeholder_color", "LineEdit", MUTED)
	th.set_color("caret_color", "LineEdit", ACCENT)
	th.set_color("selection_color", "LineEdit", Color(ACCENT, 0.4))

	th.set_stylebox("normal", "TextEdit", _box(SURFACE_2, 14, BORDER, 1, 14, 10))
	th.set_stylebox("focus", "TextEdit", _box(SURFACE_2, 14, ACCENT, 2, 14, 10))
	th.set_color("font_color", "TextEdit", TEXT)
	th.set_color("font_placeholder_color", "TextEdit", MUTED)

	th.set_stylebox("panel", "ItemList", _box(SURFACE_2, 14, Color(0, 0, 0, 0), 0, 8, 8))
	th.set_stylebox("focus", "ItemList", StyleBoxEmpty.new())
	th.set_stylebox("selected", "ItemList", _box(ACCENT_DARK, 10, Color(0, 0, 0, 0), 0, 8, 8))
	th.set_stylebox("selected_focus", "ItemList", _box(ACCENT_DARK, 10, Color(0, 0, 0, 0), 0, 8, 8))
	th.set_stylebox("cursor", "ItemList", StyleBoxEmpty.new())
	th.set_stylebox("cursor_unfocused", "ItemList", StyleBoxEmpty.new())
	th.set_color("font_color", "ItemList", TEXT)
	th.set_color("font_selected_color", "ItemList", Color.WHITE)
	th.set_color("guide_color", "ItemList", Color(0, 0, 0, 0))
	th.set_constant("v_separation", "ItemList", 14)
	th.set_constant("h_separation", "ItemList", 14)
	th.set_font_size("font_size", "ItemList", 21)

	th.set_stylebox("normal", "RichTextLabel", StyleBoxEmpty.new())
	th.set_stylebox("focus", "RichTextLabel", StyleBoxEmpty.new())
	th.set_color("default_color", "RichTextLabel", TEXT)
	th.set_font_size("normal_font_size", "RichTextLabel", 21)
	th.set_font_size("bold_font_size", "RichTextLabel", 21)

	th.set_stylebox("panel", "PopupMenu", _box(SURFACE_2, 12, BORDER, 1, 8, 8))
	th.set_stylebox("hover", "PopupMenu", _box(ACCENT_DARK, 8, Color(0, 0, 0, 0), 0, 8, 8))
	th.set_color("font_color", "PopupMenu", TEXT)
	th.set_color("font_hover_color", "PopupMenu", Color.WHITE)
	th.set_constant("v_separation", "PopupMenu", 18)

	th.set_stylebox("slider", "HSlider", _box(SURFACE_3, 6, Color(0, 0, 0, 0), 0, 0, 5))
	th.set_stylebox("grabber_area", "HSlider", _box(ACCENT, 6, Color(0, 0, 0, 0), 0, 0, 5))
	th.set_stylebox("grabber_area_highlight", "HSlider", _box(ACCENT, 6, Color(0, 0, 0, 0), 0, 0, 5))
	th.set_icon("grabber", "HSlider", _circle_tex(40, Color.WHITE))
	th.set_icon("grabber_highlight", "HSlider", _circle_tex(40, Color("cfe0ff")))
	th.set_icon("grabber_disabled", "HSlider", _circle_tex(40, MUTED))

	for sb in ["VScrollBar", "HScrollBar"]:
		th.set_stylebox("scroll", sb, _box(Color(0, 0, 0, 0), 6, Color(0, 0, 0, 0), 0, 5, 5))
		th.set_stylebox("scroll_focus", sb, _box(Color(0, 0, 0, 0), 6, Color(0, 0, 0, 0), 0, 5, 5))
		th.set_stylebox("grabber", sb, _box(SURFACE_3, 6, Color(0, 0, 0, 0), 0, 5, 5))
		th.set_stylebox("grabber_highlight", sb, _box(ACCENT, 6, Color(0, 0, 0, 0), 0, 5, 5))
		th.set_stylebox("grabber_pressed", sb, _box(ACCENT, 6, Color(0, 0, 0, 0), 0, 5, 5))
	return th


# ---- small builders ---------------------------------------------------------------------------------------

func _label(text: String, size := 22, color := TEXT, wrap := false) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	if wrap:
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return l


func _button(text: String, variation := "", min_h := 56) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size.y = min_h
	if variation != "":
		b.theme_type_variation = variation
	return b


func _panel(ratio := 1.0, variation := "") -> PanelContainer:
	var p := PanelContainer.new()
	p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	p.size_flags_vertical = Control.SIZE_EXPAND_FILL
	p.size_flags_stretch_ratio = ratio
	if variation != "":
		p.theme_type_variation = variation
	return p


func _rich() -> RichTextLabel:
	var r := RichTextLabel.new()
	r.bbcode_enabled = true
	r.fit_content = true
	r.scroll_active = false
	r.selection_enabled = false
	r.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return r


## ScrollContainer wrapper: drag-to-scroll works on touch screens.
func _scroll_of(child: Control) -> ScrollContainer:
	var sc := ScrollContainer.new()
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(child)
	return sc


func _ignore(n: Control) -> void:
	n.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for c in n.get_children():
		if c is Control:
			_ignore(c)


func _esc(s: String) -> String:
	return s.replace("[", "[lb]")


func _c(text: String, col: Color) -> String:
	return "[color=#%s]%s[/color]" % [col.to_html(false), _esc(text)]


func _h(text: String) -> String:
	return "[color=#%s][b]%s[/b][/color]\n" % [CYAN.to_html(false), _esc(text)]


## Page = header bar (back arrow, icon, title, optional right control) + body.
func _page(title: String, icon: String, body: Control, extra: Control = null) -> Control:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 12)
	var hp := PanelContainer.new()
	hp.theme_type_variation = "HeaderPanel"
	var h := HBoxContainer.new()
	hp.add_child(h)
	var back := _button("←", "", 48)
	back.custom_minimum_size.x = 68
	back.pressed.connect(_show_page.bind(P_HOME))
	h.add_child(back)
	var t := _label("%s  %s" % [icon, title], 30)
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	t.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	h.add_child(t)
	if extra != null:
		h.add_child(extra)
	v.add_child(hp)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_child(body)
	return v


func _refresh_button() -> Button:
	var b := _button("Refresh", "AccentButton", 48)
	b.custom_minimum_size.x = 150
	b.pressed.connect(func(): MarketDataManager.refresh(true))
	refresh_btns.append(b)
	return b


func _status_bar() -> Control:
	var p := PanelContainer.new()
	p.theme_type_variation = "BannerPanel"
	var row := HBoxContainer.new()
	p.add_child(row)
	var l := _label("", 17, MUTED, true)
	l.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(l)
	status_lbls.append(l)
	row.add_child(_refresh_button())
	return p


func _update_banner() -> void:
	var t := MarketDataManager.status_text()
	if FruitDatabase.has_data() and int(Time.get_unix_time_from_system()) - FruitDatabase.generated_unix() > 21600:
		t += "\n⚠ Data snapshot is more than 6 hours old."
	var bad: bool = MarketDataManager.offline or MarketDataManager.state == "error" or MarketDataManager.state == "not_configured"
	for l in status_lbls:
		l.text = t
		l.add_theme_color_override("font_color", WARN if bad else MUTED)
	if live_market_lbl != null:
		live_market_lbl.text = _live_market_text()


func _on_refresh_started() -> void:
	for b in refresh_btns:
		b.disabled = true
		b.text = "Refreshing..."


func _on_refresh_finished() -> void:
	for b in refresh_btns:
		b.disabled = false
		b.text = "Refresh"
	_update_banner()
	_refresh_market()


func _on_market_updated(diff: Dictionary) -> void:
	if diff.get("is_first_load", false):
		last_update_line = "Market data loaded (%d fruits)." % FruitDatabase.fruits.size()
	else:
		last_update_line = "Update: %d new, %d removed, %d renamed, %d value changes, %d demand changes, %d trend changes." % [
			diff["added"].size(), diff["removed"].size(), diff["renamed"].size(),
			diff["value_changes"].size(), diff["demand_changes"].size(), diff["trend_changes"].size()]
	_on_database_changed()


## Everything that shows market data is rebuilt here, so every page stays in sync.
func _on_database_changed() -> void:
	_refresh_offers()
	_refresh_calc()
	_refresh_picker()
	_refresh_values()
	_refresh_history()
	_refresh_market()
	_update_banner()
	if manual_box != null:
		manual_box.visible = not ItemDB.using_market_data()


# ---- Home (menu) ------------------------------------------------------------------------------------------

func _tile(icon: String, title: String, sub: String, kind: String, page: int) -> Button:
	var b := Button.new()
	b.theme_type_variation = kind
	b.custom_minimum_size = Vector2(0, 120)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.size_flags_vertical = Control.SIZE_EXPAND_FILL
	b.pressed.connect(_show_page.bind(page))
	var h := HBoxContainer.new()
	h.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	h.offset_left = 18
	h.offset_right = -18
	h.add_theme_constant_override("separation", 16)
	b.add_child(h)
	var ic := _label(icon, 54, Color.WHITE)
	ic.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	h.add_child(ic)
	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	v.add_theme_constant_override("separation", 0)
	v.add_child(_label(title, 27, Color.WHITE))
	v.add_child(_label(sub, 18, Color(1, 1, 1, 0.82)))
	h.add_child(v)
	var chev := _label("›", 46, Color.WHITE)
	chev.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	h.add_child(chev)
	_ignore(h)
	return b


func _build_home() -> Control:
	var root := HBoxContainer.new()
	root.add_theme_constant_override("separation", 26)

	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.size_flags_stretch_ratio = 0.85
	left.alignment = BoxContainer.ALIGNMENT_CENTER
	left.add_theme_constant_override("separation", 4)
	var crown := _label("👑", 54, WARN)
	crown.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	left.add_child(crown)
	for spec in [["BLOX", CYAN], ["TRADE AI", ORANGE]]:
		var l := _label(spec[0], 78, spec[1])
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.add_theme_constant_override("outline_size", 14)
		l.add_theme_color_override("font_outline_color", Color("1a0b4d"))
		left.add_child(l)
	var tag := _label("Trade Smarter. Play Better.", 26, TEXT)
	tag.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	left.add_child(tag)
	var gap := Control.new()
	gap.custom_minimum_size.y = 18
	left.add_child(gap)
	left.add_child(_status_bar())
	root.add_child(left)

	var grid := GridContainer.new()
	grid.columns = 2
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.size_flags_vertical = Control.SIZE_EXPAND_FILL
	grid.size_flags_stretch_ratio = 1.3
	grid.add_theme_constant_override("h_separation", 16)
	grid.add_theme_constant_override("v_separation", 16)
	grid.add_child(_tile("🧮", "Trade Calculator", "Check values & trades", "TileOrange", P_TRADE))
	grid.add_child(_tile("🍎", "Fruit Values", "Live market data", "TileBlue", P_VALUES))
	grid.add_child(_tile("🤖", "Live Assistant", "Get instant advice", "TilePurple", P_LIVE))
	grid.add_child(_tile("🕘", "Trade History", "Track your trades", "TileGreen", P_HISTORY))
	grid.add_child(_tile("📈", "Market Trends", "Gainers & losers", "TileCyan", P_MARKET))
	grid.add_child(_tile("⚙", "Settings", "Customize your app", "TileSlate", P_SETTINGS))
	root.add_child(grid)
	return root


# ---- Market trends ---------------------------------------------------------------------------------------

func _build_market() -> Control:
	var root := HBoxContainer.new()
	root.add_theme_constant_override("separation", 14)
	var left := _panel(1.0)
	home_left = _rich()
	left.add_child(_scroll_of(home_left))
	root.add_child(left)
	var right := _panel(1.0)
	home_right = _rich()
	right.add_child(_scroll_of(home_right))
	root.add_child(right)
	return root


func _event_line(e: Dictionary) -> String:
	match e.get("type"):
		"added": return "New fruit: %s" % e.get("name", e["id"])
		"removed": return "Removed: %s" % e.get("name", e["id"])
		"renamed": return "Renamed: %s -> %s" % [e.get("old", "?"), e.get("new", "?")]
		"demand": return "Demand %s: %s -> %s" % [e.get("name", e["id"]), str(e.get("old")), str(e.get("new"))]
		"trend": return "Trend %s: %s -> %s" % [e.get("name", e["id"]), e.get("old"), e.get("new")]
	return ""


func _mover_line(e: Dictionary) -> String:
	return "%s %s  %s  (%s -> %s)" % [MarketFormat.trend_glyph("rising" if float(e["pct"]) > 0.0 else "dropping"),
		e.get("name", e["id"]), MarketFormat.pct_text(e["pct"]), MarketFormat.compact(e["old"]), MarketFormat.compact(e["new"])]


func _refresh_market() -> void:
	if settings_source_lbl != null:
		settings_source_lbl.text = ItemDB.data_source
	if home_left == null:
		return
	var l := _h("Market overview")
	var r := ""
	if not FruitDatabase.has_data():
		l += _c("No market data yet.\n" + MarketDataManager.status_text(), MUTED)
		home_left.text = l
		home_right.text = ""
		return
	l += _c("Values are community estimates published in periodic snapshots. They are not real-time prices.", MUTED) + "\n"
	l += _c("Source: %s" % ItemDB.data_source, MUTED) + "\n"
	if last_update_line != "":
		l += _c(last_update_line, WARN) + "\n"
	var counts := {"rising": 0, "dropping": 0, "overpaid": 0, "stable": 0, "unknown": 0}
	for id in FruitDatabase.fruits:
		var tr_key: String = str(FruitDatabase.fruits[id]["market_trend"])
		counts[tr_key] = int(counts.get(tr_key, 0)) + 1
	l += "\n"
	for k in ["rising", "dropping", "overpaid", "stable"]:
		l += _c("%s %d %s" % [MarketFormat.trend_glyph(k), counts[k], k], MarketFormat.trend_color(k)) + "    "
	l += "\n\n" + _h("Highest demand")
	for f in FruitDatabase.search("", "", "demand").slice(0, 6):
		var dem = f["physical_demand"]
		l += _esc("%s   %s/10   %s\n" % [f["name"], "n/a" if dem == null else str(dem), MarketFormat.compact(f["physical_value"])])
	home_left.text = l

	var since := int(Time.get_unix_time_from_system()) - 7 * 86400
	r += _h("Top gainers (7 days)")
	var ups := MarketHistory.movers(since, "up", 5)
	for e in ups:
		r += _c(_mover_line(e), GOOD) + "\n"
	if ups.is_empty():
		r += _c("None recorded.", MUTED) + "\n"
	r += "\n" + _h("Top losers (7 days)")
	var downs := MarketHistory.movers(since, "down", 5)
	for e in downs:
		r += _c(_mover_line(e), BAD) + "\n"
	if downs.is_empty():
		r += _c("None recorded.", MUTED) + "\n"
	r += "\n" + _h("Recent changes")
	var n := 0
	for e in MarketHistory.recent_events(60, ["added", "removed", "renamed", "demand", "trend"]):
		r += _esc(_event_line(e)) + "\n"
		n += 1
		if n >= 10:
			break
	if n == 0:
		r += _c("None recorded.", MUTED) + "\n"
	var review: Array = FruitDatabase.meta.get("review", [])
	if not review.is_empty():
		r += "\n" + _c("⚠ Large value changes to verify:", WARN) + "\n"
		for id in review:
			r += _esc("%s\n" % FruitDatabase.get_fruit(id).get("name", id))
	var conflicts: Array = FruitDatabase.meta.get("conflicts", [])
	if not conflicts.is_empty():
		r += "\n" + _c("⚠ Sources disagree:", WARN) + "\n"
		for c in conflicts:
			var parts: Array = []
			for src in c["values"]:
				parts.append("%s=%s" % [src, str(c["values"][src])])
			r += _esc("%s %s: %s\n" % [FruitDatabase.get_fruit(c["id"]).get("name", c["id"]), c["field"], ", ".join(parts)])
	home_right.text = r


# ---- Trade calculator ------------------------------------------------------------------------------------

func _build_calc() -> Control:
	var root := HBoxContainer.new()
	root.add_theme_constant_override("separation", 14)
	root.add_child(_side("Your Offer", true))
	root.add_child(_build_verdict())
	root.add_child(_side("Their Offer", false))
	return root


func _side(title: String, is_mine: bool) -> Control:
	var p := _panel(1.0, "MinePanel" if is_mine else "TheirsPanel")
	var v := VBoxContainer.new()
	p.add_child(v)
	var head := HBoxContainer.new()
	var t := _label(title, 26, ACCENT if is_mine else PINK)
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(t)
	var sum := _label("", 21, TEXT)
	head.add_child(sum)
	v.add_child(head)
	var add := _button("+  Add fruit", "AccentButton", 60)
	add.pressed.connect(_open_picker.bind(is_mine))
	v.add_child(add)
	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 8)
	v.add_child(_scroll_of(list))
	if is_mine:
		mine_list = list
		mine_sum_lbl = sum
	else:
		theirs_list = list
		theirs_sum_lbl = sum
	return p


func _build_verdict() -> Control:
	var p := _panel(0.0)
	p.size_flags_horizontal = Control.SIZE_FILL
	p.custom_minimum_size.x = 340
	var v := VBoxContainer.new()
	p.add_child(v)
	var cap := _label("Difference", 22, TEXT)
	cap.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(cap)
	pct_lbl = _label("0%", 54, GOOD)
	pct_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(pct_lbl)
	verdict_lbl = _label("-", 30, MUTED)
	verdict_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(verdict_lbl)
	verdict_sub_lbl = _label("", 18, MUTED, true)
	verdict_sub_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(verdict_sub_lbl)

	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	stats_lbl = _label("", 21, TEXT, true)
	info.add_child(stats_lbl)
	detail_lbl = _label("", 16, MUTED, true)
	info.add_child(detail_lbl)
	warn_lbl = _label("", 16, WARN, true)
	info.add_child(warn_lbl)
	v.add_child(_scroll_of(info))

	thr_lbl = _label("", 18, MUTED)
	v.add_child(thr_lbl)
	var sl := HSlider.new()
	sl.min_value = 0.0
	sl.max_value = 50.0
	sl.step = 0.5
	sl.value = threshold
	sl.custom_minimum_size.y = 40
	sl.value_changed.connect(func(val: float):
		threshold = val
		_refresh_calc()
		_refresh_history())
	v.add_child(sl)

	var hb := HBoxContainer.new()
	var save := _button("Save trade", "AccentButton", 54)
	save.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	save.pressed.connect(func():
		if mine.size() + theirs.size() > 0:
			TradeHistory.add(mine, theirs, TradeEngine.evaluate(mine, theirs, threshold))
			_refresh_history()
			_toast("Trade saved to History."))
	hb.add_child(save)
	var clear := _button("Clear", "", 54)
	clear.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	clear.pressed.connect(func():
		mine.clear()
		theirs.clear()
		_refresh_calc())
	hb.add_child(clear)
	v.add_child(hb)
	return p


func _toast(msg: String) -> void:
	warn_lbl.text = ""
	detail_lbl.text = msg


## After a market update, offers are re-priced from the new data (same id and variant).
func _refresh_offers() -> void:
	for arr in [mine, theirs]:
		for i in arr.size():
			var cur: Dictionary = arr[i]
			var fresh := ItemDB.get_item(str(cur.get("id", "")), str(cur.get("variant", "physical")))
			if fresh.is_empty():
				cur["value"] = null
				cur["status"] = "partial"
				if not str(cur["name"]).ends_with("(no longer listed)"):
					cur["name"] = str(cur["name"]) + " (no longer listed)"
			else:
				arr[i] = fresh


func _item_sub_text(it: Dictionary) -> String:
	var v = it.get("value")
	var s := "no value" if v == null else MarketFormat.compact(v)
	var trend := str(it.get("trend", ""))
	if trend != "":
		s += "   " + MarketFormat.trend_glyph(trend)
	if it.get("variant", "physical") == "physical" and it.has("id"):
		var ch := MarketHistory.last_value_change(str(it["id"]))
		if not ch.is_empty():
			s += " " + MarketFormat.pct_text(ch.get("pct"))
	var badge := MarketFormat.status_badge(str(it.get("status", "")))
	if badge != "":
		s += "   " + badge
	return s


func _item_row(arr: Array, i: int) -> Control:
	var it: Dictionary = arr[i]
	var row := PanelContainer.new()
	row.theme_type_variation = "RowPanel"
	var h := HBoxContainer.new()
	row.add_child(h)
	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_theme_constant_override("separation", 0)
	var n := _label(str(it["name"]), 22)
	n.clip_text = true
	n.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	v.add_child(n)
	v.add_child(_label(_item_sub_text(it), 17, MarketFormat.trend_color(str(it.get("trend", "")))))
	h.add_child(v)
	var x := _button("×", "", 48)
	x.custom_minimum_size.x = 52
	x.pressed.connect(func():
		arr.remove_at(i)
		_refresh_calc())
	h.add_child(x)
	return row


func _fill(list: VBoxContainer, arr: Array, sum_lbl: Label) -> void:
	for c in list.get_children():
		list.remove_child(c)
		c.queue_free()
	if arr.is_empty():
		list.add_child(_label("Nothing added yet.\nTap “+ Add fruit”.", 19, MUTED, true))
	for i in arr.size():
		list.add_child(_item_row(arr, i))
	var tot := TradeEngine.total(arr)
	var s := "💎 " + MarketFormat.compact(tot["sum"])
	if int(tot["missing"]) > 0:
		s += "  (+%d n/a)" % int(tot["missing"])
	sum_lbl.text = s


func _signed(v) -> String:
	var f := float(v)
	return ("+" if f > 0.0 else "") + MarketFormat.compact(f)


func _refresh_calc() -> void:
	if mine_list == null:
		return
	_fill(mine_list, mine, mine_sum_lbl)
	_fill(theirs_list, theirs, theirs_sum_lbl)
	var r := TradeEngine.evaluate(mine, theirs, threshold)
	var parts := TradeEngine.label(r["result"]).split(" - ")
	var col := {TradeEngine.Result.WIN: GOOD, TradeEngine.Result.FAIR: WARN,
		TradeEngine.Result.LOSS: BAD, TradeEngine.Result.UNKNOWN: MUTED}
	var c: Color = col[r["result"]]
	pct_lbl.text = "n/a" if r["pct"] == null else "%.1f%%" % absf(float(r["pct"]))
	pct_lbl.add_theme_color_override("font_color", c)
	verdict_lbl.text = parts[0]
	verdict_lbl.add_theme_color_override("font_color", c)
	verdict_sub_lbl.text = parts[1] if parts.size() > 1 else ""
	stats_lbl.text = "You   %s\nThem  %s\nDiff   %s" % [
		MarketFormat.compact(r["mine"]), MarketFormat.compact(r["theirs"]), _signed(r["diff"])]
	detail_lbl.text = "Values: %s\n%s\nTip: keep the difference under %.0f%% for a fair trade." % [
		MarketDataManager.freshness_label(), r["note"], threshold]
	warn_lbl.text = "\n".join(r["warnings"])
	thr_lbl.text = "Fair threshold: %.1f%%" % threshold


# ---- Fruit picker (tap to add) ----------------------------------------------------------------------------

func _build_picker() -> Control:
	picker = Control.new()
	picker.set_anchors_preset(Control.PRESET_FULL_RECT)
	picker.visible = false

	var dim := ColorRect.new()
	dim.color = Color(0.02, 0.0, 0.1, 0.78)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.gui_input.connect(func(ev: InputEvent):
		if ev is InputEventMouseButton and ev.pressed:
			_close_picker())
	picker.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE   # taps outside the panel reach the dim layer
	picker.add_child(center)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(960, 600)
	center.add_child(panel)
	var v := VBoxContainer.new()
	panel.add_child(v)

	var head := HBoxContainer.new()
	picker_title = _label("Add fruit", 26)
	picker_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(picker_title)
	picker_perm = CheckButton.new()
	picker_perm.text = "Permanent"
	picker_perm.toggled.connect(func(_on): _refresh_picker())
	head.add_child(picker_perm)
	var done := _button("Done", "AccentButton", 50)
	done.custom_minimum_size.x = 120
	done.pressed.connect(_close_picker)
	head.add_child(done)
	v.add_child(head)

	picker_search = LineEdit.new()
	picker_search.placeholder_text = "Search fruits"
	picker_search.clear_button_enabled = true
	picker_search.text_changed.connect(func(_t): _refresh_picker())
	v.add_child(picker_search)

	picker_list = ItemList.new()
	picker_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	picker_list.max_columns = 3
	picker_list.same_column_width = true
	picker_list.allow_reselect = true
	picker_list.item_clicked.connect(_on_picker_click)
	v.add_child(picker_list)

	picker_note = _label("", 18, MUTED, true)
	v.add_child(picker_note)
	return picker


func _open_picker(is_mine: bool) -> void:
	picker_is_mine = is_mine
	picker_title.text = "Add to your offer" if is_mine else "Add to their offer"
	picker_search.text = ""
	picker_note.text = "Tap a fruit to add it. Tap Done when finished."
	_refresh_picker()
	picker.visible = true


func _close_picker() -> void:
	picker.visible = false
	picker_search.release_focus()


func _refresh_picker() -> void:
	if picker == null or picker_list == null:
		return
	picker_list.clear()
	picker_ids.clear()
	var variant := "permanent" if picker_perm.button_pressed else "physical"
	for it in ItemDB.search(picker_search.text):
		var d := ItemDB.get_item(str(it["id"]), variant)
		if d.is_empty():
			continue
		var v = d.get("value")
		var trend := str(d.get("trend", ""))
		var glyph := (MarketFormat.trend_glyph(trend) + " ") if trend != "" else ""
		picker_list.add_item("%s%s   %s" % [glyph, str(d.get("base_name", d["name"])), "no value" if v == null else MarketFormat.compact(v)])
		picker_list.set_item_custom_fg_color(picker_list.item_count - 1, MUTED if v == null else MarketFormat.trend_color(trend))
		picker_ids.append(str(d["id"]))


func _on_picker_click(index: int, _pos: Vector2, button: int) -> void:
	if button != MOUSE_BUTTON_LEFT or index < 0 or index >= picker_ids.size():
		return
	var variant := "permanent" if picker_perm.button_pressed else "physical"
	var it := ItemDB.get_item(str(picker_ids[index]), variant)
	if it.is_empty():
		return
	var arr: Array = mine if picker_is_mine else theirs
	arr.append(it)
	_refresh_calc()
	picker_note.text = "Added %s  (%d in this offer). Tap more, or press Done." % [str(it["name"]), arr.size()]


# ---- Fruit values ------------------------------------------------------------------------------------------

func _rarity_color(r: String) -> Color:
	match r:
		"mythical": return Color("ef4444")
		"legendary": return Color("f59e0b")
		"rare": return Color("3b82f6")
		"uncommon": return Color("22c55e")
	return Color("94a3b8")


func _build_values() -> Control:
	var root := HBoxContainer.new()
	root.add_theme_constant_override("separation", 14)

	var left := _panel(1.7)
	var lv := VBoxContainer.new()
	left.add_child(lv)

	var top := HBoxContainer.new()
	var group := ButtonGroup.new()
	var names := ["All", "Physical", "Permanent"]
	for i in names.size():
		var pill := _button(names[i], "Pill", 52)
		pill.toggle_mode = true
		pill.button_group = group
		pill.button_pressed = (i == val_mode)
		pill.pressed.connect(func():
			val_mode = i
			_refresh_values())
		top.add_child(pill)
	val_search = LineEdit.new()
	val_search.placeholder_text = "Search"
	val_search.clear_button_enabled = true
	val_search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	val_search.text_changed.connect(func(_t): _refresh_values())
	top.add_child(val_search)
	lv.add_child(top)

	var fr := HBoxContainer.new()
	val_rarity = OptionButton.new()
	for r in ["All rarities", "mythical", "legendary", "rare", "uncommon", "common"]:
		val_rarity.add_item(r)
	val_rarity.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	val_rarity.item_selected.connect(func(_i): _refresh_values())
	fr.add_child(val_rarity)
	val_sort = OptionButton.new()
	for s in SORT_KEYS:
		val_sort.add_item("Sort: " + s)
	val_sort.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	val_sort.item_selected.connect(func(_i): _refresh_values())
	fr.add_child(val_sort)
	lv.add_child(fr)

	val_cards = VBoxContainer.new()
	val_cards.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	val_cards.add_theme_constant_override("separation", 10)
	val_scroll = _scroll_of(val_cards)
	lv.add_child(val_scroll)
	root.add_child(left)

	var right := _panel(1.0)
	var rv := VBoxContainer.new()
	right.add_child(rv)
	val_detail = _rich()
	val_detail.text = _c("Tap a fruit to see its details.", MUTED)
	rv.add_child(_scroll_of(val_detail))
	val_fav = _button("★  Favorite", "", 54)
	val_fav.disabled = true
	val_fav.pressed.connect(func():
		if selected_id != "":
			ItemDB.toggle_favorite(selected_id)
			_refresh_values())
	rv.add_child(val_fav)
	rv.add_child(_build_manual())
	rv.add_child(_status_bar())
	root.add_child(right)
	return root


func _fruit_card(f: Dictionary) -> Button:
	var id := str(f["id"])
	var b := Button.new()
	b.theme_type_variation = "CardSel" if id == selected_id else "Card"
	b.custom_minimum_size = Vector2(0, 92)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.pressed.connect(_pick_fruit.bind(id))
	var h := HBoxContainer.new()
	h.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	h.offset_left = 14
	h.offset_right = -14
	h.offset_top = 8
	h.offset_bottom = -8
	h.add_theme_constant_override("separation", 14)
	b.add_child(h)

	var rarity := str(f["rarity"])
	var rc := _rarity_color(rarity)
	var av := PanelContainer.new()
	av.custom_minimum_size = Vector2(62, 62)
	av.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	av.add_theme_stylebox_override("panel", _box(rc.darkened(0.5), 31, rc, 2, 0, 0))
	var initial := _label(str(f["name"]).substr(0, 1).to_upper(), 30, Color.WHITE)
	initial.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	initial.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	av.add_child(initial)
	h.add_child(av)

	var mid := VBoxContainer.new()
	mid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mid.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	mid.add_theme_constant_override("separation", 2)
	var nm := HBoxContainer.new()
	var star := "★ " if ItemDB.favorites.has(id) else ""
	nm.add_child(_label(star + str(f["name"]), 24))
	var badge := PanelContainer.new()
	badge.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	badge.add_theme_stylebox_override("panel", _box(rc, 8, Color(0, 0, 0, 0), 0, 8, 1))
	badge.add_child(_label(rarity.capitalize(), 15, Color.WHITE))
	nm.add_child(badge)
	mid.add_child(nm)
	var vals := ""
	match val_mode:
		1: vals = "P: %s" % MarketFormat.compact(f["physical_value"])
		2: vals = "Perm: %s" % MarketFormat.compact(f["permanent_value"])
		_: vals = "P: %s     Perm: %s" % [MarketFormat.compact(f["physical_value"]), MarketFormat.compact(f["permanent_value"])]
	mid.add_child(_label(vals, 18, MUTED))
	h.add_child(mid)

	var rv := VBoxContainer.new()
	rv.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	rv.add_theme_constant_override("separation", 0)
	var dem = f["physical_demand"]
	var dl := _label("Demand: %s" % ("n/a" if dem == null else "%d/10" % int(dem)), 17, MUTED)
	dl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	rv.add_child(dl)
	var trend := str(f["market_trend"])
	var ch := MarketHistory.last_value_change(id)
	var tt := MarketFormat.trend_glyph(trend)
	if not ch.is_empty():
		tt += " " + MarketFormat.pct_text(ch.get("pct"))
	var tl := _label(tt, 20, MarketFormat.trend_color(trend))
	tl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	rv.add_child(tl)
	h.add_child(rv)
	_ignore(h)
	return b


func _pick_fruit(id: String) -> void:
	if card_by_id.has(selected_id):
		card_by_id[selected_id].theme_type_variation = "Card"
	selected_id = id
	if card_by_id.has(id):
		card_by_id[id].theme_type_variation = "CardSel"
	_show_fruit(id)
	_update_fav_button()


## Manual values exist only as an offline fallback when no market data has ever been loaded.
func _build_manual() -> Control:
	manual_box = VBoxContainer.new()
	manual_box.add_child(_label("No market data yet. Manual fallback:", 18, MUTED, true))
	var hb := HBoxContainer.new()
	val_spin = SpinBox.new()
	val_spin.max_value = 1e12
	val_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hb.add_child(val_spin)
	var setb := _button("Set value", "", 48)
	setb.pressed.connect(func():
		if selected_id != "":
			ItemDB.set_value(selected_id, val_spin.value)
			_refresh_values())
	hb.add_child(setb)
	manual_box.add_child(hb)
	var imp := TextEdit.new()
	imp.placeholder_text = "Paste values JSON to import"
	imp.custom_minimum_size.y = 90
	manual_box.add_child(imp)
	var ib := _button("Import values", "", 48)
	ib.pressed.connect(func():
		var e := ItemDB.import_values(imp.text)
		val_status.text = "Imported." if e == "" else e
		_refresh_values())
	manual_box.add_child(ib)
	val_status = _label("", 17, MUTED, true)
	manual_box.add_child(val_status)
	manual_box.visible = not ItemDB.using_market_data()
	return manual_box


func _update_fav_button() -> void:
	if val_fav == null:
		return
	val_fav.disabled = selected_id == ""
	val_fav.text = "★  Unfavorite" if ItemDB.favorites.has(selected_id) else "★  Favorite"


func _refresh_values() -> void:
	if val_cards == null:
		return
	var keep := val_scroll.scroll_vertical
	for c in val_cards.get_children():
		val_cards.remove_child(c)
		c.queue_free()
	card_by_id.clear()
	var rarity := "" if val_rarity.selected <= 0 else val_rarity.get_item_text(val_rarity.selected)
	var key: String = SORT_KEYS[maxi(val_sort.selected, 0)]
	var rows: Array = []
	if ItemDB.using_market_data():
		rows = FruitDatabase.search(val_search.text, rarity, key)
		if val_mode == 2:
			rows = rows.filter(func(f): return f["permanent_value"] != null)
			if key == "value":
				rows.sort_custom(func(a, b): return a["permanent_value"] > b["permanent_value"])
	else:
		for it in ItemDB.search(val_search.text):
			var rar := "common"
			if it.get("rarity") != null:
				rar = str(it["rarity"])
			rows.append({"id": it["id"], "name": it["name"], "rarity": rar, "physical_value": it.get("value"),
				"permanent_value": null, "physical_demand": null, "market_trend": "unknown"})
	for f in rows:
		var card := _fruit_card(f)
		val_cards.add_child(card)
		card_by_id[str(f["id"])] = card
	if rows.is_empty():
		val_cards.add_child(_label("No fruits match.", 20, MUTED))
	if selected_id != "" and card_by_id.has(selected_id):
		_show_fruit(selected_id)
	_update_fav_button()
	val_scroll.set_deferred("scroll_vertical", keep)


func _show_fruit(id: String) -> void:
	var f := FruitDatabase.get_fruit(id)
	if f.is_empty():
		var it := ItemDB.get_item(id)
		if it.is_empty():
			val_detail.text = _c("No market data for this item.", MUTED)
		else:
			var txt := "[b]%s[/b]\n" % _esc(str(it["name"]))
			if it.get("value") != null:
				txt += "Manual value: %s" % str(it["value"])
			else:
				txt += _c("No market data for this item.", MUTED)
			val_detail.text = txt
		return
	var ch := MarketHistory.last_value_change(id)
	var ch_p := MarketHistory.last_value_change(id, "permanent_value")
	var t := "[b][font_size=28]%s[/font_size][/b]\n%s\n\n" % [_esc(f["name"]), _c("%s  •  %s" % [f["rarity"], f["fruit_type"]], MUTED)]
	t += "Physical value:  [b]%s[/b]" % MarketFormat.compact(f["physical_value"])
	if not ch.is_empty():
		t += "  " + _c("(last change %s)" % MarketFormat.pct_text(ch.get("pct")), MUTED)
	t += "\nPermanent value:  [b]%s[/b]" % ("not published" if f["permanent_value"] == null else MarketFormat.compact(f["permanent_value"]))
	if not ch_p.is_empty():
		t += "  " + _c("(last change %s)" % MarketFormat.pct_text(ch_p.get("pct")), MUTED)
	t += "\nDemand:  physical %s,  permanent %s\n" % [
		"n/a" if f["physical_demand"] == null else "%d/10" % f["physical_demand"],
		"not published" if f["permanent_demand"] == null else "%d/10" % f["permanent_demand"]]
	t += "Trend:  " + _c("%s %s" % [MarketFormat.trend_glyph(f["market_trend"]), f["market_trend"]], MarketFormat.trend_color(f["market_trend"])) + "\n\n"
	t += _c("Beli dealer price (shop price, NOT a trading value): %s\n" % MarketFormat.compact(f["beli_price"]), MUTED)
	t += _c("Robux price: %s\n" % ("n/a" if f["robux_price"] == null else "R$" + str(f["robux_price"])), MUTED)
	t += _c("Source: %s  |  revised: %s  |  status: %s\n" % [f["source"], str(f["last_updated"]), f["confidence_status"]], MUTED)
	for fl in f["flags"]:
		t += _c("⚠ " + fl, WARN) + "\n"
	for c in FruitDatabase.conflicts_for(id):
		var parts: Array = []
		for src in c["values"]:
			parts.append("%s: %s" % [src, str(c["values"][src])])
		t += _c("⚠ Sources disagree on %s - %s" % [c["field"], "; ".join(parts)], WARN) + "\n"
	val_detail.text = t


# ---- Trade history ----------------------------------------------------------------------------------------

func _build_history() -> Control:
	var root := HBoxContainer.new()
	root.add_theme_constant_override("separation", 14)

	var left := _panel(1.0)
	var lv := VBoxContainer.new()
	left.add_child(lv)
	lv.add_child(_label("Saved trades", 24, CYAN))
	hist_list = ItemList.new()
	hist_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	hist_list.allow_reselect = true
	hist_list.item_selected.connect(_show_history)
	hist_list.item_clicked.connect(func(i: int, _p: Vector2, _b: int): _show_history(i))
	lv.add_child(hist_list)
	root.add_child(left)

	var right := _panel(1.2)
	var rv := VBoxContainer.new()
	right.add_child(rv)
	hist_detail = _rich()
	hist_detail.text = _c("Select a saved trade to see the details.", MUTED)
	rv.add_child(_scroll_of(hist_detail))
	var del := _button("Delete selected", "", 54)
	del.pressed.connect(func():
		if selected_hist >= 0:
			TradeHistory.remove_at(selected_hist)
			selected_hist = -1
			hist_detail.text = _c("Select a saved trade to see the details.", MUTED)
			_refresh_history())
	rv.add_child(del)
	root.add_child(right)
	return root


func _refresh_history() -> void:
	if hist_list == null:
		return
	hist_list.clear()
	for e in TradeHistory.entries:
		var now := TradeHistory.reevaluate(e, threshold)
		var tag := ""
		if now.has("label") and now["label"] != e["result"]:
			tag = "   → NOW: " + str(now["label"]).split(" - ")[0]
		var verdict: String = str(e["result"]).split(" - ")[0]
		hist_list.add_item("%s   %s%s" % [e["time"], verdict, tag])
		var c := MUTED
		match verdict:
			"WIN": c = GOOD
			"FAIR": c = WARN
			"LOSS": c = BAD
		hist_list.set_item_custom_fg_color(hist_list.item_count - 1, c)
	if selected_hist >= hist_list.item_count:
		selected_hist = -1


func _show_history(i: int) -> void:
	if i < 0 or i >= TradeHistory.entries.size():
		return
	selected_hist = i
	hist_list.select(i)
	var e: Dictionary = TradeHistory.entries[i]
	var t := "[b]Saved %s[/b]\n\nYou:  %s  (%s)\nThem:  %s  (%s)\n\nResult then:  %s\n\n" % [
		e["time"], _esc(", ".join(e["mine"])), MarketFormat.compact(e["mine_total"]),
		_esc(", ".join(e["theirs"])), MarketFormat.compact(e["their_total"]), e["result"]]
	var now := TradeHistory.reevaluate(e, threshold)
	if now.is_empty():
		t += _c("Re-evaluation not available (saved before item ids were recorded).", MUTED)
	elif now.has("missing"):
		t += _c("%s is no longer listed, so this trade cannot be re-evaluated." % now["missing"], WARN)
	else:
		t += "With current values:  You %s  |  Them %s\n→ %s" % [
			MarketFormat.compact(now["mine"]), MarketFormat.compact(now["theirs"]), now["label"]]
	hist_detail.text = t


# ---- Live assistant ----------------------------------------------------------------------------------------

func _live_market_text() -> String:
	if not FruitDatabase.has_data():
		return "Market values: none loaded. No verdicts can be given."
	var age := int(Time.get_unix_time_from_system()) - FruitDatabase.generated_unix()
	var s := "Market values: %s (community snapshot, not real-time)." % MarketDataManager.freshness_label()
	if age > 21600:
		s += " Values are old; check before trusting a verdict."
	return s


func _build_live() -> Control:
	var root := HBoxContainer.new()
	root.add_theme_constant_override("separation", 14)

	var left := _panel(1.3)
	var lv := VBoxContainer.new()
	left.add_child(lv)
	lv.add_child(_label("Need help with a trade?", 26, CYAN))
	lv.add_child(_label("Start asks Android for screen-capture permission. Your screen is analysed on this device only. One temporary frame file is kept and deleted when you stop. Nothing is uploaded or recorded. A notification with a Stop button shows while capturing.", 19, MUTED, true))
	live_market_lbl = _label(_live_market_text(), 19, MUTED, true)
	lv.add_child(live_market_lbl)
	root.add_child(left)

	var right := _panel(1.0)
	var rv := VBoxContainer.new()
	right.add_child(rv)
	rv.add_child(_label("Status", 22, MUTED))
	live_status = _label("Ready." if LiveCapture.available() else "Capture plugin not available (Android build only).", 22, TEXT, true)
	rv.add_child(live_status)
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	rv.add_child(spacer)
	var start := _button("Start live capture", "AccentButton", 62)
	start.pressed.connect(func(): LiveCapture.start())
	rv.add_child(start)
	var stop := _button("Stop", "", 62)
	stop.pressed.connect(func(): LiveCapture.stop())
	rv.add_child(stop)
	LiveCapture.status_changed.connect(func(t): live_status.text = t)
	root.add_child(right)
	return root


# ---- Settings ----------------------------------------------------------------------------------------------

func _setting_row(icon: String, title: String, sub: String, right: Control = null) -> Control:
	var row := PanelContainer.new()
	row.theme_type_variation = "RowPanel"
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 16)
	row.add_child(h)
	var ic := _label(icon, 34)
	ic.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	h.add_child(ic)
	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_theme_constant_override("separation", 0)
	v.add_child(_label(title, 23))
	_last_sub = _label(sub, 17, MUTED, true)
	v.add_child(_last_sub)
	h.add_child(v)
	if right != null:
		h.add_child(right)
	return row


func _build_settings() -> Control:
	var p := _panel(1.0)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 12)
	p.add_child(_scroll_of(v))
	v.add_child(_setting_row("⏱", "Auto update", "Refreshes every 15 minutes while the app is open, and on resume."))
	if MarketDataManager.background_sync_available():
		var cb := CheckButton.new()
		cb.button_pressed = MarketDataManager.bg_sync_enabled
		cb.toggled.connect(func(on): MarketDataManager.set_background_sync(on))
		v.add_child(_setting_row("🔔", "Background sync", "About hourly; Android decides when.", cb))
	else:
		v.add_child(_setting_row("🔔", "Background sync", "Available in the Android build once a data feed is configured."))
	v.add_child(_setting_row("🌐", "Data source", ItemDB.data_source))
	settings_source_lbl = _last_sub
	v.add_child(_setting_row("ℹ", "About", "Blox Trade AI  •  version 1.0.0\nValues are community estimates, not real-time prices."))
	return p
