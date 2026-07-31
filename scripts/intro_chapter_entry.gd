extends Node2D

## Entry point scene for the hotel/carnival episode intro: wires
## script_vm.gd + intro_presenter.gd (titlecard -> van drive -> room 3 chat),
## which then hands off to Room9Intro.tscn once it reaches the excluded room.

const IntroVMSceneScript := preload("res://scripts/intro_vm_scene.gd")

@export var chapter := "hotel"


func _ready() -> void:
	var scene = IntroVMSceneScript.new()
	add_child(scene)
	scene.start(chapter)
