-- CC:Tweaked Media Player
-- Plays DFPWM audio through a speaker and renders NFP video frames on a monitor array.
-- Auto-updates itself from GitHub on launch.
--
-- Setup:
--   1. Place a speaker next to/adjacent to the computer
--   2. Place monitors in a grid and connect them (or use a single monitor)
--   3. Run this script: lua player.lua
--
-- GitHub raw base URL
local GITHUB_RAW = "https://raw.githubusercontent.com/ob-105/CC-tweaked-Audio-video-playback./main"
local SELF_URL   = GITHUB_RAW .. "/player.lua"
local SELF_PATH  = "player.lua"

-- ---------------------------------------------------------------------------
-- Self-update
-- ---------------------------------------------------------------------------
local function selfUpdate()
    print("[player] Checking for updates...")
    local tmpPath = "player.lua.tmp"
    local ok = pcall(function()
        if fs.exists(tmpPath) then fs.delete(tmpPath) end
        local result = http.get(SELF_URL)
        if not result then error("HTTP request failed") end
        local data = result.readAll()
        result.close()
        local f = fs.open(tmpPath, "w")
        f.write(data)
        f.close()
    end)
    if ok and fs.exists(tmpPath) then
        fs.delete(SELF_PATH)
        fs.move(tmpPath, SELF_PATH)
        print("[player] Updated! Rebooting...")
        os.sleep(0.5)
        os.reboot()
    else
        print("[player] Could not reach GitHub, running local copy.")
    end
end

-- ---------------------------------------------------------------------------
-- Download helper
-- ---------------------------------------------------------------------------
local function download(url, path)
    if fs.exists(path) then return true end
    -- Create directories
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

    -- Always fetch fresh copy
    if fs.exists(path) then fs.delete(path) end
    local res = http.get(url)
    if res then
        local data = res.readAll()
        res.close()
        local dir = "media"
        if not fs.exists(dir) then fs.makeDir(dir) end
        local f = fs.open(path, "w")
        f.write(data)
        f.close()
    end

    if not fs.exists(path) then
        return { video = {}, audio = {} }
    end
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

    local dfpwm    = require("cc.audio.dfpwm")
    local decoder  = dfpwm.make_decoder()

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
            local furl  = GITHUB_RAW .. "/output/" .. mediaName .. "/frames/" .. fname
            local fpath = "media/" .. mediaName .. "/frames/" .. fname
            download(furl, fpath)
        end
    end

    local startTime = os.clock()
    local frame = 1

    local function videoRoutine()
        while frame <= frameCount do
            local targetTime = (frame - 1) / fps
            local elapsed    = os.clock() - startTime
            local wait       = targetTime - elapsed
            if wait > 0 then os.sleep(wait) end

            local fname = string.format("%06d.nfp", frame)
            local fpath = "media/" .. mediaName .. "/frames/" .. fname

            if not fs.exists(fpath) then
                local furl = GITHUB_RAW .. "/output/" .. mediaName .. "/frames/" .. fname
                download(furl, fpath)
            end

            if fs.exists(fpath) and hasVideo then
                local f = fs.open(fpath, "r")
                local nfpText = f.readAll()
                f.close()
                renderNFP(mon, nfpText)
            end

            -- Prefetch ahead
            local next = frame + PREFETCH
            if next <= frameCount then
                local nf   = string.format("%06d.nfp", next)
                local nfp  = "media/" .. mediaName .. "/frames/" .. nf
                if not fs.exists(nfp) then
                    local nfurl = GITHUB_RAW .. "/output/" .. mediaName .. "/frames/" .. nf
                    download(nfurl, nfp)
                end
            end

            frame = frame + 1
        end
    end

    local function audioRoutine()
        if hasAudio and speaker then
            playAudio(speaker, mediaName)
        end
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
-- Menu helpers
-- ---------------------------------------------------------------------------
local function drawMenu(title, items, prompt)
    term.clear()
    term.setCursorPos(1, 1)
    print("=================================")
    print("  CC:T Media Player")
    print("  " .. title)
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
    io.write(prompt .. ": ")
    local input = io.read()
    local n = tonumber(input)
    if n == 0 then return nil end
    if n and items[n] then return items[n] end
    -- Try text match
    for _, name in ipairs(items) do
        if name:lower() == input:lower() then return name end
    end
    return nil
end

local function mainMenu(index)
    while true do
        term.clear()
        term.setCursorPos(1, 1)
        print("=================================")
        print("  CC:T Media Player")
        print("=================================")
        print("  1. Videos  (" .. #index.video .. " available)")
        print("  2. Audio   (" .. #index.audio .. " available)")
        print("---------------------------------")
        print("  R. Refresh library")
        print("  Q. Quit")
        print()
        io.write("Choice: ")
        local input = io.read()
        if not input then return nil, nil end
        input = input:lower()
        if input == "1" and #index.video > 0 then
            local pick = drawMenu("Videos", index.video, "Select video")
            if pick then return "video", pick end
        elseif input == "2" and #index.audio > 0 then
            local pick = drawMenu("Audio", index.audio, "Select audio")
            if pick then return "audio", pick end
        elseif input == "r" then
            return "refresh", nil
        elseif input == "q" then
            return "quit", nil
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
    if not speaker then
        print("[warn] No speaker found. Audio will be skipped.")
    end
    local mon = setupMonitor()

    local index = loadIndex()

    while true do
        local action, pick = mainMenu(index)

        if action == "quit" or not action then
            term.clear()
            term.setCursorPos(1, 1)
            print("Goodbye!")
            return

        elseif action == "refresh" then
            print("[player] Refreshing library...")
            index = loadIndex()
            print("Done.")
            os.sleep(0.5)

        elseif pick then
            print("[player] Loading: " .. pick)
            local ok, manifest = pcall(loadManifest, pick)
            if not ok then
                print("[error] " .. tostring(manifest))
                print("Press Enter to continue...")
                io.read()
            else
                playMedia(mon, speaker, pick, manifest)
            end
        end
    end
end

main()

-- ---------------------------------------------------------------------------
-- Self-update
-- ---------------------------------------------------------------------------
local function selfUpdate()
    print("[player] Checking for updates...")
    local tmpPath = "player.lua.tmp"
    local ok = pcall(function()
        if fs.exists(tmpPath) then fs.delete(tmpPath) end
        local result = http.get(SELF_URL)
        if not result then error("HTTP request failed") end
        local data = result.readAll()
        result.close()
        local f = fs.open(tmpPath, "w")
        f.write(data)
        f.close()
    end)
    if ok and fs.exists(tmpPath) then
        fs.delete(SELF_PATH)
        fs.move(tmpPath, SELF_PATH)
        print("[player] Updated! Rebooting...")
        os.sleep(0.5)
        os.reboot()
    else
        print("[player] Could not reach GitHub, running local copy.")
    end
end

-- ---------------------------------------------------------------------------
-- Download helper
-- ---------------------------------------------------------------------------
local function download(url, path)
    if fs.exists(path) then return true end
    local dirs = ""
    for part in path:gmatch("([^/]+)/") do
        dirs = dirs .. part .. "/"
        if not fs.exists(dirs) then fs.makeDir(dirs) end
    end
    local res = http.get(url)
    if not res then return false, "HTTP failed: " .. url end
    local data = res.readAll()
    res.close()
    local f = fs.open(path, "wb")
    f.write(data)
    f.close()
    return true
end

-- ---------------------------------------------------------------------------
-- Load manifest
-- ---------------------------------------------------------------------------
local function loadManifest(mediaName)
    local url  = GITHUB_RAW .. "/output/" .. mediaName .. "/manifest.lua"
    local path = "media/" .. mediaName .. "/manifest.lua"
    local ok, err = download(url, path)
    if not ok then error("Could not download manifest: " .. tostring(err)) end
    local fn = loadfile(path)
    if not fn then error("Could not parse manifest") end
    return fn()
end

-- ---------------------------------------------------------------------------
-- Monitor setup
-- ---------------------------------------------------------------------------
local function setupMonitor(manifest)
    local mon = peripheral.find("monitor")
    if not mon then
        print("[player] No monitor found, video disabled.")
        return nil
    end
    mon.setTextScale(0.5)  -- smallest scale for most pixels
    local mw, mh = mon.getSize()
    print(string.format("[player] Monitor size: %dx%d chars", mw, mh))
    return mon
end

-- ---------------------------------------------------------------------------
-- NFP renderer
-- ---------------------------------------------------------------------------
-- CC:T colour index → blit hex char
local BLIT = "0123456789abcdef"

local function renderNFP(mon, nfpText, manifest)
    if not mon then return end
    local mw, mh = mon.getSize()
    local row = 1
    for line in (nfpText .. "\n"):gmatch("([^\n]*)\n") do
        if row > mh then break end
        -- Each NFP char is a colour index; we draw coloured spaces
        local col = 1
        local i = 1
        while i <= #line and col <= mw do
            local c = line:sub(i, i)
            local ci = BLIT:find(c, 1, true)
            if ci then
                ci = ci - 1  -- 0-based
                local bc = BLIT:sub(ci + 1, ci + 1)
                mon.setCursorPos(col, row)
                mon.blit(" ", bc, bc)
            end
            col = col + 1
            i   = i   + 1
        end
        row = row + 1
    end
end

-- ---------------------------------------------------------------------------
-- DFPWM speaker playback (streams chunks)
-- ---------------------------------------------------------------------------
local function playAudio(speaker, mediaName, manifest)
    local CHUNK_SIZE = 16 * 1024  -- 16 KB per chunk
    local url = GITHUB_RAW .. "/output/" .. mediaName .. "/audio.dfpwm"

    print("[player] Streaming audio...")
    local res = http.get(url, nil, true)  -- binary mode
    if not res then
        print("[player] Could not fetch audio.")
        return
    end

    local dfpwm = require("cc.audio.dfpwm")
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
-- Video playback (downloads frames on demand)
-- ---------------------------------------------------------------------------
local function playVideo(mon, speaker, mediaName, manifest)
    local fps         = manifest.fps or 5
    local frameCount  = manifest.frame_count or 0
    local hasAudio    = manifest.has_audio == "true"
    local hasVideo    = manifest.has_video == "true" and mon ~= nil

    if frameCount == 0 and not hasAudio then
        print("[player] Nothing to play.")
        return
    end

    print(string.format("[player] Playing '%s'  frames=%d  fps=%d", mediaName, frameCount, fps))

    -- Pre-download first few frames
    local PREFETCH = math.min(10, frameCount)
    print(string.format("[player] Pre-fetching %d frames...", PREFETCH))
    for i = 1, PREFETCH do
        local fname = string.format("%06d.nfp", i)
        local furl  = GITHUB_RAW .. "/output/" .. mediaName .. "/frames/" .. fname
        local fpath = "media/" .. mediaName .. "/frames/" .. fname
        download(furl, fpath)
    end

    -- Start audio in parallel
    local audioRoutine
    if hasAudio and speaker then
        audioRoutine = function()
            playAudio(speaker, mediaName, manifest)
        end
    end

    local startTime = os.clock()
    local frame = 1

    local function videoRoutine()
        while frame <= frameCount do
            local targetTime = (frame - 1) / fps
            local elapsed    = os.clock() - startTime
            local waitTime   = targetTime - elapsed
            if waitTime > 0 then
                os.sleep(waitTime)
            end

            -- Render frame
            local fname = string.format("%06d.nfp", frame)
            local fpath = "media/" .. mediaName .. "/frames/" .. fname

            -- Download if not cached
            if not fs.exists(fpath) then
                local furl = GITHUB_RAW .. "/output/" .. mediaName .. "/frames/" .. fname
                download(furl, fpath)
            end

            if fs.exists(fpath) and hasVideo then
                local f = fs.open(fpath, "r")
                local nfpText = f.readAll()
                f.close()
                renderNFP(mon, nfpText, manifest)
            end

            -- Prefetch next frame in background
            local nextFrame = frame + PREFETCH
            if nextFrame <= frameCount then
                local nf    = string.format("%06d.nfp", nextFrame)
                local nfurl = GITHUB_RAW .. "/output/" .. mediaName .. "/frames/" .. nf
                local nfp   = "media/" .. mediaName .. "/frames/" .. nf
                if not fs.exists(nfp) then
                    download(nfurl, nfp)
                end
            end

            frame = frame + 1
        end
    end

    if audioRoutine then
        parallel.waitForAll(audioRoutine, videoRoutine)
    else
        videoRoutine()
    end

    print("\n[player] Playback complete.")
end

-- ---------------------------------------------------------------------------
-- Media picker
-- ---------------------------------------------------------------------------
local function pickMedia()
    -- List available media by fetching a simple index file from GitHub
    local indexUrl  = GITHUB_RAW .. "/output/index.lua"
    local indexPath = "media/index.lua"

    -- Try to fetch updated index
    local res = http.get(indexUrl)
    if res then
        local data = res.readAll()
        res.close()
        local f = fs.open(indexPath, "w")
        f.write(data)
        f.close()
    end

    if fs.exists(indexPath) then
        local fn = loadfile(indexPath)
        if fn then
            local list = fn()
            if list and #list > 0 then
                print("\n=== Available Media ===")
                for i, name in ipairs(list) do
                    print(string.format("  %d. %s", i, name))
                end
                io.write("\nEnter number or media name: ")
                local input = io.read()
                local n = tonumber(input)
                if n and list[n] then return list[n] end
                return input
            end
        end
    end

    -- Fallback: ask directly
    io.write("Enter media name (folder name in output/): ")
    return io.read()
end

-- ---------------------------------------------------------------------------
-- Main
-- ---------------------------------------------------------------------------
local function main()
    term.clear()
    term.setCursorPos(1, 1)
    print("=== CC:Tweaked Media Player ===")
    print("github.com/ob-105/CC-tweaked-Audio-video-playback.")
    print()

    -- Self-update
    selfUpdate()

    -- Find peripherals
    local speaker = peripheral.find("speaker")
    if not speaker then
        print("[warn] No speaker found. Audio will be skipped.")
    end

    local mon = setupMonitor(nil)

    -- Pick media
    local mediaName = pickMedia()
    if not mediaName or mediaName == "" then
        print("No media selected.")
        return
    end

    -- Load manifest
    print("[player] Loading manifest for: " .. mediaName)
    local ok, manifest = pcall(loadManifest, mediaName)
    if not ok then
        print("[error] " .. tostring(manifest))
        return
    end

    -- Play
    playVideo(mon, speaker, mediaName, manifest)
end

main()
