-- CC:Tweaked Media Player
-- Plays DFPWM audio through a speaker and renders NFP video frames on a monitor array.
-- Auto-updates itself from GitHub on launch.
--
-- Setup:
--   1. Place a speaker next to/adjacent to the computer
--   2. Place monitors in a grid and connect them (or use a single monitor)
--   3. Run this script: lua player.lua

local GITHUB_RAW = "https://raw.githubusercontent.com/ob-105/CC-tweaked-Audio-video-playback./main"
local SELF_URL   = GITHUB_RAW .. "/player.lua"
local SELF_PATH  = "player.lua"
local VERSION    = "3"  -- increment this to trigger an update

-- ---------------------------------------------------------------------------
-- Self-update (uses version number to avoid CRLF comparison issues)
-- ---------------------------------------------------------------------------
local function selfUpdate()
    print("[player] Checking for updates...")
    local ok, newData = pcall(function()
        local result = http.get(SELF_URL)
        if not result then error("HTTP request failed") end
        local data = result.readAll()
        result.close()
        return data
    end)
    if not ok or not newData then
        print("[player] Could not reach GitHub, running local copy.")
        return
    end
    -- Extract version from downloaded file
    local remoteVer = newData:match('local VERSION%s*=%s*"(%d+)"')
    if not remoteVer then
        print("[player] Could not read remote version, skipping update.")
        return
    end
    if remoteVer == VERSION then
        print("[player] Already up to date (v" .. VERSION .. ").")
        return
    end
    -- Write new version and reboot
    local f = fs.open(SELF_PATH, "w")
    f.write(newData)
    f.close()
    print("[player] Updated to v" .. remoteVer .. "! Rebooting...")
    os.sleep(0.5)
    os.reboot()
end

-- ---------------------------------------------------------------------------
-- Download helper
-- ---------------------------------------------------------------------------
local function download(url, path)
    if fs.exists(path) then return true end
    local dir = path:match("^(.*)/[^/]+$")
    if dir and dir ~= "" and not fs.exists(dir) then
        fs.makeDir(dir)
    end
    local res = http.get(url, nil, true)
    if not res then return false, "HTTP failed: " .. url end
    local data = res.readAll()
    res.close()
    local f = fs.open(path, "wb")
    f.write(data)
    f.close()
    return true
end

-- ---------------------------------------------------------------------------
-- Load index from GitHub
-- ---------------------------------------------------------------------------
local function loadIndex()
    local url  = GITHUB_RAW .. "/output/index.lua"
    local path = "media/index.lua"
    if fs.exists(path) then fs.delete(path) end
    local res = http.get(url)
    if res then
        local data = res.readAll()
        res.close()
        if not fs.exists("media") then fs.makeDir("media") end
        local f = fs.open(path, "w")
        f.write(data)
        f.close()
    end
    if not fs.exists(path) then return { video = {}, audio = {} } end
    local fn = loadfile(path)
    if not fn then return { video = {}, audio = {} } end
    local ok, result = pcall(fn)
    if not ok or type(result) ~= "table" then return { video = {}, audio = {} } end
    result.video = result.video or {}
    result.audio = result.audio or {}
    return result
end

-- ---------------------------------------------------------------------------
-- Load manifest
-- ---------------------------------------------------------------------------
local function loadManifest(mediaName)
    local url  = GITHUB_RAW .. "/output/" .. mediaName .. "/manifest.lua"
    local path = "media/" .. mediaName .. "/manifest.lua"
    if fs.exists(path) then fs.delete(path) end
    local ok, err = download(url, path)
    if not ok then error("Could not download manifest: " .. tostring(err)) end
    local fn = loadfile(path)
    if not fn then error("Could not parse manifest") end
    return fn()
end

-- ---------------------------------------------------------------------------
-- Monitor setup
-- ---------------------------------------------------------------------------
local function setupMonitor()
    local mon = peripheral.find("monitor")
    if not mon then return nil end
    mon.setTextScale(0.5)
    local mw, mh = mon.getSize()
    print(string.format("[player] Monitor: %dx%d chars", mw, mh))
    return mon
end

-- ---------------------------------------------------------------------------
-- NFP renderer
-- ---------------------------------------------------------------------------
local BLIT = "0123456789abcdef"

local function renderNFP(mon, nfpText)
    if not mon then return end
    local mw, mh = mon.getSize()
    local row = 1
    for line in (nfpText .. "\n"):gmatch("([^\n]*)\n") do
        if row > mh then break end
        local col = 1
        local i = 1
        while i <= #line and col <= mw do
            local c  = line:sub(i, i)
            local ci = BLIT:find(c, 1, true)
            if ci then
                ci = ci - 1
                local bc = BLIT:sub(ci + 1, ci + 1)
                mon.setCursorPos(col, row)
                mon.blit(" ", bc, bc)
            end
            col = col + 1
            i   = i + 1
        end
        row = row + 1
    end
end

-- ---------------------------------------------------------------------------
-- DFPWM audio streaming
-- ---------------------------------------------------------------------------
local function playAudio(speaker, mediaName)
    local CHUNK_SIZE = 16 * 1024
    local url = GITHUB_RAW .. "/output/" .. mediaName .. "/audio.dfpwm"
    print("[player] Streaming audio...")
    local res = http.get(url, nil, true)
    if not res then
        print("[player] Could not fetch audio.")
        return
    end
    local dfpwm   = require("cc.audio.dfpwm")
    local decoder = dfpwm.make_decoder()
    while true do
        local chunk = res.read(CHUNK_SIZE)
        if not chunk then break end
        local pcm = decoder(chunk)
        while not speaker.playAudio(pcm) do
            os.pullEvent("speaker_audio_empty")
        end
    end
    res.close()
end

-- ---------------------------------------------------------------------------
-- Video + audio playback
-- ---------------------------------------------------------------------------
local function playMedia(mon, speaker, mediaName, manifest)
    local fps        = manifest.fps or 5
    local frameCount = manifest.frame_count or 0
    local hasAudio   = manifest.has_audio == "true"
    local hasVideo   = manifest.has_video == "true" and mon ~= nil

    print(string.format("[player] Playing '%s'", mediaName))

    local PREFETCH = math.min(10, frameCount)
    if hasVideo and frameCount > 0 then
        print(string.format("[player] Pre-fetching %d frames...", PREFETCH))
        for i = 1, PREFETCH do
            local fname = string.format("%06d.nfp", i)
            download(GITHUB_RAW .. "/output/" .. mediaName .. "/frames/" .. fname,
                     "media/" .. mediaName .. "/frames/" .. fname)
        end
    end

    local startTime = os.clock()
    local frame = 1

    local function videoRoutine()
        while frame <= frameCount do
            local wait = (frame - 1) / fps - (os.clock() - startTime)
            if wait > 0 then os.sleep(wait) end
            local fname = string.format("%06d.nfp", frame)
            local fpath = "media/" .. mediaName .. "/frames/" .. fname
            if not fs.exists(fpath) then
                download(GITHUB_RAW .. "/output/" .. mediaName .. "/frames/" .. fname, fpath)
            end
            if fs.exists(fpath) and hasVideo then
                local f = fs.open(fpath, "r")
                local nfpText = f.readAll()
                f.close()
                renderNFP(mon, nfpText)
            end
            local next = frame + PREFETCH
            if next <= frameCount then
                local nfp = "media/" .. mediaName .. "/frames/" .. string.format("%06d.nfp", next)
                if not fs.exists(nfp) then
                    download(GITHUB_RAW .. "/output/" .. mediaName .. "/frames/" .. string.format("%06d.nfp", next), nfp)
                end
            end
            frame = frame + 1
        end
    end

    local function audioRoutine()
        if hasAudio and speaker then playAudio(speaker, mediaName) end
    end

    if hasAudio and hasVideo and frameCount > 0 then
        parallel.waitForAll(audioRoutine, videoRoutine)
    elseif hasAudio then
        audioRoutine()
    elseif frameCount > 0 then
        videoRoutine()
    end

    print("\n[player] Playback complete.")
    print("Press Enter to return to menu...")
    io.read()
end

-- ---------------------------------------------------------------------------
-- Menus
-- ---------------------------------------------------------------------------
local function drawMenu(title, items)
    term.clear()
    term.setCursorPos(1, 1)
    print("=================================")
    print("  CC:T Media Player  |  " .. title)
    print("=================================")
    if #items == 0 then
        print("  (none available)")
    else
        for i, name in ipairs(items) do
            print(string.format("  %d. %s", i, name))
        end
    end
    print("---------------------------------")
    print("  0. Back")
    print()
    io.write("Select: ")
    local input = io.read()
    local n = tonumber(input)
    if not n or n == 0 then return nil end
    return items[n]
end

local function mainMenu(index)
    while true do
        term.clear()
        term.setCursorPos(1, 1)
        print("=================================")
        print("  CC:T Media Player")
        print("=================================")
        print(string.format("  1. Videos  (%d available)", #index.video))
        print(string.format("  2. Audio   (%d available)", #index.audio))
        print("---------------------------------")
        print("  R. Refresh library")
        print("  Q. Quit")
        print()
        io.write("Choice: ")
        local input = io.read()
        if not input then return "quit", nil end
        input = input:lower()
        if input == "1" then
            if #index.video == 0 then print("No videos yet.") ; os.sleep(1)
            else local p = drawMenu("Videos", index.video) ; if p then return "play", p end end
        elseif input == "2" then
            if #index.audio == 0 then print("No audio yet.") ; os.sleep(1)
            else local p = drawMenu("Audio", index.audio) ; if p then return "play", p end end
        elseif input == "r" then return "refresh", nil
        elseif input == "q" then return "quit", nil
        end
    end
end

-- ---------------------------------------------------------------------------
-- Main
-- ---------------------------------------------------------------------------
local function main()
    term.clear()
    term.setCursorPos(1, 1)
    print("=== CC:Tweaked Media Player ===")
    print()
    selfUpdate()
    local speaker = peripheral.find("speaker")
    if not speaker then print("[warn] No speaker found.") end
    local mon   = setupMonitor()
    local index = loadIndex()
    while true do
        local action, pick = mainMenu(index)
        if action == "quit" then
            term.clear() ; term.setCursorPos(1,1) ; print("Goodbye!") ; return
        elseif action == "refresh" then
            print("[player] Refreshing...") ; index = loadIndex() ; print("Done.") ; os.sleep(0.5)
        elseif action == "play" and pick then
            local ok, manifest = pcall(loadManifest, pick)
            if not ok then
                print("[error] " .. tostring(manifest))
                print("Press Enter...") ; io.read()
            else
                playMedia(mon, speaker, pick, manifest)
            end
        end
    end
end

main()
