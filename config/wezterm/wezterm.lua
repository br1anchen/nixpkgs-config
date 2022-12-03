local wezterm = require("wezterm")
local mux = wezterm.mux

wezterm.on("gui-startup", function(cmd)
	local tab, pane, window = mux.spawn_window(cmd or {})
	window:gui_window():maximize()
end)

return {
	color_scheme = "Catppuccin Mocha",
	font = wezterm.font("Monocraft Nerd Font"),
	window_decorations = "RESIZE",
}
