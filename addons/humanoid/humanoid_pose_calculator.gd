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
class_name HumanoidPoseCalculator

const human_trait: Resource = preload("human_trait.gd")
const humanoid_transform_util: Resource = preload("transform_util.gd")

@export var active: bool = false
@export var skeleton: Skeleton3D = null
@export var target: HumanoidDriver = null
@export var force_rest_pose: bool = false
@export var force_bicycle_pose: bool = false

var bone_and_axis_to_coefficent_mapping_table: Array[Array] = []
	
func precalculate_bone_axis_table() -> void:
	var bone_name_to_index: Dictionary = human_trait.bone_name_to_index() # String -> int
	var muscle_name_to_index: Dictionary = human_trait.muscle_name_to_index() # String -> int
	var muscle_index_to_bone_and_axis: Array[Vector2i] = human_trait.muscle_index_to_bone_and_axis() # int -> Vector2i
		
	bone_and_axis_to_coefficent_mapping_table = []
	for i: int in range(human_trait.BoneCount + 1):
		if i == 0:
			bone_and_axis_to_coefficent_mapping_table.append([null, null, null, null])
		else:
			bone_and_axis_to_coefficent_mapping_table.append([null, null, null])
			
	for i: int in range(0, human_trait.MuscleCount):
		var muscle_bone_idx_axis: Vector2i = muscle_index_to_bone_and_axis[i]
		bone_and_axis_to_coefficent_mapping_table[muscle_bone_idx_axis.x][muscle_bone_idx_axis.y] = i


func apply_pose_to_humanoid_driver_coefficents() -> void:
	if not active and Engine.is_editor_hint():
		return
	
	precalculate_bone_axis_table()
	
	if skeleton:
		if force_bicycle_pose or force_rest_pose:
			for bone_idx: int in range(0, skeleton.get_bone_count()):
				var transform: Transform3D = Transform3D()
				transform.origin = skeleton.get_bone_rest(bone_idx).origin
				transform.basis = skeleton.get_bone_rest(bone_idx).basis.orthonormalized()
				
				skeleton.set_bone_pose(bone_idx, transform)
		
		var leftovers: Array[Quaternion]
		for bone_idx: int in range(0, skeleton.get_bone_count()):
			var bone_name: String = skeleton.get_bone_name(bone_idx)
			var humanoid_bone_id: int = human_trait.GodotHumanNames.find(bone_name)
			if humanoid_bone_id >= 0:
				while len(leftovers) <= humanoid_bone_id:
					leftovers.append(Quaternion.IDENTITY)
				var reference_pose: Quaternion = human_trait.preQ_exported[humanoid_bone_id] * human_trait.postQ_inverse_exported[humanoid_bone_id]
				if force_bicycle_pose:
					skeleton.set_bone_pose_rotation(bone_idx, reference_pose)
				
				var custom_pose: Quaternion = skeleton.get_bone_pose(bone_idx).basis.get_rotation_quaternion()
				
				if humanoid_bone_id == 0:
					target.hips_transform = skeleton.get_bone_pose(bone_idx)
				else:
					if humanoid_bone_id >= 1:
						var muscle_triplet_vector: Vector3 = humanoid_transform_util.inverse_calculate_humanoid_rotation(leftovers, humanoid_bone_id, custom_pose)
						if target:
							var muscle_from_bone: Array = bone_and_axis_to_coefficent_mapping_table[humanoid_bone_id]
							var muscle_triplet: Array[float] = [muscle_triplet_vector.x, muscle_triplet_vector.y, muscle_triplet_vector.z]
							
							for i in range(0, 3):
								if muscle_from_bone[i] is int:
									target.set(human_trait.MuscleName[muscle_from_bone[i]], muscle_triplet[i])

func _process(_delta: float) -> void:
	apply_pose_to_humanoid_driver_coefficents()
