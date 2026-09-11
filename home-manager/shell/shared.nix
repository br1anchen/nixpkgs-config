{
  # Aliases absent from Omarchy's Bash layer and useful on both platforms.
  aliases = {
    cat = "bat";
    find = "fd";
    grep = "grep --color=auto";
    md = "mdcat";

    dc = "docker-compose";
    dk = "docker";

    vimdiff = "nvim -d";
    vf = "nvim";
    vd = "nvim .";

    lg = "lazygit";

    hdr = "herdr";
    herdr-reload = "herdr server reload-config";
    gsh = "ghostty-shell";

    garbage = "nix-collect-garbage -d && nix-temp-gc && { command -v docker >/dev/null && docker image prune --force || true; }";
    installed = "nix-env --query --installed";
    imise = "mise install";
    dots = "dotfiles-sync";

    # Aikido Safe Chain wraps the package managers it supports.
    npm = "aikido-npm";
    npx = "aikido-npx";
    yarn = "aikido-yarn";
    pnpm = "aikido-pnpm";
    pnpx = "aikido-pnpx";
    bun = "aikido-bun";
    bunx = "aikido-bunx";
    pip = "aikido-pip";
    pip3 = "aikido-pip3";
    uv = "aikido-uv";
    uvx = "aikido-uvx";
    poetry = "aikido-poetry";
    pipx = "aikido-pipx";
  };

  # POSIX-compatible environment shared by zsh and Bash.
  environment = ''
    # Rust Cargo
    export PATH="$HOME/.cargo/bin:$PATH"

    # Bob-managed Neovim. config/bob/config.json sets installation_location to
    # ~/.local/share/bob/nvim-bin; `used` supports the older layout.
    if [ -d "$HOME/.local/share/bob/nvim-bin" ]; then
      export PATH="$HOME/.local/share/bob/nvim-bin:$PATH"
    elif [ -f "$HOME/.local/share/bob/used" ]; then
      export PATH="$HOME/.local/share/bob/$(cat "$HOME/.local/share/bob/used")/bin:$PATH"
    fi

    # Dart / Go / Swift
    export PATH="$PATH:$HOME/.pub-cache/bin"
    export GOPATH="$HOME/go"
    export PATH="$GOPATH/bin:$PATH"
    export PATH="$HOME/.mint/bin:$PATH"

    # mason.nvim installs
    export PATH="$HOME/.local/share/nvim/mason/bin:$PATH"

    # PNPM / BUN / Maestro
    export PNPM_HOME="$HOME/.local/share/pnpm"
    export PATH="$PNPM_HOME:$PATH"
    export BUN_HOME="$HOME/.bun"
    export PATH="$BUN_HOME/bin:$PATH"
    export PATH="$PATH:$HOME/.maestro/bin"

    # Local bin
    export PATH="$HOME/.local/bin:$PATH"
  '';
}
