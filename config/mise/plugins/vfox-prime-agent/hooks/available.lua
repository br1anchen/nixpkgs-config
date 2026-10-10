local http = require("http")
local json = require("json")

local function headers()
    local token = os.getenv("GITHUB_TOKEN") or os.getenv("GH_TOKEN")
    local h = { ["Accept"] = "application/vnd.github+json" }
    if token and token ~= "" then
        h["Authorization"] = "Bearer " .. token
    end
    return h
end

-- Stable releases only: the beta channel ships several pre-releases a day.
function PLUGIN:Available(ctx)
    local resp, err = http.get({
        url = "https://api.github.com/repos/PrimeIntellect-ai/prime-agent/releases?per_page=100",
        headers = headers(),
    })
    if err ~= nil or resp.status_code ~= 200 then
        error("listing prime-agent releases failed: " .. (err or ("HTTP " .. resp.status_code)))
    end
    local out = {}
    for _, r in ipairs(json.decode(resp.body)) do
        if not r.prerelease and not r.draft then
            table.insert(out, { version = (r.tag_name:gsub("^v", "")) })
        end
    end
    return out
end
