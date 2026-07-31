extends CanvasLayer
class_name ChoiceBar

## Dialogue-choice selector — the port's presentation of the ROM's choice-thread
## scheduler (script op $02 register_choice_option, ROM $25AC / ROM_MAP row 116;
## thread tables $FF0838, navigate rows 87-90). Data comes from
## assets/data/global/choices_<chapter>.json (tools/gen_choices.py):
## label = the player's line, reply = the NPC's answer.
##
## Mouse: click a line. Gamepad/keyboard: ui_up / ui_down / ui_accept to pick,
## ui_cancel to dismiss — one resolver for both, per the input design.

signal choice_selected(index: int, choice: Dictionary)
signal dismissed

const LINE_H := 11
const PAD := 4
const BG := Color(0.06, 0.06, 0.10, 0.92)
const FG := Color(0.86, 0.86, 0.78)
const HI := Color(1.0, 0.85, 0.3)

var _choices: Array = []
var _sel := 0
var _panel: Control
var _labels: Array = []

func _ready() -> void:
	layer = 90
	_ensure_panel()
	visible = false

func _ensure_panel() -> void:
	if _panel == null:
		_panel = Control.new()
		add_child(_panel)

func open(choices: Array) -> void:
	_ensure_panel()
	_choices = choices
	_sel = 0
	for l in _labels:
		l.queue_free()
	_labels = []
	var vp := Vector2(320, 200)          # project viewport (320x200 SCUMM layout)
	if _panel.is_inside_tree():
		vp = _panel.get_viewport_rect().size
	var h := PAD * 2 + LINE_H * choices.size()
	var bg := ColorRect.new()
	bg.color = BG
	bg.position = Vector2(0, vp.y - h)
	bg.size = Vector2(vp.x, h)
	_panel.add_child(bg)
	_labels.append(bg)
	for i in range(choices.size()):
		var lbl := Label.new()
		lbl.text = str(choices[i].get("label", ""))
		lbl.position = Vector2(PAD + 6, vp.y - h + PAD + i * LINE_H - 1)
		lbl.add_theme_font_size_override("font_size", 8)
		lbl.add_theme_color_override("font_color", FG)
		lbl.mouse_filter = Control.MOUSE_FILTER_STOP
		var idx := i
		lbl.gui_input.connect(func(ev: InputEvent) -> void:
			if ev is InputEventMouseButton and ev.pressed \
					and ev.button_index == MOUSE_BUTTON_LEFT:
				_pick(idx))
		lbl.mouse_entered.connect(func() -> void:
			_sel = idx
			_update_highlight())
		_panel.add_child(lbl)
		_labels.append(lbl)
	_update_highlight()
	visible = true

func close() -> void:
	visible = false
	for l in _labels:
		l.queue_free()
	_labels = []
	_choices = []

func is_open() -> bool:
	return visible

func _update_highlight() -> void:
	for i in range(1, _labels.size()):        # index 0 is the bg rect
		var lbl: Label = _labels[i]
		var on := (i - 1) == _sel
		lbl.add_theme_color_override("font_color", HI if on else FG)
		lbl.text = ("> " if on else "  ") + str(_choices[i - 1].get("label", ""))

func _pick(i: int) -> void:
	if i < 0 or i >= _choices.size():
		return
	var c: Dictionary = _choices[i]
	close()
	choice_selected.emit(i, c)

func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event.is_action_pressed("ui_down"):
		_sel = (_sel + 1) % _choices.size()
		_update_highlight()
		_panel.get_viewport().set_input_as_handled()
	elif event.is_action_pressed("ui_up"):
		_sel = (_sel - 1 + _choices.size()) % _choices.size()
		_update_highlight()
		_panel.get_viewport().set_input_as_handled()
	elif event.is_action_pressed("ui_accept"):
		_pick(_sel)
		_panel.get_viewport().set_input_as_handled()
	elif event.is_action_pressed("ui_cancel"):
		close()
		dismissed.emit()
		_panel.get_viewport().set_input_as_handled()
