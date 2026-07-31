extends SceneTree
## Validates the lifted dialogue-choice data + the ChoiceBar selection flow:
## every choice has a label; known conversations are present; selecting via the
## signal path returns the right record.

func _init() -> void:
	var doc: Variant = null
	var f := FileAccess.open("res://assets/data/global/choices_hotel.json", FileAccess.READ)
	if f != null:
		doc = JSON.parse_string(f.get_as_text())
	var ok_data := doc is Dictionary and (doc as Dictionary).has("choices")
	var choices: Dictionary = doc.get("choices", {}) if ok_data else {}
	var total := 0
	var bad := 0
	for eid in choices:
		for c in choices[eid]:
			total += 1
			if str(c.get("label", "")) == "":
				bad += 1
	# known ground truth from the ROM lift
	var cook: Array = choices.get("125", [])
	var cook_ok := false
	for c in cook:
		if str(c.get("label", "")).begins_with("Hey, where's the chow?"):
			cook_ok = str(c.get("reply", "")).begins_with("You kids look well fed")
	print("[choices_test] hotel: entities=", choices.size(), " choices=", total, " empty_labels=", bad)
	print("[choices_test] Cook conversation lifted correctly: ", cook_ok)

	# ChoiceBar selection flow (headless: drive _pick directly)
	var Bar := load("res://scripts/choice_bar.gd")
	var bar = Bar.new()
	get_root().add_child(bar)
	var picked: Array = []
	bar.choice_selected.connect(func(i: int, c: Dictionary) -> void:
		picked.append(i)
		picked.append(c))
	bar.open([{"label": "A", "reply": "ra"}, {"label": "B", "reply": "rb"}])
	var was_open: bool = bar.is_open()
	bar._pick(1)
	var sel_ok: bool = picked.size() == 2 and int(picked[0]) == 1 \
		and str(picked[1]["reply"]) == "rb" and not bar.is_open()
	print("[choices_test] bar open=", was_open, " select flow ok=", sel_ok)
	var all_ok := ok_data and bad == 0 and cook_ok and was_open and sel_ok
	print("[choices_test] RESULT: ", ("PASS" if all_ok else "FAIL"))
	quit()
