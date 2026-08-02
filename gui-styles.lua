local gui_style = data.raw["gui-style"]["default"]

-- subheader_frame is 36px tall, which clips the 40px signal button, so the
-- height is re-derived from the button rather than inherited.
gui_style.cybersyn_content_reader_network_selector_frame = {
	type = "frame_style",
	parent = "subheader_frame",
	horizontally_stretchable = "on",
	height = 48,
	left_padding = 12,
	right_padding = 12,
	top_padding = 4,
	bottom_padding = 4,
	vertical_align = "center",
	horizontal_flow_style = {
		type = "horizontal_flow_style",
		horizontal_spacing = 12,
		vertical_align = "center",
	},
}


gui_style.cybersyn_content_reader_network_selector = {
  type = "textbox_style",
  width = 30,
  height = 28
}

gui_style.cybersyn_content_reader_label_signal_count_inventory = {
	type = "label_style",
	parent = "count_label",
	size = 36,
	width = 36,
	horizontal_align = "right",
	vertical_align = "bottom",
	right_padding = 2,
	parent_hovered_font_color = { 1, 1, 1 },
}