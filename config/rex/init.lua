-- Shared Rex config for macOS and Omarchy.
--
-- Mirrors config/herdr/config.toml (itself a tmux mirror), so the same keys
-- work in Rex, herdr and tmux. Prefix is herdr's ctrl+a, written as a key
-- sequence: "ctrl+a>c" is prefix then c.
-- tmux session -> rex session, tmux window -> rex tab, tmux pane -> rex pane
--
-- The server reads this file, so a remote host (blade) uses its own copy.
-- After a change: `rex config check`, then `rex config reload` on that host.
--
-- No equivalent in Rex, so not mirrored: detach, copy mode, last pane,
-- rename pane and agent navigation.

local P = "ctrl+a>"

-- Press the prefix twice to send it to the terminal
rex.bind(P .. "ctrl+a", "pane.send_key", { key = "ctrl+a" })

-- Config and help
rex.bind(P .. "r", "client.config.reload")
rex.bind(P .. "shift+/", "client.palette.toggle")

-- Panes. herdr's split_horizontal stacks panes (tmux split-window -v).
for _, key in ipairs({ P .. "h", "alt+enter" }) do
  rex.bind(key, "pane.split.down")
end
for _, key in ipairs({ P .. "v", "alt+shift+enter" }) do
  rex.bind(key, "pane.split.right")
end
rex.bind(P .. "x", "pane.close")
rex.bind(P .. "z", "pane.zoom")

local arrows = { left = "h", down = "j", up = "k", right = "l" }
for dir, vim in pairs(arrows) do
  rex.bind("ctrl+alt+" .. dir, "pane.focus." .. dir)
  rex.bind("ctrl+alt+shift+" .. dir, "pane.resize", { direction = dir })
  rex.bind(P .. "shift+" .. vim, "pane.move." .. dir)
end

-- vim-tmux-navigator style: ctrl+hjkl goes to (n)vim when it is in front,
-- and smart-splits' at_edge runs `rex focus` at its last split
local terminal = "com.superlogical.terminal"
for dir, vim in pairs(arrows) do
  rex.bind("ctrl+" .. vim, function(ctx)
    local p = rex.block.call(terminal, "process", { block_id = ctx.block_id })
    local fg = p and p.foreground and p.foreground.name or ""
    if fg:match("^n?vim$") then
      return false
    end
    rex.session.focus_direction({ session_id = ctx.session_id, direction = dir })
    return true
  end)
end

-- Like herdr's resize_mode: arrows resize until escape or enter
rex.mode("resize", { exclusive = true })
rex.bind(P .. "ctrl+r", "client.mode.enter", { name = "resize" })
for dir, vim in pairs(arrows) do
  rex.bind("resize/" .. dir, "pane.resize", { direction = dir })
  rex.bind("resize/" .. vim, "pane.resize", { direction = dir })
end
rex.bind("resize/=", "pane.balance")
rex.bind("resize/enter", "client.mode.exit")

-- Windows -> tabs
rex.bind(P .. "c", "client.tab.new")
rex.bind(P .. ",", "client.tab.rename")
rex.bind(P .. "k", "client.tab.close")
for i = 1, 9 do
  rex.bind(P .. i, "client.tab.goto", { index = i })
  rex.bind("alt+" .. i, "client.tab.goto", { index = i })
end
for _, key in ipairs({ P .. "p", "alt+left" }) do
  rex.bind(key, "client.tab.previous")
end
for _, key in ipairs({ P .. "n", "alt+right" }) do
  rex.bind(key, "client.tab.next")
end
rex.bind("alt+shift+left", "client.tab.move.backward")
rex.bind("alt+shift+right", "client.tab.move.forward")

-- Sessions -> sessions
rex.bind(P .. "shift+c", "session.new")
rex.bind(P .. "shift+r", "session.rename")
rex.bind(P .. "q", "session.close")
for _, key in ipairs({ P .. "shift+p", "alt+up" }) do
  rex.bind(key, "session.previous")
end
for _, key in ipairs({ P .. "shift+n", "alt+down" }) do
  rex.bind(key, "session.next")
end

-- pstack actions (kitchen/pair/trio/fleet/sync) from the checkout
-- home-manager/pstack.nix links at ~/.local/share/pstack. Skipped when absent.
local pstack = (os.getenv("HOME") or "") .. "/.local/share/pstack"
local f = io.open(pstack .. "/plugins/rex/pstack.lua")
if f then
  f:close()
  dofile(pstack .. "/plugins/rex/pstack.lua")(pstack)
end
