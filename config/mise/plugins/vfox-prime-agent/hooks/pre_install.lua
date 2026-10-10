local http = require("http")

local platforms = {
    linux = { amd64 = "linux-x64", arm64 = "linux-arm64" },
    darwin = { amd64 = "darwin-x64", arm64 = "darwin-arm64" },
}

-- The release tarball for this host, checked against the release's SHA256SUMS.
function PLUGIN:PreInstall(ctx)
    local version = ctx.version
    local platform = (platforms[RUNTIME.osType] or {})[RUNTIME.archType]
    if platform == nil then
        error("prime-agent has no release for " .. RUNTIME.osType .. "/" .. RUNTIME.archType)
    end
    local base = "https://github.com/PrimeIntellect-ai/prime-agent/releases/download/v" .. version .. "/"
    local file = "prime-agent-" .. version .. "-" .. platform .. ".tar.gz"
    local resp, err = http.get({ url = base .. "SHA256SUMS" })
    if err ~= nil or resp.status_code ~= 200 then
        error("fetching SHA256SUMS for prime-agent " .. version .. " failed: " .. (err or ("HTTP " .. resp.status_code)))
    end
    local sha
    for line in resp.body:gmatch("[^\n]+") do
        local sum, name = line:match("^(%x+)%s+%*?(%S+)$")
        if name == file then
            sha = sum
        end
    end
    if sha == nil then
        error(file .. " is not listed in the release's SHA256SUMS")
    end
    return { version = version, url = base .. file, sha256 = sha }
end
