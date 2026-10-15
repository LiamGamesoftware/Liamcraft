@tool
extends TextEdit

# Public TextEdit virtual covers shortcuts and the native context-menu Paste.
# Returning false leaves ordinary text paste available regardless of vision support.
var image_paste_handler: Callable


func _paste(caret_index: int) -> void:
	if not editable:
		return
	if image_paste_handler.is_valid() and image_paste_handler.call():
		return
	var clipboard := _clipboard_text()
	if not clipboard.is_empty():
		begin_complex_operation()
		insert_text_at_caret(clipboard.replace("\r\n", "\n").replace("\r", ""), caret_index)
		end_complex_operation()


func _clipboard_text() -> String:
	return DisplayServer.clipboard_get()
