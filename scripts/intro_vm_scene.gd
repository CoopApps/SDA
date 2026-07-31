extends Node2D

## Wires script_vm.gd (pure stepper) + intro_presenter.gd (presentation) for
## one chapter's episode intro. The presenter owns the titlecard/van-drive
## phase itself (not part of the VM script at all -- see intro_presenter.gd's
## class doc); only once that finishes does the VM start stepping the actual
## ROM-derived script.

const ScriptVMScript = preload("res://scripts/script_vm.gd")
const ScriptVMStateScript = preload("res://scripts/script_vm_state.gd")
const IntroPresenterScript = preload("res://scripts/intro_presenter.gd")

var vm
var presenter


func start(chapter: String) -> void:
	var path := "res://assets/intros/%s_intro.json" % chapter
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		printerr("IntroVMScene: missing %s" % path)
		return
	var data: Dictionary = JSON.parse_string(f.get_as_text())
	f.close()
	var events: Array = data.get("events", [])

	presenter = IntroPresenterScript.new()
	add_child(presenter)
	presenter.setup(chapter, events)

	var state = ScriptVMStateScript.new()
	vm = ScriptVMScript.new(events, state)
	presenter.attach(vm)

	await presenter.titlecard_done
	vm.run()
