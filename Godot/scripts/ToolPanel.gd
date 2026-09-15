#Author: Vladimír Horák
#Desc:
#Script controlling ToolPanel - contains tabs with player data and setting for different elements
#contains character_tree button functions - TODO move to separate script applied on "Characters" Margin container

extends Control

var button_visible: Texture2D = preload("res://icons/GuiVisibilityVisible.svg")
var button_hidden: Texture2D = preload("res://icons/GuiVisibilityHidden.svg")

var char_sheet = preload("res://UI/character_sheet.tscn")

var dialog_item

@onready var tree = $TabContainer/Characters/Tree

# Called when the node enters the scene tree for the first time.
func _ready():
	if not Globals.lobby.check_is_server():
		self.visible = false
	

func _on_tree_item_activated():
	print("[ToolPanel] item activated")
	var selected = tree.get_selected()
	if selected == null:
		print("[ToolPanel] BAIL: no item selected")
		return
	print("[ToolPanel] selected item: ", selected.get_text(0))
	print("[ToolPanel] has character meta: ", selected.has_meta("character"))
	var ch_sh = char_sheet.instantiate()
	ch_sh.token_sheet = false
	ch_sh.character = selected.get_meta("character") if selected.has_meta("character") else null
	if ch_sh.character == null:
		print("[ToolPanel] BAIL: character is null on selected item")
		return
	print("[ToolPanel] character ok: ", ch_sh.character.name)
	print("[ToolPanel] Globals.windows = ", Globals.windows)
	if Globals.windows == null:
		push_error("[ToolPanel] BAIL: Globals.windows is null — map scene not ready")
		return
	Globals.windows.add_child(ch_sh)
	print("[ToolPanel] character sheet opened")


func _on_tree_item_selected():
	#Globals.draw_layer = tree.get_selected().get_meta("draw_layer")
	pass


func _on_tree_button_clicked(item, column, id, mouse_button_index):
	if id == 0:#edit
		tree.set_selected(item, 0)
		tree.edit_selected(true)
	if id == 1:#add new
		if item == tree.get_root(): #first character
			tree.add_new_item("Character", item)
		else:
			tree.add_new_item(item.get_text(0) + "_copy", item)
	if id == 2:#remove
		dialog_item = item
		$ConfirmationDialog.popup()

#change meta data of layer for reload with edited name
func _on_tree_item_edited():
	tree.rename_character(tree.get_edited(), tree.get_edited().get_text(0))

func _on_confirmation_dialog_confirmed():
	custom_remove_item(dialog_item)
	
func custom_remove_item(item: TreeItem):
	item.get_meta("character").delete()
	
	item.free()
	
	if tree.get_root().get_first_child() == null:
		tree.hide_root = false
		
