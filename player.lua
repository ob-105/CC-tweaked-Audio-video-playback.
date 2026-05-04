-- CC:Tweaked Media Player v4
local GITHUB_RAW = "https://raw.githubusercontent.com/ob-105/CC-tweaked-Audio-video-playback./main"
local SELF_URL   = GITHUB_RAW .. "/player.lua"
local SELF_PATH  = "player.lua"
local VERSION    = "6"

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
    if remoteVer == VERSION then print("[player] Up to date (v"..VERSION..")."); return end
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
    local mon = peripheral.find("monitor")
    if not mon then return nil end
    mon.setTextScale(0.5)
    local w, h = mon.getSize()
    print(("[player] Monitor: %dx%d"):format(w, h))
    return mon
end

local BLIT = "0123456789abcdef"
local function renderNFP(mon, nfp)
    if not mon then return end
    local mw, mh = mon.getSize()
    local row = 1
    for line in (nfp.."\n"):gmatch("([^\n]*)\n") do
        if row > mh then break end
        for col = 1, math.min(#line, mw) do
            local c = line:sub(col, col)
            local ci = BLIT:find(c, 1, true)
            if ci then
                ci = ci - 1
                local bc = BLIT:sub(ci+1, ci+1)
                mon.setCursorPos(col, row); mon.blit(" ", bc, bc)
            end
        end
        row = row + 1
    end
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

local function playMedia(mon, speakers, name, manifest)
    local fps   = manifest.fps or 5
    local count = manifest.frame_count or 0
    local audio = manifest.has_audio == "true"
    local video = manifest.has_video == "true" and mon ~= nil
    print(("[player] Playing '%s'"):format(name))
    print(("[player] frames=%d  audio=%s  video=%s  speakers=%d  monitor=%s"):format(
        count, tostring(audio), tostring(video),
        #speakers, tostring(mon ~= nil)))
    local pre = math.min(10, count)
    if video and count > 0 then
        print(("[player] Pre-fetching %d frames..."):format(pre))
        for i = 1, pre do
            local f = ("%06d.nfp"):format(i)
            download(GITHUB_RAW.."/output/"..name.."/frames/"..f, "media/"..name.."/frames/"..f)
        end
    end
    local t0 = os.clock(); local frame = 1
    local function videoLoop()
        while frame <= count do
            local wait = (frame-1)/fps - (os.clock()-t0)
            if wait > 0 then os.sleep(wait) end
            local f = ("%06d.nfp"):format(frame)
            local p = "media/"..name.."/frames/"..f
            if not fs.exists(p) then download(GITHUB_RAW.."/output/"..name.."/frames/"..f, p) end
            if fs.exists(p) and video then
                local fh = fs.open(p, "r"); renderNFP(mon, fh.readAll()); fh.close()
            end
            local nx = frame + pre
            if nx <= count then
                local nf = "media/"..name.."/frames/"..("%06d.nfp"):format(nx)
                if not fs.exists(nf) then download(GITHUB_RAW.."/output/"..name.."/frames/"..("%06d.nfp"):format(nx), nf) end
            end
            frame = frame + 1
        end
    end
    local function audioLoop() if audio and #speakers > 0 then playAudio(speakers, name) end end
    if audio and video and count > 0 then parallel.waitForAll(audioLoop, videoLoop)
    elseif audio then audioLoop()
    elseif count > 0 then videoLoop() end
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
    -- Collect all connected speakers
    local speakers = {peripheral.find("speaker")}
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