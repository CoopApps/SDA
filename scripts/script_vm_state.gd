extends RefCounted
class_name ScriptVMState

## Minimal state store script_vm.gd needs to evaluate conditions (opcodes
## 0x03/0x04) and apply assigns (0x08/0x09): the global flag-bit array (ROM
## $FF2A00) and per-actor integer fields (ROM actor record $FF1200+id*26,
## addressed here as flat byte offsets from that record's base -- see
## memory scooby_entity_records.md). Deliberately NOT the actor's visual
## state (position/sprite/anim) -- that stays presenter-owned; this only
## holds the VM-legible fields a condition or assign can read/write.

var _flags: Dictionary = {}         # {byte_index: {bit: bool}}
var _actor_fields: Dictionary = {}  # {actor_id: {field_offset: int}}


func get_flag(byte_index: int, bit: int) -> bool:
	var byte: Dictionary = _flags.get(byte_index, {})
	return bool(byte.get(bit, false))


func set_flag(byte_index: int, bit: int, value: bool) -> void:
	if not _flags.has(byte_index):
		_flags[byte_index] = {}
	_flags[byte_index][bit] = value


func get_actor_field(actor_id: int, field_offset: int) -> int:
	var rec: Dictionary = _actor_fields.get(actor_id, {})
	return int(rec.get(field_offset, 0))


func set_actor_field(actor_id: int, field_offset: int, value: int) -> void:
	if not _actor_fields.has(actor_id):
		_actor_fields[actor_id] = {}
	_actor_fields[actor_id][field_offset] = value
