PlayerCivilian = PlayerCivilian or class(PlayerStandard)

-- Lines: 3 to 5
function PlayerCivilian:init(unit)
	PlayerCivilian.super.init(self, unit)
end

-- Lines: 7 to 18
function PlayerCivilian:enter(state_data, enter_data)
	PlayerCivilian.super.enter(self, state_data, enter_data)
	MenuCallbackHandler:_update_outfit_information()

	local selected_equipment = managers.player:selected_equipment()

	if selected_equipment then
		managers.player:update_deployable_equipment_amount_to_peers(selected_equipment.equipment, 0)
	end
end

-- Lines: 20 to 57
function PlayerCivilian:_enter(enter_data)
	local equipped_selection = self._unit:inventory():equipped_selection()

	if equipped_selection ~= 1 then
		self._previous_equipped_selection = equipped_selection

		self._ext_inventory:equip_selection(1, false)
		managers.upgrades:setup_current_weapon()
	end

	if self._unit:camera():anim_data().equipped then
		self._unit:camera():play_redirect(self:get_animation("unequip"))
	end

	self._unit:base():set_slot(self._unit, 4)
	self._ext_movement:set_attention_settings({"pl_civilian"})

	if not managers.groupai:state():enemy_weapons_hot() then
		self._enemy_weapons_hot_listen_id = "PlayerCivilian" .. tostring(self._unit:key())

		managers.groupai:state():add_listener(self._enemy_weapons_hot_listen_id, {"enemy_weapons_hot"}, callback(self, self, "clbk_enemy_weapons_hot"))
	end

	self._ext_network:send("set_stance", 1, false, false)

	self._show_casing_t = Application:time() + 4
end

-- Lines: 59 to 98
function PlayerCivilian:exit(state_data, new_state_name)
	PlayerCivilian.super.exit(self, state_data)
	MenuCallbackHandler:_update_outfit_information()

	local selected_equipment = managers.player:selected_equipment()

	if selected_equipment and selected_equipment.amount and type(selected_equipment.amount) == "string" then
		local amount = Application:digest_value(selected_equipment.amount, false)

		managers.player:update_deployable_equipment_amount_to_peers(selected_equipment.equipment, amount)
	end

	managers.hud:hide_casing()

	if self._previous_equipped_selection then
		self._unit:inventory():equip_selection(self._previous_equipped_selection, false)

		self._previous_equipped_selection = nil
	end

	self._unit:base():set_slot(self._unit, 2)

	if self._enemy_weapons_hot_listen_id then
		managers.groupai:state():remove_listener(self._enemy_weapons_hot_listen_id)

		self._enemy_weapons_hot_listen_id = nil
	end
end

-- Lines: 101 to 108
function PlayerCivilian:update(t, dt)
	PlayerCivilian.super.update(self, t, dt)

	if self._show_casing_t and self._show_casing_t < t then
		self._show_casing_t = nil

		managers.hud:show_casing("civilian")
	end
end

-- Lines: 114 to 161
function PlayerCivilian:_update_check_actions(t, dt)
	local input = self:_get_input(t, dt)
	self._stick_move = self._controller:get_input_axis("move")

	if mvector3.length(self._stick_move) < 0.1 or self:_interacting() then
		self._move_dir = nil
	else
		self._move_dir = mvector3.copy(self._stick_move)
		local cam_flat_rot = Rotation(self._cam_fwd_flat, math.UP)

		mvector3.rotate_with(self._move_dir, cam_flat_rot)
	end

	self:_update_interaction_timers(t)

	if input.btn_stats_screen_press then
		self._unit:base():set_stats_screen_visible(true)
	elseif input.btn_stats_screen_release then
		self._unit:base():set_stats_screen_visible(false)
	end

	self:_update_foley(t, input)

	local new_action = nil
	new_action = new_action or self:_check_action_interact(t, input)

	if not new_action and self._state_data.ducking then
		self:_end_action_ducking(t)
	end

	self:_check_action_jump(t, input)
	self:_check_action_duck(t, input)
	self:_check_action_run(t, input)
	self:_check_action_use_item(t, input)
end

-- Lines: 166 to 200
function PlayerCivilian:_check_action_interact(t, input)
	local new_action, timer, interact_object = nil

	if input.btn_interact_press then
		local action_forbidden = self:chk_action_forbidden("interact") or self._unit:base():stats_screen_visible() or self:_interacting() or self._ext_movement:has_carry_restriction() or self:_on_zipline()

		if not action_forbidden then
			new_action, timer, interact_object = managers.interaction:interact(self._unit)

			if timer then
				new_action = true

				self._ext_camera:camera_unit():base():set_limits(80, 50)
				self:_start_action_interact(t, input, timer, interact_object)
			end
		end

		if not new_action then
			managers.hint:show_hint("clean_block_interact")
		end
	end

	if input.btn_interact_release then
		self:_interupt_action_interact()
	end

	return new_action
end

-- Lines: 203 to 211
function PlayerCivilian:_start_action_interact(t, input, timer, interact_object)
	self._interact_expire_t = timer
	self._interact_params = {
		object = interact_object,
		timer = timer,
		tweak_data = interact_object:interaction().tweak_data
	}

	managers.hud:show_interaction_bar(0, timer)
	managers.network:session():send_to_peers_synched("sync_teammate_progress", 1, true, self._interact_params.tweak_data, timer, false)
end

-- Lines: 213 to 225
function PlayerCivilian:_interupt_action_interact(t, input, complete)
	if self._interact_expire_t then
		self._interact_expire_t = nil

		if alive(self._interact_params.object) then
			self._interact_params.object:interaction():interact_interupt(self._unit, complete)
		end

		self._ext_camera:camera_unit():base():remove_limits()
		managers.interaction:interupt_action_interact(self._unit)
		managers.hud:hide_interaction_bar(complete)
		managers.network:session():send_to_peers_synched("sync_teammate_progress", 1, false, self._interact_params.tweak_data, 0, complete and true or false)

		self._interact_params = nil
	end
end

-- Lines: 227 to 252
function PlayerCivilian:_update_interaction_timers(t)
	if self._interact_expire_t then
		local dt = self:_get_interaction_speed()
		self._interact_expire_t = self._interact_expire_t - dt

		if not alive(self._interact_params.object) or self._interact_params.object ~= managers.interaction:active_unit() or self._interact_params.tweak_data ~= self._interact_params.object:interaction().tweak_data or self._interact_params.object:interaction():check_interupt() then
			self:_interupt_action_interact(t)
		else
			managers.hud:set_interaction_bar_width(self._interact_params.timer - self._interact_expire_t, self._interact_params.timer)

			if self._interact_expire_t <= 0 then
				self:_end_action_interact(t)

				self._interact_expire_t = nil
			end
		end
	end
end

-- Lines: 256 to 260
function PlayerCivilian:_check_action_jump(t, input)
	if input.btn_duck_press then
		managers.hint:show_hint("clean_block_interact")
	end
end

-- Lines: 262 to 266
function PlayerCivilian:_check_action_duck(t, input)
	if input.btn_jump_press then
		managers.hint:show_hint("clean_block_interact")
	end
end

-- Lines: 268 to 272
function PlayerCivilian:_check_action_run(t, input)
	if input.btn_run_press then
		managers.hint:show_hint("clean_block_interact")
	end
end

-- Lines: 274 to 278
function PlayerCivilian:_check_action_use_item(t, input)
	if input.btn_use_item_press then
		managers.hint:show_hint("clean_block_interact")
	end
end

-- Lines: 280 to 286
function PlayerCivilian:clbk_enemy_weapons_hot()
	if self._enemy_weapons_hot_listen_id then
		managers.groupai:state():remove_listener(self._enemy_weapons_hot_listen_id)

		self._enemy_weapons_hot_listen_id = nil
	end
end

-- Lines: 288 to 289
function PlayerCivilian:interaction_blocked()
	return false
end

-- Lines: 292 to 293
function PlayerCivilian:_get_walk_headbob()
	return 0.0125
end

