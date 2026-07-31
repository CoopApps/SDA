extends Node2D

## vm_presenter.gd -- base class for anything that visualizes a ScriptVM's
## signal stream (see script_vm.gd). Owns ONLY the plumbing: attach to a VM
## instance, forward its two signals to overridable hooks, and guarantee
## vm.resume() always eventually fires even if a subclass's blocking
## handler is a no-op -- so a missing handler can never silently hang the
## stepper the way an unresolved blocking op did during this project's
## first live test (see the "deferred emit" gotcha in
## memory/scooby_godot_port.md).
##
## All actual drawing/animation belongs in a concrete subclass --
## intro_presenter.gd (cinematic) -- which `extends
## "res://scripts/vm_presenter.gd"` and overrides _on_op_fired() /
## _handle_blocking(). (The interactive-room subclass room_presenter.gd was
## removed as dead code -- gameplay uses main_gameplay/room/room_behavior_runner.)

var vm


func attach(vm_) -> void:
	vm = vm_
	vm.op_fired.connect(_on_op_fired)
	vm.op_blocking.connect(_on_op_blocking_internal)


## Override in a subclass: fire-and-forget ops (anything not in
## script_vm.gd's BLOCKING_OPS) land here and stepping has already moved on.
func _on_op_fired(_op_name: String, _data: Dictionary) -> void:
	pass


func _on_op_blocking_internal(op_name: String, data: Dictionary) -> void:
	await _handle_blocking(op_name, data)
	vm.resume()


## Override in a subclass. Default: every blocking op resolves instantly --
## a subclass adds real waiting (Tween/timer/await process_frame) only for
## the ops it actually cares about presenting.
func _handle_blocking(_op_name: String, _data: Dictionary) -> void:
	pass
