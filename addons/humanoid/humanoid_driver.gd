# Copyright 2023-present Lyuma and contributors
# Copyright 2022-2023 lox9973
#
# SPDX-License-Identifier: Apache-2.0
@tool
extends Node
class_name HumanoidDriver

const human_trait_const: Resource = preload("human_trait.gd")
const humanoid_transform_util_const: Resource = preload("transform_util.gd")

@export var reset_pose: bool = false

@export var active: bool = false:
	set(value):
		if active == value:
			return
		active = value
		if not is_inside_tree():
			return
		if not active:
			_clear_silhouette_visualization()
		else:
			# If becoming active, re-apply visualization if debug flag is set
			_apply_or_clear_silhouette_visualization()

@export var skeleton: Skeleton3D = null
@export var hips_transform: Transform3D = Transform3D()

@export var muscle_settings: Array[float] = []
@export var bone_swing_twists: Array[Vector3] = []
@export var bone_leftovers: Array[Quaternion] = []

@export var debug_draw_silhouette: bool = false:
	set(value):
		if debug_draw_silhouette == value:
			return
		debug_draw_silhouette = value
		if not is_inside_tree():
			return
		_apply_or_clear_silhouette_visualization()
@export var silhouette_color: Color = Color(1.0, 0.0, 1.0, 0.75): # Magenta, 75% alpha
	set(value):
		if silhouette_color == value:
			return
		silhouette_color = value
		if _silhouette_material:
			_silhouette_material.albedo_color = silhouette_color
		# If visualization is active, the material property change will take effect immediately.

var _silhouette_material: StandardMaterial3D = null
var _original_material_overrides: Dictionary = {} # NodePath -> Material (original global override)
var _affected_mesh_instances: Array[NodePath] = []

func _init():
	muscle_settings.resize(human_trait_const.MuscleCount)
	muscle_settings.fill(0.0)
	bone_leftovers.resize(human_trait_const.BoneCount)
	bone_leftovers.fill(Quaternion.IDENTITY)

var humanoid_track_sets: Array[Array] = []

func _ready() -> void:
	_create_silhouette_material()
	_apply_or_clear_silhouette_visualization() # Apply based on initial state

func _exit_tree() -> void:
	_clear_silhouette_visualization()
	if _silhouette_material:
		_silhouette_material.free()
		_silhouette_material = null

func update_muscle_values() -> void:
	var bone_name_to_index: Dictionary = human_trait_const.bone_name_to_index() # String -> int
	var muscle_name_to_index: Dictionary = human_trait_const.muscle_name_to_index() # String -> int
	var muscle_index_to_bone_and_axis: Array[Vector2i] = human_trait_const.muscle_index_to_bone_and_axis() # int -> Vector2i
	
	var humanoid_track_sets: Array[Array] = []
	
	for i: int in range(human_trait_const.BoneCount + 1):
		if i == 0:
			humanoid_track_sets.append([null, null, null, null])
		else:
			humanoid_track_sets.append([null, null, null])
		
	for i: int in range(0, human_trait_const.MuscleCount):
		var muscle_bone_idx_axis: Vector2i = muscle_index_to_bone_and_axis[i]
		humanoid_track_sets[muscle_bone_idx_axis.x][muscle_bone_idx_axis.y] = muscle_settings[i]
	
		
	bone_swing_twists = []
	for i: int in range(0, human_trait_const.BoneCount):
		var new_vec: Vector3 = Vector3(0.0, 0.0, 0.0)
		if humanoid_track_sets[i][0] is float:
			new_vec.x = humanoid_track_sets[i][0]
		if humanoid_track_sets[i][1] is float:
			new_vec.y = humanoid_track_sets[i][1]
		if humanoid_track_sets[i][2] is float:
			new_vec.z = humanoid_track_sets[i][2]
			
		bone_swing_twists.append(new_vec)

func _process(_delta: float) -> void:
	if skeleton:
		if reset_pose:
			for i: int in range(0, skeleton.get_bone_count()):
				skeleton.set_bone_pose(i, skeleton.get_bone_rest(i))
			_clear_silhouette_visualization() # Clear silhouette if pose is reset
			return # If resetting pose, do nothing else this frame
	
	if not active and Engine.is_editor_hint():
		# Ensure silhouette is cleared if not active in editor, handled by 'active' setter too
		# _clear_silhouette_visualization() # Redundant due to 'active' setter
		return
	
	if not active: # Ensure silhouette is cleared if not active (runtime)
		# _clear_silhouette_visualization() # Redundant due to 'active' setter
		return

	if skeleton:
		update_muscle_values()
		
		var target_root_bone_idx: int = -1
		var target_hips_bone_idx: int = -1 # This is the bone *named* Hips or GodotHumanNames[0]

		# Pass 1: Reset bones and find target Root and Hips
		for i: int in range(0, skeleton.get_bone_count()):
			skeleton.set_bone_pose(i, skeleton.get_bone_rest(i)) # Reset to rest pose
			var bone_name_check: String = skeleton.get_bone_name(i)
			if bone_name_check == "Root" and target_root_bone_idx == -1:
				target_root_bone_idx = i
			# Check if this bone is mapped as Hips (humanoid_bone_id == 0)
			if human_trait_const.GodotHumanNames.find(bone_name_check) == 0 and target_hips_bone_idx == -1:
				target_hips_bone_idx = i
		
		var bone_to_receive_hips_transform: int = -1
		if target_root_bone_idx != -1:
			bone_to_receive_hips_transform = target_root_bone_idx
		elif target_hips_bone_idx != -1:
			bone_to_receive_hips_transform = target_hips_bone_idx
		else:
			var default_hips_name = human_trait_const.GodotHumanNames[0] if human_trait_const.GodotHumanNames.size() > 0 else "Hips"
			push_warning("HumanoidDriver: Neither 'Root' nor mapped '%s' bone found in target skeleton. Root motion from source will not be applied." % default_hips_name)

		# Pass 2: Apply muscle and leftover rotations to all mapped bones
		# that are NOT receiving the full hips_transform.
		for i: int in range(0, skeleton.get_bone_count()):
			if i == bone_to_receive_hips_transform:
				continue # This bone gets the full hips_transform later

			var bone_name: String = skeleton.get_bone_name(i)
			var humanoid_bone_id: int = human_trait_const.GodotHumanNames.find(bone_name)
			
			# Process if it's a mapped bone (humanoid_bone_id >= 0).
			# This includes Hips (humanoid_bone_id == 0) if Hips is not the bone_to_receive_hips_transform.
			if humanoid_bone_id >= 0:
				if humanoid_bone_id < bone_swing_twists.size(): # Ensure index is valid
					var this_swing_twist: Vector3 = bone_swing_twists[humanoid_bone_id]
					var pre_value: Quaternion = Quaternion() 
					var value: Quaternion = humanoid_transform_util_const.calculate_humanoid_rotation(humanoid_bone_id, this_swing_twist)
					var leftover_compensation: Quaternion = Quaternion.IDENTITY
					if humanoid_bone_id < bone_leftovers.size(): 
						leftover_compensation = bone_leftovers[humanoid_bone_id]
					
					skeleton.set_bone_pose_rotation(i, pre_value * value * leftover_compensation)
				else:
					push_warning("HumanoidDriver: humanoid_bone_id %d out of bounds for bone_swing_twists (size %d) for bone '%s'" % [humanoid_bone_id, bone_swing_twists.size(), bone_name])

		# Pass 3: Apply the full hips_transform (root motion)
		if bone_to_receive_hips_transform != -1:
			skeleton.set_bone_pose(bone_to_receive_hips_transform, hips_transform)

# Silhouette Visualization Functions
func _create_silhouette_material() -> void:
	if _silhouette_material == null:
		_silhouette_material = StandardMaterial3D.new()
		_silhouette_material.shading_mode = StandardMaterial3D.SHADING_MODE_UNSHADED
		_silhouette_material.albedo_color = silhouette_color
		_silhouette_material.cull_mode = BaseMaterial3D.CULL_FRONT
		_silhouette_material.transparency = StandardMaterial3D.TRANSPARENCY_ALPHA

func _get_relevant_mesh_instances() -> Array[MeshInstance3D]:
	var meshes: Array[MeshInstance3D] = []
	if not skeleton:
		return meshes

	# Case 1: MeshInstance3D is a direct child of Skeleton3D
	for i in range(skeleton.get_child_count()):
		var child = skeleton.get_child(i)
		if child is MeshInstance3D:
			meshes.append(child)

	# Case 2: MeshInstance3D is a sibling (or elsewhere) and its .skeleton property points to this Skeleton3D
	var skeleton_parent = skeleton.get_parent()
	if skeleton_parent:
		# Correctly call find_children and iterate over its result.
		# The fourth argument 'owned' was effectively 'false' in the original incorrect code
		# due to an empty array evaluating to false in a boolean context.
		# We'll use 'false' to maintain wider search capabilities.
		var potential_mesh_nodes: Array[Node] = skeleton_parent.find_children("*", "MeshInstance3D", true, false)
		for mesh_node in potential_mesh_nodes:
			var mesh_instance := mesh_node as MeshInstance3D
			# mesh_instance should be valid due to type filter, but check is safe.
			if mesh_instance and mesh_instance.skeleton == skeleton.get_path():
				if not meshes.has(mesh_instance): # Avoid duplicates
					meshes.append(mesh_instance)
	return meshes

func _apply_silhouette_visualization() -> void:
	_clear_silhouette_visualization() # Ensure clean state before applying
	
	if not active or not skeleton or not _silhouette_material:
		return

	var mesh_instances: Array[MeshInstance3D] = _get_relevant_mesh_instances()

	for mesh_instance in mesh_instances:
		var mesh_path: NodePath = mesh_instance.get_path()
		_affected_mesh_instances.append(mesh_path)
		# Store the current global material override.
		# If it's null, it means surface materials are active. Restoring null will revert to that.
		_original_material_overrides[mesh_path] = mesh_instance.material_override
		mesh_instance.material_override = _silhouette_material

func _clear_silhouette_visualization() -> void:
	for mesh_path_np in _affected_mesh_instances:
		var mesh_instance: MeshInstance3D = get_node_or_null(mesh_path_np) as MeshInstance3D
		if mesh_instance and _original_material_overrides.has(mesh_path_np):
			var original_override = _original_material_overrides[mesh_path_np]
			mesh_instance.material_override = original_override
	
	_original_material_overrides.clear()
	_affected_mesh_instances.clear()

func _apply_or_clear_silhouette_visualization() -> void:
	if debug_draw_silhouette and active:
		_apply_silhouette_visualization()
	else:
		_clear_silhouette_visualization()

func _get_property_list() -> Array[Dictionary]:
	var properties: Array[Dictionary] = []
	for i: int in range(0, human_trait_const.MuscleCount):
		properties.append({
			"name": "muscle_settings/" + human_trait_const.MuscleName[i],
			"type": TYPE_FLOAT,
			"hint": PROPERTY_HINT_RANGE,
			"hint_string": "-1.0, 1.0",
		})
	return properties
	
func _get(property: StringName) -> Variant:
	var found_index: int = human_trait_const.MuscleName.find(property.lstrip("muscle_settings/"))
	if found_index >= 0:
		return muscle_settings[found_index]
		
	return null
	
func _set(property: StringName, value: Variant) -> bool:
	var found_index: int = human_trait_const.MuscleName.find(property.lstrip("muscle_settings/"))
	if found_index >= 0:
		if typeof(value) == TYPE_FLOAT:
			muscle_settings[found_index] = value as float
			return true
		
	return false

func _property_can_revert(p_property: StringName) -> bool:
	var found_index: int = human_trait_const.MuscleName.find(p_property.lstrip("muscle_settings/"))
	if found_index >= 0:
		return true
	
	return false
	
func _property_get_revert(p_property: StringName) -> Variant:
	var found_index: int = human_trait_const.MuscleName.find(p_property.lstrip("muscle_settings/"))
	if found_index >= 0:
		return 0.0
	
	return null
