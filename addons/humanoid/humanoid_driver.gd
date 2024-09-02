# -!- coding: utf-8 -!-
#
# Copyright 2023-present Lyuma and contributors
# Copyright 2022-2023 lox9973
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#	 http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# SPDX-License-Identifier: Apache-2.0
@tool
extends Node
class_name HumanoidDriver

const human_trait_const: Resource = preload("human_trait.gd")
const humanoid_transform_util_const: Resource = preload("transform_util.gd")

@export var reset_pose: bool = false

@export var active: bool = false
@export var skeleton: Skeleton3D = null
@export var hips_transform: Transform3D = Transform3D()

var muscle_settings: Array[float]

func _init():
	muscle_settings.resize(human_trait_const.MuscleCount)
	muscle_settings.fill(0.0)

var bone_swing_twists: Array[Vector3] = []

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
	
	if not active and Engine.is_editor_hint():
		return
	
	if skeleton:
		update_muscle_values()
		for i: int in range(0, skeleton.get_bone_count()):
			skeleton.set_bone_pose(i, skeleton.get_bone_rest(i))
			var bone_name: String = skeleton.get_bone_name(i)
			var humanoid_bone_id: int = human_trait_const.GodotHumanNames.find(bone_name)
			if humanoid_bone_id >= 0:
				if humanoid_bone_id == 0:
					skeleton.set_bone_pose(i, Transform3D())
				else:
					var affected_by_bone_idx: int = human_trait_const.extraAffectedByBones.get(humanoid_bone_id, -1)
					var weight = 1.0
					var this_swing_twist: Vector3 = Vector3(bone_swing_twists[humanoid_bone_id])
					#if humanoid_bone_id == 11:
					#	print(this_swing_twist)
					var pre_value: Quaternion = Quaternion()
					
					"""
					if affected_by_bone_idx != -1:
						weight = 0.5
						this_swing_twist.x *= weight
						var affected_by_twist: Vector3 = Vector3(bone_swing_twists[affected_by_bone_idx])
						affected_by_twist = Vector3(affected_by_twist.x * (1.0 - weight), 0, 0)
						pre_value = humanoid_transform_util_const.calculate_humanoid_rotation(affected_by_bone_idx, affected_by_twist, true)
					"""
					
					var value: Quaternion = humanoid_transform_util_const.calculate_humanoid_rotation(humanoid_bone_id, this_swing_twist)
					skeleton.set_bone_pose_rotation(i, pre_value * value)
					
		skeleton.set_bone_pose(0, hips_transform)
					
func _get_property_list() -> Array[Dictionary]:
	var properties: Array[Dictionary] = []
	
	for i: int in range(0, human_trait_const.MuscleCount):
		properties.append({
			"name": "muscle_settings/" + human_trait_const.MuscleName[i],
			"type": TYPE_FLOAT,
			"hint": PROPERTY_HINT_RANGE,
			"hint_string": "-1.0, 1.0",
		})
	
	print(properties)
	
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
