package main

import "core:fmt"
import "core:math"
import "core:math/rand"
import "core:path/filepath"
import "core:strings"
import "core:time"
import "core:hash"

import rl "vendor:raylib"


// GUI

Gui_Id :: distinct u64


GUI_State :: struct {
	width, height: i32,

	hover_id, active_id: Gui_Id,
	last_hover_id, last_active_id: Gui_Id,
	updated_hover:  bool,
	updated_active: bool,

	mouse_pos: rl.Vector2,
	last_mouse_pos: rl.Vector2,

	current_time: f64,
	delta_time:   f64,

	hover_in_time: f64,

	active_in_time:  f64,
	active_out_time: f64,
	last_pressed_id: Gui_Id,

	mouse_down:     bool,
	mouse_pressed:  bool,
	mouse_released: bool,
}


Game_Table :: struct {
	opponent_deck: [dynamic]Card,
	player_deck:   [dynamic]Card,

	opponent_discard: [dynamic]Card,
	player_discard:   [dynamic]Card,

	opponent_cards: [STACK_COUNT]Table_Card,
	player_cards:   [STACK_COUNT]Table_Card,

	force_player_draw_idx: int,

	gui_state: GUI_State,
}

Control_Result :: enum u32 {
	Click,
	// Right_Click,
	Dragging,
	Active_In,
	Active_Out,
	Hover_In,
	Hover_Out,
}
Control_Result_Set :: distinct bit_set[Control_Result; u32]

@(require_results)
update_control :: proc(gui: ^GUI_State, id: Gui_Id, rect: rl.Rectangle) -> (res: Control_Result_Set) {
	set_active :: proc(state: ^GUI_State, id: Gui_Id) {
		state.active_id = id
		state.updated_active = true
	}
	set_hover :: proc(state: ^GUI_State, id: Gui_Id) {
		state.hover_id = id
		state.updated_hover = true
	}

	hovered := rl.CheckCollisionPointRec(gui.mouse_pos, rect)

	if hovered && (!gui.mouse_down || gui.active_id == id) && gui.hover_id != id {
		set_hover(gui, id)
		if gui.hover_id == id {
			res += {.Hover_In}
		}
	}

	if gui.active_id == id {
		if gui.mouse_pressed && !hovered || !gui.mouse_down  {
			set_active(gui, 0)
		} else {
			gui.updated_active = true
			if gui.mouse_down || gui.mouse_pressed {
				res += {.Dragging}
			}
		}
	}

	if gui.hover_id == id {
		gui.updated_hover = true
		if gui.mouse_pressed && gui.active_id != id {
			set_active(gui, id)
			res += {.Active_In}
			gui.active_in_time = gui.current_time
			gui.last_pressed_id = id
		} else if !hovered {
			set_hover(gui, 0)
			res += {.Hover_Out}
		}
	}

	if gui.active_id != id && gui.last_active_id == id {
		res += {.Active_Out}
		gui.active_out_time = gui.current_time
	}

	if gui.hover_id == id && gui.mouse_pressed {
		res += {.Click}
	}

	return
}

gui_start :: proc(gui: ^GUI_State, render_width, render_height: i32) {
	gui.width = render_width
	gui.height = render_height

	prev_current_time := gui.current_time
	gui.current_time = rl.GetTime()
	gui.delta_time = gui.current_time - prev_current_time

	gui.mouse_down     = rl.IsMouseButtonDown(.LEFT)
	gui.mouse_pressed  = rl.IsMouseButtonPressed(.LEFT)
	gui.mouse_released = rl.IsMouseButtonPressed(.LEFT)


	{ // scale mouse position
		w := f32(render_width)
		h := f32(render_height)

		sw := f32(max(rl.GetScreenWidth(), 1))
		sh := f32(max(rl.GetScreenHeight(), 1))

		mouse_pos := rl.GetMousePosition()
		mouse_pos.x /= sw
		mouse_pos.y /= sh

		scale := min(sw/w, sh/h)

		mouse_pos.x -= 0.5
		mouse_pos.y -= 0.5
		mouse_pos.x *= sw/(scale*w)
		mouse_pos.y *= sh/(scale*h)
		mouse_pos.x += 0.5
		mouse_pos.y += 0.5

		mouse_pos.x *= w
		mouse_pos.y *= h

		gui.mouse_pos = mouse_pos
	}


	switch {
	case gui.active_id != 0:
		rl.SetMouseCursor(.CROSSHAIR)
	case gui.hover_id != 0:
		rl.SetMouseCursor(.POINTING_HAND)
	case:
		rl.SetMouseCursor(.DEFAULT)
	}


}


gui_end :: proc(gui: ^GUI_State) {
	if gui.hover_id != gui.last_hover_id || gui.active_id == gui.hover_id {
		gui.hover_in_time = gui.current_time
	}

	gui.last_active_id = gui.active_id
	gui.last_hover_id  = gui.hover_id

	if !gui.updated_active {
		gui.active_id = 0
	}
	gui.updated_active = false


	if !gui.updated_hover {
		gui.hover_id = 0
	}
	gui.updated_hover = false

	gui.last_mouse_pos = gui.mouse_pos
}

// Game

Card_Suit :: enum u8 {
	None,
	Diamonds,
	Clubs,
	Hearts,
	Spades,
}

Card_Value :: enum u8 {
	Joker,
	Ace,
	Two,
	Three,
	Four,
	Five,
	Six,
	Seven,
	Eight,
	Nine,
	Ten,
	Jack,
	Queen,
	King,
}

Card :: struct {
	suit:         Card_Suit,
	value:        Card_Value,
	texture:      rl.Texture2D,
	back_texture: rl.Texture2D,
}

card_suit_texture_names := [Card_Suit]string{
	.None     = "",
	.Diamonds = "Diamonds",
	.Clubs    = "Clubs",
	.Hearts   = "Hearts",
	.Spades   = "Spades",
}

card_value_texture_names := [Card_Value]string{
	.Joker = "Joker",
	.Ace   = "A",
	.Two   = "2",
	.Three = "3",
	.Four  = "4",
	.Five  = "5",
	.Six   = "6",
	.Seven = "7",
	.Eight = "8",
	.Nine  = "9",
	.Ten   = "10",
	.Jack  = "J",
	.Queen = "Q",
	.King  = "K",
}

card_textures: map[string]rl.Texture2D


Table_Card_State :: enum u8 {
	Dead,
	Alive,
	Drag,
}

Table_Card :: struct {
	card:     Card,
	state:    Table_Card_State,

	drag_rotation: f64,
	drag_end_time: f64,

	health:   i8,
	pack_idx: u8,
	position: rl.Vector2,
	rect:     rl.Rectangle,
	is_over:  bool,

	is_over_start_time: f64,
	is_over_end_time:   f64,
	is_over_rotation:   f64,
}

STACK_COUNT :: 3



card_health :: proc(value: Card_Value) -> i8 {
	#partial switch value {
	case .Ace:   return 11
	case .Joker: return 13

	case .Jack:  return 11
	case .Queen: return 12
	case .King:  return 13
	}
	return i8(value)
}

make_table_card :: proc(card: Card) -> Table_Card {
	return {
		card = card,
		state = .Alive,
		health = card_health(card.value),
	}
}
Difficulty :: enum {
	Easy,
	Medium,
	Hard,
}

init_table :: proc(table: ^Game_Table, difficulty: Difficulty) {
	make_card :: proc(value: Card_Value, suit: Card_Suit, back_texture: rl.Texture2D) -> Card {
		if value == .Joker {
			str := fmt.tprintf("card%s", card_value_texture_names[value])
			return Card{
				suit    = .None,
				value   = value,
				texture = card_textures[str],
				back_texture = back_texture,
			}
		}
		str := fmt.tprintf("card%s%s", card_suit_texture_names[suit], card_value_texture_names[value])
		return Card{
			suit    = suit,
			value   = value,
			texture = card_textures[str],
			back_texture = back_texture,
		}
	}

	red_back  := card_textures["cardBack_red4"]
	blue_back := card_textures["cardBack_blue4"]

	table.force_player_draw_idx = -1

	clear(&table.opponent_deck)
	clear(&table.player_deck)

	clear(&table.opponent_discard)
	clear(&table.player_discard)

	suit_backs := [2]rl.Texture2D{
		red_back,
		blue_back,
	}
	if difficulty == .Hard {
		suit_backs = {blue_back, red_back}
	}

	// Opponent Deck
	for suit in Card_Suit do if suit != .None {
		append(&table.opponent_deck, make_card(.Jack,  suit, suit_backs[0]))
		append(&table.opponent_deck, make_card(.Queen, suit, suit_backs[0]))
		append(&table.opponent_deck, make_card(.King,  suit, suit_backs[0]))

		if difficulty == .Hard {
			append(&table.opponent_deck, make_card(.Jack,  suit, suit_backs[1]))
			append(&table.opponent_deck, make_card(.Queen, suit, suit_backs[1]))
			append(&table.opponent_deck, make_card(.King,  suit, suit_backs[1]))
		}
	}

	// Player Deck
	for suit in Card_Suit do if suit != .None {
		for value in Card_Value.Ace ..= Card_Value.Ten {
			append(&table.player_deck, make_card(value, suit, suit_backs[0]))
		}
	}

	rand.shuffle(table.opponent_deck[:])
	rand.shuffle(table.player_deck[:])

	max_deck_size := 52
	switch difficulty {
	case .Easy:   max_deck_size = 24
	case .Medium: max_deck_size = 21
	case .Hard:   max_deck_size = 52
	}
	max_deck_size = min(max_deck_size, len(table.player_deck))
	resize(&table.player_deck, max_deck_size)

	// Add jokers
	joker := make_card(.Joker, .None, suit_backs[0])
	append(&table.player_deck, joker, joker)
	if difficulty == .Hard {
		append(&table.player_deck, joker, joker)
	}

	rand.shuffle(table.player_deck[:])


	// Fill stacks
	for i in 0..<STACK_COUNT {
		card := pop_safe(&table.opponent_deck) or_break
		table.opponent_cards[i] = make_table_card(card)
	}
	for i in 0..<STACK_COUNT {
		card := pop_safe(&table.player_deck) or_break
		table.player_cards[i] = make_table_card(card)
	}
}

CARD_WIDTH, CARD_HEIGHT :: 140, 190

the_game :: proc(table: ^Game_Table, render_texture: rl.RenderTexture2D) {
	@(require_results)
	alive_count :: proc(cards: [STACK_COUNT]Table_Card) -> (count: int) {
		for c in cards {
			if c.state != .Dead {
				count += 1
			}
		}
		return
	}



	center_overlay_text :: proc(gui: ^GUI_State, text: cstring) {
		FONT_SIZE :: i32(128)
		width := rl.MeasureText(text, FONT_SIZE)
		tx, ty := gui.width/2, gui.height/2
		tx -= width/2
		ty -= FONT_SIZE/2

		shadow_offset := max(FONT_SIZE/16, 4)
		rl.DrawText(text, tx+shadow_offset, ty+shadow_offset, FONT_SIZE, {0, 0, 0, 255})
		rl.DrawText(text, tx, ty, FONT_SIZE, {255, 236, 0, 255})
	}


	gui := &table.gui_state

	cw :: CARD_WIDTH*1.25
	ch :: CARD_HEIGHT*1.25


	PADDING :: CARD_WIDTH/2

	// Update states of opponent cards
	for &oc in table.opponent_cards {
		if oc.health <= 0 {
			if oc.state != .Dead {
				append(&table.opponent_discard, oc.card)
			}
			oc.state = .Dead
		}
	}

	if len(table.opponent_deck) != 0 { // Check opponent states
		all_dead := alive_count(table.opponent_cards) == 0
		if all_dead {
			for &oc in table.opponent_cards do if oc.state == .Dead {
				if card, ok := pop_safe(&table.opponent_deck); ok {
					oc = make_table_card(card)
				}
			}
		}
	}

	if len(table.player_deck) != 0 { // Check player states
		all_dead := alive_count(table.player_cards) == 0
		if all_dead || table.force_player_draw_idx >= 0 {
			// NOTE(bill): #reverse this to make it match the "peek" cards
			#reverse for &pc, i in table.player_cards do if pc.state == .Dead {
				if all_dead || i == table.force_player_draw_idx {
					if card, ok := pop_safe(&table.player_deck); ok {
						pc = make_table_card(card)
					}
				}
			}
		}
	}
	table.force_player_draw_idx = -1


	PEEK_AMOUNT :: 3

	CARD_SEPARATION :: 14
	for oc, i in table.opponent_deck {
		x := f32((cw+PADDING)*(STACK_COUNT/2) + render_texture.texture.width/2)
		y := f32(CARD_HEIGHT*2)
		x += f32(i) * CARD_SEPARATION

		offset := rl.Vector2{cw*0.5, ch*0.5}

		rot := f32(0)
		texture := oc.back_texture


		if i+PEEK_AMOUNT >= len(table.opponent_deck) {
			texture = oc.texture
			j := f32(len(table.opponent_deck)-i)
			k := min(f32(len(table.opponent_deck)), PEEK_AMOUNT)
			if k < PEEK_AMOUNT {
				k += 1
			}
			rot = (k-j) * 10

			offset.x = 0
			offset.y = ch
			x -= cw*0.5
			y += ch*0.5
		}


		rect := rl.Rectangle{x, y, cw, ch}

		rl.DrawTexturePro(
			texture,
			{0, 0, CARD_WIDTH, CARD_HEIGHT},
			rect,
			offset,
			rot,
			rl.WHITE,
		)
	}

	for pc, i in table.player_deck {
		x := f32((cw+PADDING)*(STACK_COUNT/2) + render_texture.texture.width/2)
		y := f32(render_texture.texture.height) - 1 - CARD_HEIGHT*1.25
		x += f32(i) * CARD_SEPARATION

		offset := rl.Vector2{cw*0.5, ch*0.5}

		rot := f32(0)
		texture := pc.back_texture

		if i+PEEK_AMOUNT >= len(table.player_deck) {
			texture = pc.texture
			j := f32(len(table.player_deck)-i)
			k := min(f32(len(table.player_deck)), PEEK_AMOUNT)
			if k < PEEK_AMOUNT {
				k += 1
			}
			rot = (k-j) * 10

			offset.x = 0
			offset.y = ch
			x -= cw*0.5
			y += ch*0.5
		}

		rect := rl.Rectangle{x, y, cw, ch}


		rl.DrawTexturePro(
			texture,
			{0, 0, CARD_WIDTH, CARD_HEIGHT},
			rect,
			offset,
			rot,
			rl.WHITE,
		)
	}

	for &oc, i in table.opponent_cards {
		WIDTH :: cw+PADDING

		x, y: f32
		y = CARD_HEIGHT*2
		x = WIDTH*(f32(i) - 0.5 - STACK_COUNT*0.5)
		x += f32(render_texture.texture.width)*0.5

		oc.rect = {x, y, cw, ch}

		bg_rect := oc.rect
		bg_rect.x -= 16
		bg_rect.y -= 16
		bg_rect.width += 32
		bg_rect.height += 32

		tint := rl.WHITE
		if oc.is_over && gui.active_id == 0 {
			oc.is_over = false
			oc.is_over_end_time = gui.current_time
		}

		if oc.is_over {
			// tint = {165, 190, 255, 255}
			oc.is_over_rotation = math.sin(8 * (gui.current_time - oc.is_over_start_time)) * 5
		} else {
			if abs(oc.is_over_rotation) < 1 {
				oc.is_over_rotation = 0
			} else {
				t := (gui.current_time - oc.is_over_end_time) * 0.3
				oc.is_over_rotation = math.lerp(oc.is_over_rotation, 0, t*0.8)
			}
		}

		rl.DrawTexturePro(
			oc.card.back_texture,
			{0, 0, CARD_WIDTH, CARD_HEIGHT},
			bg_rect,
			{cw*0.5, ch*0.5},
			0,
			{0, 0, 0, 70},
		)

		if oc.state == .Dead {
			continue
		}

		rl.DrawTexturePro(
			oc.card.texture,
			{0, 0, CARD_WIDTH, CARD_HEIGHT},
			oc.rect,
			{cw*0.5, ch*0.5},
			f32(oc.is_over_rotation),
			tint,
		)

		FONT_SIZE :: i32(64)

		text := rl.TextFormat("%d", oc.health)
		width := rl.MeasureText(text, FONT_SIZE)
		tx, ty := i32(x), i32(y)
		tx -= width/2
		ty -= FONT_SIZE + 32
		ty -= i32(math.round(f32(ch/2)))

		shadow_offset := i32(6)
		rl.DrawText(text, tx+shadow_offset, ty+shadow_offset, FONT_SIZE, {0, 0, 0, 255})
		rl.DrawText(text, tx, ty, FONT_SIZE, {255, 236, 0, 255})
	}

	rect_to_redraw: struct {
		texture:  rl.Texture2D,
		src, dst: rl.Rectangle,
		origin:   rl.Vector2,
		rotation: f32,
		tint:     rl.Color,
	}
	rect_to_redraw_idx: int = -1

	for &pc, pc_idx in table.player_cards {
		WIDTH :: cw+PADDING

		x, y: f32
		y = f32(render_texture.texture.height)-1 - CARD_HEIGHT*1.25
		x = WIDTH*(f32(pc_idx) - 0.5 - STACK_COUNT*0.5)
		x += f32(render_texture.texture.width)*0.5

		rect := rl.Rectangle{x, y, cw, ch}
		origin := rl.Vector2{cw*0.5, ch*0.5}

		bg_rect := rect
		bg_rect.x -= 16
		bg_rect.y -= 16
		bg_rect.width += 32
		bg_rect.height += 32


		if pc.state == .Dead {
			rl.DrawTexturePro(
				pc.card.back_texture,
				{0, 0, CARD_WIDTH, CARD_HEIGHT},
				bg_rect,
				origin,
				0,
				{0, 0, 0, 70},
			)

			continue
		}

		if pc.state == .Drag {
			rect.x = gui.mouse_pos.x - pc.position.x
			rect.y = gui.mouse_pos.y - pc.position.y
		}


		tint := rl.WHITE
		corrected_rect := rect
		corrected_rect.x -= origin.x
		corrected_rect.y -= origin.y

		id := Gui_Id(uintptr(&pc))
		res := update_control(gui, id, corrected_rect)

		switch id {
		case gui.active_id:
			tint = {255, 255, 205, 255}
		case gui.hover_id:
			tint = {255, 245, 165, 255}
		}

		if pc.state == .Drag {
			over_any: [STACK_COUNT]bool
			over_any_count := 0
			for oc, i in table.opponent_cards {
				if oc.state == .Dead {
					continue
				}
				if rl.CheckCollisionRecs(rect, oc.rect) {
					over_any[i] = true
					over_any_count += 1
				}
			}

			if over_any_count == 1 {
				for over, over_idx in over_any {
					oc := &table.opponent_cards[over_idx]
					if over {
						if id != gui.active_id {
							oc.health -= pc.health
							if oc.health <= 0 {
								table.force_player_draw_idx = pc_idx
							}
							pc.state = .Dead
							append(&table.player_discard, pc.card)
							break
						} else {
							if !oc.is_over {
								oc.is_over_start_time = gui.current_time
								oc.is_over_rotation = 0
							}
							oc.is_over = true

						}
					} else {
						if oc.is_over {
							oc.is_over_end_time = gui.current_time
						}
						oc.is_over = false
					}
				}
			} else {
				for &oc in table.opponent_cards {
					if oc.is_over {
						oc.is_over_end_time = gui.current_time
					}
					oc.is_over = false
				}
			}

			pc.drag_rotation = math.sin(8 * (gui.current_time - gui.active_in_time)) * 5

			rect_to_redraw = {
				pc.card.texture,
				{0, 0, CARD_WIDTH, CARD_HEIGHT},
				rect,
				origin,
				f32(pc.drag_rotation),
				tint,
			}
			rect_to_redraw_idx = pc_idx
		} else {
			if abs(pc.drag_rotation) < 1 {
				pc.drag_rotation = 0
			} else if pc.drag_end_time > gui.active_in_time {
				dt := gui.current_time - pc.drag_end_time
				pc.drag_rotation = math.lerp(pc.drag_rotation, 0, dt*0.8)
			}

		}


		if id == gui.active_id {
			pc.state = .Drag
			tint = {255, 200, 165, 255}
			if .Click in res {
				pc.position = gui.mouse_pos - {rect.x, rect.y}
			}
		} else if pc.state == .Drag {
			pc.drag_end_time = gui.current_time
			pc.state = .Alive
		} else {
			pc.position = {0, 0}
		}

		// Background
		rl.DrawTexturePro(
			pc.card.back_texture,
			{0, 0, CARD_WIDTH, CARD_HEIGHT},
			bg_rect,
			origin,
			0,
			{0, 0, 0, 70},
		)

		// Card on Background
		if rect_to_redraw_idx != pc_idx {
			rl.DrawTexturePro(
				pc.card.texture,
				{0, 0, CARD_WIDTH, CARD_HEIGHT},
				rect,
				origin,
				f32(pc.drag_rotation),
				tint,
			)
		}
	}


	win_state := false
	if len(table.opponent_deck) == 0 && alive_count(table.opponent_cards) == 0 {
		center_overlay_text(gui, "You Win!")
		win_state = true
	} else if len(table.player_deck) == 0 && alive_count(table.player_cards) == 0 {
		center_overlay_text(gui, "You Lose!")
	}


	for card, i in table.opponent_discard {
		rect := rl.Rectangle{0, 0, CARD_WIDTH, CARD_HEIGHT}

		rect.x = f32(gui.width)-1 - (rect.width/2 + 32)
		rect.y = (rect.height/2 + 32)

		rotation := 20*math.sin(f32(i))

		texture := card.texture
		if win_state {
			rotation = 20*math.sin(f32(i) + f32(gui.current_time))

			w0 := -0.2 * (math.mod(f32(i), 7)+1)
			w1 := -0.2 * (math.mod(f32(i*13), 7)+1)
			phase := math.TAU*f32(i) + 0.5

			phase += f32(i)

			if i%5 == 1 {
				texture = card.back_texture
			}

			w, h := f32(gui.width), f32(gui.height)

			rect.x = math.cos(w0*f32(gui.current_time) + phase)*0.4 * w + w*0.5
			rect.y = math.sin(w1*f32(gui.current_time) + phase)*0.4 * h + h*0.5
		}

		rl.DrawTexturePro(
			texture,
			{0, 0, CARD_WIDTH, CARD_HEIGHT},
			rect,
			{rect.width/2, rect.height/2},
			rotation,
			rl.WHITE,
		)
	}

	for card, i in table.player_discard {
		rect := rl.Rectangle{0, 0, CARD_WIDTH, CARD_HEIGHT}

		rect.x = rect.width/2 + 32
		rect.y = f32(gui.height)-1 - (rect.height/2 + 32)

		rotation := 20*math.sin(f32(i))

		texture := card.texture
		if win_state {
			rotation = 20*math.sin(f32(i) + f32(gui.current_time))

			w0 := 0.3 * (math.mod(f32(i), 7)+1)
			w1 := 0.3 * (math.mod(f32(i*13), 7)+1)

			phase := f32(i)

			if i%5 == 1 {
				texture = card.back_texture
			}

			w, h := f32(gui.width), f32(gui.height)

			rect.x = math.cos(w0*f32(gui.current_time) + phase)*0.4 * w + w*0.5
			rect.y = math.sin(w1*f32(gui.current_time) + phase)*0.4 * h + h*0.5
		}

		rl.DrawTexturePro(
			texture,
			{0, 0, CARD_WIDTH, CARD_HEIGHT},
			rect,
			{rect.width/2, rect.height/2},
			rotation,
			rl.WHITE,
		)
	}

	@(require_results)
	new_game_button :: proc(gui: ^GUI_State, text: cstring, row: i32) -> Control_Result_Set {
		FONT_SIZE :: 24
		width := f32(rl.MeasureText(text, FONT_SIZE))

		id := Gui_Id(hash.fnv64a(transmute([]byte)string(text)))

		tx := i32(64)
		// ty := gui.height-1 - (i32(64) + FONT_SIZE)*(row+1) - 16*(row-1)
		ty := (i32(64) + FONT_SIZE)*(row+1) + 16*(row-1)

		rect := rl.Rectangle{f32(tx)-32, f32(ty)-32, width+64, FONT_SIZE+64}
		tint := rl.Color{185, 255, 165, 255}
		res := update_control(gui, id, rect)


		if gui.hover_id == id {
			tint = {195, 215, 125, 255}
		}
		if gui.active_id == id {
			tint = {105, 150, 100, 255}
		}

		bg_rect := rect
		bg_rect.x += 4
		bg_rect.y += 4
		rl.DrawRectangleRounded(bg_rect, 0.25, 8, {0, 0, 0, 255})
		rl.DrawRectangleRounded(rect, 0.25, 8, tint)
		rl.DrawText(text, tx, ty, FONT_SIZE, {0, 0, 0, 255})

		return res
	}
	if .Click in new_game_button(gui, "New Easy Mode", 0) {
		init_table(table, .Easy)
	}
	if .Click in new_game_button(gui, "New Medium Mode", 1) {
		init_table(table, .Medium)
	}
	if .Click in new_game_button(gui, "New Hard Mode", 2) {
		init_table(table, .Hard)
	}



	if rect_to_redraw.texture.id != 0 {
		dup := rect_to_redraw
		dup.dst.x += 12
		dup.dst.y += 12
		dup.tint = {0, 0, 0, 80}

		rl.DrawTexturePro(expand_values(dup))
		rl.DrawTexturePro(expand_values(rect_to_redraw))
	}

}


main :: proc() {
	rl.SetTraceLogLevel(.ERROR)
	rl.SetConfigFlags({.MSAA_4X_HINT, .VSYNC_HINT, .WINDOW_RESIZABLE})
	rl.InitWindow(1280, 720, "Face the Court - Card Game")
	defer rl.CloseWindow()

	card_textures_data := #load_directory("../res/image/")
	for ctd in card_textures_data {
		name, data := ctd.name, ctd.data
		index := strings.last_index_any(name, `/\`)
		path := filepath.stem(name[index+1:])
		image := rl.LoadImageFromMemory(".png", raw_data(data), i32(len(data)))
		card_textures[path] = rl.LoadTextureFromImage(image)
		rl.UnloadImage(image)
	}
	defer delete(card_textures)

	seed := u64(time.time_to_unix(time.now()))
	r := rand.create(seed)
	context.random_generator = rand.default_random_generator(&r)

	table: Game_Table
	init_table(&table, .Easy)

	render_texture := rl.LoadRenderTexture(1920, 1080)
	defer rl.UnloadRenderTexture(render_texture)

	rl.SetTargetFPS(144)
	for !rl.WindowShouldClose() {
		free_all(context.temp_allocator)

		rl.BeginTextureMode(render_texture)
		rl.ClearBackground({0, 0, 0, 0})

		gui := &table.gui_state
		gui_start(gui, render_texture.texture.width, render_texture.texture.height)
		the_game(&table, render_texture)
		gui_end(gui)

		rl.EndTextureMode()

		rl.BeginDrawing()
		rl.ClearBackground({25, 125, 45, 255})

		{
			w := f32(render_texture.texture.width)
			h := f32(render_texture.texture.height)
			source := rl.Rectangle{0, 0, w, h}
			dst := source

			sw := f32(rl.GetScreenWidth())
			sh := f32(rl.GetScreenHeight())
			scale := min(sw/w, sh/h)
			dst.width  = scale * f32(dst.width)
			dst.height = scale * f32(dst.height)

			dst.x = (sw - dst.width)  * 0.5
			dst.y = (sh - dst.height) * 0.5


			source.height = -source.height
			rl.DrawTexturePro(
				texture  = render_texture.texture,
				source   = source,
				dest     = dst,
				origin   = {0, 0},
				rotation = 0,
				tint     = rl.WHITE,
			)
		}

		rl.DrawFPS(2, 2)
		rl.EndDrawing()
	}
}