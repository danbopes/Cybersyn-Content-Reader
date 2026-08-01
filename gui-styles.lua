local gui_style = data.raw["gui-style"]["default"]

gui_style.cybersyn_content_reader_network_selector_frame = {
	type = "frame_style",
	parent = "subheader_frame",
	top_margin = 4,
	bottom_margin = 12,
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