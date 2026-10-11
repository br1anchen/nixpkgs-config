{ upstream }:
upstream.overrideAttrs (old: {
  patches = (old.patches or [ ]) ++ [
    (builtins.path {
      path = ./prime-agent.patch;
      name = "herdr-prime-agent.patch";
    })
  ];
})
