{ ... }:

# Local mise plugins kept in this repo, for tools with no mise registry entry
# or backend that fits. mise reads plugins from ~/.local/share/mise/plugins/<name>
# on both platforms; each is a vfox (Lua) plugin, read-only once installed, so
# the store symlink is safe (Omarchy never touches mise's plugin dir). The
# tools themselves are pinned in config/mise/config.toml.
{
  xdg.dataFile."mise/plugins/prime-agent".source = ../config/mise/plugins/vfox-prime-agent;
}
