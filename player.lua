-- CC:Tweaked Media Player v4
local GITHUB_RAW = "https://raw.githubusercontent.com/ob-105/CC-tweaked-Audio-video-playback./main"
local SELF_URL   = GITHUB_RAW .. "/player.lua"
local SELF_PATH  = "player.lua"
local VERSION    = "16"

local function selfUpdate()
    print("[player] Checking for updates...")
    local ok, newData = pcall(function()
        local r = http.get(SELF_URL)
        if not r then error("HTTP failed") end
        local d = r.readAll(); r.close(); return d
    end)
    if not ok or not newData then print("[player] Offline, using local copy."); return end
    local remoteVer = newData:match('local VERSION%s*=%s*"(%d+)"')
    if not remoteVer then print("[player] Bad remote version."); return end
    if tonumber(remoteVer) <= tonumber(VERSION) then print("[player] Up to date (v"..VERSION..")."); return end
    local f = fs.open(SELF_PATH, "w"); f.write(newData); f.close()
    print("[player] Updated to v"..remoteVer.."! Rebooting..."); os.sleep(0.5); os.reboot()
end

local function download(url, path)
    if fs.exists(path) then return true end
    local dir = path:match("^(.*)/[^/]+$")
    if dir and dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
    local res = http.get(url, nil, true)
    if not res then return false end
    local data = res.readAll(); res.close()
    local f = fs.open(path, "wb"); f.write(data); f.close()
    return true
end

local function loadIndex()
    local url  = GITHUB_RAW .. "/output/index.lua"
    local path = "media/index.lua"
    if fs.exists(path) then fs.delete(path) end
    local res = http.get(url)
    if res then
        local data = res.readAll(); res.close()
        if not fs.exists("media") then fs.makeDir("media") end
        local f = fs.open(path, "w"); f.write(data); f.close()
    end
    if not fs.exists(path) then return {video={},audio={}} end
    local fn = loadfile(path)
    if not fn then return {video={},audio={}} end
    local ok, r = pcall(fn)
    if not ok or type(r) ~= "table" then return {video={},audio={}} end
    r.video = r.video or {}; r.audio = r.audio or {}
    return r
end

local function loadManifest(name)
    local url  = GITHUB_RAW .. "/output/" .. name .. "/manifest.lua"
    local path = "media/" .. name .. "/manifest.lua"
    if fs.exists(path) then fs.delete(path) end
    if not download(url, path) then error("Could not download manifest") end
    local fn = loadfile(path)
    if not fn then error("Could not parse manifest") end
    return fn()
end

local function setupMonitor()
    -- Try local first, then any monitor reachable over a wired network
    local mon = peripheral.find("monitor")
    if not mon then return nil end
    mon.setTextScale(0.5)
    local w, h = mon.getSize()
    print(("[player] Monitor: %dx%d"):format(w, h))
    return mon
end

local function findSpeakers()
    -- Collect all speakers (local + networked via wired modem)
    local found = {}
    local seen  = {}
    for _, s in ipairs({peripheral.find("speaker")}) do
        local n = peripheral.getName(s)
        if not seen[n] then seen[n] = true; found[#found+1] = s end
    end
    -- Also walk every wired modem and pull remote speakers
    for _, side in ipairs(peripheral.getNames()) do
        local p = peripheral.wrap(side)
        if p and peripheral.getType(side) == "modem" and p.isWireless and not p.isWireless() then
            -- wired modem: open it so remote names are visible
            if p.open then pcall(p.open, 0) end
            if p.getNamesOnNetwork then
                for _, rname in ipairs(p.getNamesOnNetwork()) do
                    if not seen[rname] then
                        local rtype = p.getTypeOnSide and p.getTypeOnSide(rname)
                        if rtype == "speaker" or peripheral.getType(rname) == "speaker" then
                            local rs = peripheral.wrap(rname)
                            if rs then seen[rname] = true; found[#found+1] = rs end
                        end
                    end
                end
            end
        end
    end
    return found
end

local function renderLines(mon, lines)
    if not mon then return end
    local nh = #lines
    if nh == 0 then return end
    local nw = #lines[1]
    if nw == 0 then return end
    local mw, mh = mon.getSize()
    -- Build each output row as a full-width blit string, then send in one call.
    -- This cuts API calls from (mw * mh) down to mh, which is ~mw times faster.
    local spaces = (" "):rep(mw)
    for row = 1, mh do
        local srcRow = math.max(1, math.min(nh, math.ceil(row * nh / mh)))
        local line   = lines[srcRow]
        local colour = {}
        for col = 1, mw do
            local srcCol = math.max(1, math.min(nw, math.ceil(col * nw / mw)))
            colour[col]  = line:sub(srcCol, srcCol)
        end
        local colStr = table.concat(colour)
        mon.setCursorPos(1, row)
        mon.blit(spaces, colStr, colStr)
    end
end

local function renderNFP(mon, data)
    if not mon then return end
    local lines = {}
    for line in (data.."\n"):gmatch("([^\n]*)\n") do
        lines[#lines+1] = line:gsub("\r", "")
    end
    renderLines(mon, lines)
end

local function renderNFPC(mon, data)
    if not mon then return end
    local lines = {}
    for rowstr in (data.."\n"):gmatch("([^\n]*)\n") do
        local rs   = rowstr:gsub("\r", "")
        local line = ""
        for run in (rs.."|" ):gmatch("([^|]*)|" ) do
            local c, n = run:match("^(.):(%d+)$")
            if c and n then line = line .. c:rep(tonumber(n)) end
        end
        lines[#lines+1] = line
    end
    renderLines(mon, lines)
end

local function playAudio(speakers, name)
    local url = GITHUB_RAW .. "/output/" .. name .. "/audio.dfpwm"
    print(("[player] Streaming audio on %d speaker(s)..."):format(#speakers))
    local res = http.get(url, nil, true)
    if not res then print("[player] Audio fetch failed."); return end
    local dfpwm = require("cc.audio.dfpwm")
    local decoder = dfpwm.make_decoder()
    while true do
        local chunk = res.read(16384)
        if not chunk then break end
        local pcm = decoder(chunk)
        -- Play to all speakers simultaneously; wait if any is busy
        local busy = true
        while busy do
            busy = false
            for _, spk in ipairs(speakers) do
                if not spk.playAudio(pcm) then busy = true end
            end
            if busy then os.pullEvent("speaker_audio_empty") end
        end
    end
    res.close()
end

local function calcBuffer(manifest)
    -- Each NFP frame is (width + 1) * height bytes (chars + newlines)
    local fw = manifest.width  or 51
    local fh = manifest.height or 19
    local frame_bytes = (fw + 1) * fh
    -- Leave 200 KB headroom for the OS, player.lua and index files
    local free = fs.getFreeSpace("/") - 200 * 1024
    if free <= 0 then return 1 end
    -- Use at most half the remaining free space for the frame buffer
    local buf = math.floor((free / 2) / frame_bytes)
    return math.max(1, math.min(buf, 60))  -- clamp: at least 1, at most 60
end

local function playMedia(mon, speakers, name, manifest)
    local fps   = manifest.fps or 5
    local count = manifest.frame_count or 0
    local audio = manifest.has_audio == "true"
    local video = manifest.has_video == "true" and mon ~= nil
    local FRAME_BUFFER = calcBuffer(manifest)
    print(("[player] Playing '%s'  buffer=%d frames"):format(name, FRAME_BUFFER))
    print(("[player] frames=%d  audio=%s  video=%s  speakers=%d  monitor=%s"):format(
        count, tostring(audio), tostring(video),
        #speakers, tostring(mon ~= nil)))

    local fext = manifest.frame_ext or "nfp"
    local function framePath(i)
        return ("media/%s/frames/%06d.%s"):format(name, i, fext)
    end
    local function frameURL(i)
        return ("%s/output/%s/frames/%06d.%s"):format(GITHUB_RAW, name, i, fext)
    end

    -- No pre-fetch burst: the rolling loop downloads ahead safely one frame at a time
    local t0 = os.clock()
    local skipped = 0
    local function videoLoop()
        for frame = 1, count do
            local due = (frame - 1) / fps  -- seconds this frame is due
            local elapsed = os.clock() - t0
            -- If we're more than one frame period behind, skip rendering (keep audio sync)
            local p = framePath(frame)
            if not fs.exists(p) then download(frameURL(frame), p) end
            if elapsed <= due + (1 / fps) then
                -- On time (or close enough): wait if early, then render
                local wait = due - elapsed
                if wait > 0 then os.sleep(wait) end
                if fs.exists(p) and video then
                    local fh = fs.open(p, "r")
                    local data = fh.readAll(); fh.close()
                    if fext == "nfpc" then renderNFPC(mon, data)
                    else renderNFP(mon, data) end
                end
            else
                -- Behind: skip render, catch up
                skipped = skipped + 1
            end
            if fs.exists(p) then fs.delete(p) end
            -- Download the next lookahead frame only if there is room
            local nx = frame + FRAME_BUFFER
            if nx <= count and fs.getFreeSpace("/") > 400 * 1024 then
                download(frameURL(nx), framePath(nx))
            end
        end
        if skipped > 0 then print(("[player] Skipped %d frame(s) to maintain sync."):format(skipped)) end
    end
    local function audioLoop() if audio and #speakers > 0 then playAudio(speakers, name) end end
    if audio and video and count > 0 then parallel.waitForAll(audioLoop, videoLoop)
    elseif audio then audioLoop()
    elseif count > 0 then videoLoop() end
    -- Clean up any leftover buffered frames (downloaded but not yet rendered)
    local mediaDir = "media/"..name
    if fs.exists(mediaDir) then fs.delete(mediaDir) end
    print("\n[player] Done. Press Enter..."); io.read()
end

local function drawMenu(title, items)
    term.clear(); term.setCursorPos(1,1)
    print("=================================")
    print("  CC:T Media Player  |  "..title)
    print("=================================")
    if #items == 0 then print("  (none available)")
    else for i, n in ipairs(items) do print(("  %d. %s"):format(i, n)) end end
    print("---------------------------------"); print("  0. Back"); print()
    io.write("Select: ")
    local n = tonumber(io.read())
    if not n or n == 0 then return nil end
    return items[n]
end

local function mainMenu(idx)
    while true do
        term.clear(); term.setCursorPos(1,1)
        print("=================================")
        print("  CC:T Media Player")
        print("=================================")
        print(("  1. Videos  (%d available)"):format(#idx.video))
        print(("  2. Audio   (%d available)"):format(#idx.audio))
        print("---------------------------------")
        print("  R. Refresh    Q. Quit"); print()
        io.write("Choice: ")
        local inp = io.read()
        if not inp then return "quit", nil end
        inp = inp:lower()
        if inp == "1" then
            if #idx.video == 0 then print("No videos yet."); os.sleep(1)
            else local p = drawMenu("Videos", idx.video); if p then return "play", p end end
        elseif inp == "2" then
            if #idx.audio == 0 then print("No audio yet."); os.sleep(1)
            else local p = drawMenu("Audio", idx.audio); if p then return "play", p end end
        elseif inp == "r" then return "refresh", nil
        elseif inp == "q" then return "quit", nil end
    end
end

local function main()
    term.clear(); term.setCursorPos(1,1)
    print("=== CC:Tweaked Media Player ==="); print()
    selfUpdate()
    -- Wipe cached media to free disk space before each session
    if fs.exists("media") then
        print("[player] Clearing media cache...")
        fs.delete("media")
    end
    -- Collect all connected speakers (local + networked)
    local speakers = findSpeakers()
    if #speakers == 0 then print("[warn] No speakers found. Audio disabled.")
    else print(("[player] Found %d speaker(s)."):format(#speakers)) end
    local mon = setupMonitor()
    local idx = loadIndex()
    while true do
        local action, pick = mainMenu(idx)
        if action == "quit" then term.clear(); term.setCursorPos(1,1); print("Goodbye!"); return
        elseif action == "refresh" then print("Refreshing..."); idx = loadIndex(); print("Done."); os.sleep(0.5)
        elseif action == "play" and pick then
            local ok, manifest = pcall(loadManifest, pick)
            if not ok then print("[error] "..tostring(manifest)); print("Press Enter..."); io.read()
            else playMedia(mon, speakers, pick, manifest) end
        end
    end
end

main()