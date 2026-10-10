-- The tarball holds the prime-agent binary at its root, beside the payload
-- (runtime, skills, bundled models) it reads relative to itself.
function PLUGIN:EnvKeys(ctx)
    return { { key = "PATH", value = ctx.path } }
end
