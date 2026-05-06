-- HTTP connectivity test
-- Run with: lua http_test.lua

local TEST_URL = "https://httpbin.org/get"

print("=== HTTP Test ===")
print()

-- 1. Check if HTTP is enabled and URL is allowed
io.write("Checking URL... ")
local ok, reason = http.checkURL(TEST_URL)
if not ok then
    print("BLOCKED")
    print("Reason: " .. tostring(reason))
    print()
    print("HTTP is disabled or this URL is not on the whitelist.")
    print("Ask your server admin to enable HTTP in CC:Tweaked config.")
    return
end
print("OK (allowed)")

-- 2. Try a real GET request
io.write("Making GET request... ")
local res = http.get(TEST_URL)
if not res then
    print("FAILED (nil response)")
    print("HTTP is allowed but the request failed. Check internet connectivity.")
    return
end
local body = res.readAll()
local code = res.getResponseCode()
res.close()
print(("OK (HTTP %d, %d bytes)"):format(code, #body))

-- 3. Try GitHub raw (what the player actually uses)
io.write("Reaching GitHub raw... ")
local ghRes = http.get("https://raw.githubusercontent.com/ob-105/CC-tweaked-Audio-video-playback./main/player.lua")
if not ghRes then
    print("FAILED")
    print("General HTTP works but GitHub is unreachable.")
else
    local ghBody = ghRes.readAll()
    ghRes.close()
    print(("OK (%d bytes)"):format(#ghBody))
end

print()
print("All tests passed! HTTP is working.")
