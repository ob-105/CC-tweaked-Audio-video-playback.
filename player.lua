-- CC:Tweaked Media Player v4
local GITHUB_RAW = "https://raw.githubusercontent.com/ob-105/CC-tweaked-Audio-video-playback./main"
local SELF_URL   = GITHUB_RAW .. "/player.lua"
local SELF_PATH  = "player.lua"
local VERSION    = "23"

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

-- Half-block renderer: each file line = "topColours|botColours" (CC hex chars).
-- Uses the lower-half-block glyph (\x8f in CC:T's font = U+2584 ▄):
--   foreground colour -> bottom pixel, background colour -> top pixel.
-- This gives 2x vertical resolution for the same monitor size.
local HALF_BLOCK = string.char(0x8f)
local function renderNFPH(mon, data)
    if not mon then return end
    local row = 0
    for line in (data.."\n"):gmatch("([^\n]*)\n") do
        row = row + 1
        local ln  = line:gsub("\r", "")
        local sep = ln:find("|", 1, true)
        if sep then
            local top = ln:sub(1, sep - 1)  -- background = top pixel colour
            local bot = ln:sub(sep + 1)     -- foreground = bottom pixel colour
            local w   = #top
            if w > 0 then
                mon.setCursorPos(1, row)
                mon.blit(HALF_BLOCK:rep(w), bot, top)
            end
        end
    end
end

-- NFPHC: half-block + RLE. Each line = "topRLE;botRLE" where each side
-- uses the same char:count|char:count encoding as NFPC.
local function renderNFPHC(mon, data)
    if not mon then return end
    local function decodeRLE(rle)
        local s = ""
        for run in (rle.."|" ):gmatch("([^|]*)|" ) do
            local c, n = run:match("^(.):(%d+)$")
            if c and n then s = s .. c:rep(tonumber(n)) end
        end
        return s
    end
    local row = 0
    for line in (data.."\n"):gmatch("([^\n]*)\n") do
        row = row + 1
        local ln  = line:gsub("\r", "")
        local sep = ln:find(";", 1, true)
        if sep then
            local top = decodeRLE(ln:sub(1, sep - 1))
            local bot = decodeRLE(ln:sub(sep + 1))
            local w   = #top
            if w > 0 then
                mon.setCursorPos(1, row)
                mon.blit(HALF_BLOCK:rep(w), bot, top)
            end
        end
    end
end

local function playAudio(speakers, name, stats, audioData)
    local dfpwm   = require("cc.audio.dfpwm")
    local decoder = dfpwm.make_decoder()
    local stalls  = 0

    local function processChunks(readFn, closeFn)
        while true do
            local t0chunk = os.clock()
            local chunk = readFn()
            if not chunk then break end
            local fetchTime = os.clock() - t0chunk
            if fetchTime > 0.5 then
                stalls = stalls + 1
                if stats then stats.audioStalls = (stats.audioStalls or 0) + 1 end
                print(("\n[warn] Audio fetch slow: %.2fs"):format(fetchTime))
            end
            local pcm  = decoder(chunk)
            local busy = true
            local underrun = false
            while busy do
                busy = false
                for _, spk in ipairs(speakers) do
                    if not spk.playAudio(pcm) then busy = true end
                end
                if busy then
                    underrun = true
                    os.pullEvent("speaker_audio_empty")
                end
            end
            if underrun then
                stalls = stalls + 1
                if stats then stats.audioStalls = (stats.audioStalls or 0) + 1 end
            end
        end
        if closeFn then closeFn() end
    end

    if audioData then
        -- Play from in-memory string fetched from the storage network
        print("[player] Playing audio from storage network...")
        local pos = 1
        processChunks(function()
            if pos > #audioData then return nil end
            local chunk = audioData:sub(pos, pos + 16383)
            pos = pos + 16384
            return chunk
        end, nil)
    elseif fs.exists("media/" .. name .. "/audio.dfpwm") then
        print("[player] Playing audio from local cache...")
        local fh = fs.open("media/" .. name .. "/audio.dfpwm", "rb")
        if not fh then
            if stats then stats.audioFailed = true end; return
        end
        processChunks(function() return fh.read(16384) end, function() fh.close() end)
    else
        local url = GITHUB_RAW .. "/output/" .. name .. "/audio.dfpwm"
        print(("[player] Streaming audio on %d speaker(s)..."):format(#speakers))
        local res = http.get(url, nil, true)
        if not res then
            print("[player] Audio fetch FAILED.")
            if stats then stats.audioFailed = true end; return
        end
        processChunks(function() return res.read(16384) end, function() res.close() end)
    end

    if stats then stats.audioStalls = stalls end
end

-- ---------------------------------------------------------------------------
-- Storage network helpers
-- ---------------------------------------------------------------------------
local STORAGE_API_URL = "https://raw.githubusercontent.com/ob-105/CC-Tweaked-General-Purpose-Storage-Network/main/storage_api.lua"

-- Probe each modem individually to find the one connected to the storage
-- controller, then pre-open it so storage_api's broadcast reaches the right
-- network. Works regardless of whether peripherals share a network or not.
local CTRL_PROTOCOL = "cct-store-ctrl"
local function findStorageModem()
    local allModems = {}
    for _, side in ipairs(peripheral.getNames()) do
        if peripheral.getType(side) == "modem" then allModems[#allModems+1] = side end
    end
    if #allModems <= 1 then return allModems[1] end
    -- Close all modems so we can test each in isolation
    for _, s in ipairs(allModems) do pcall(rednet.close, s) end
    local found = nil
    for _, side in ipairs(allModems) do
        pcall(rednet.open, side)
        rednet.broadcast({cmd = "ping"}, CTRL_PROTOCOL)
        local deadline = os.clock() + 2
        while os.clock() < deadline do
            local sender, msg = rednet.receive(CTRL_PROTOCOL, deadline - os.clock())
            if sender and type(msg) == "table" and msg.ok then
                found = side; break
            end
        end
        pcall(rednet.close, side)
        if found then break end
    end
    -- Pre-open the found modem so storage_api broadcasts through it.
    -- If nothing responded, open all modems and let storage_api try.
    if found then
        pcall(rednet.open, found)
    else
        for _, s in ipairs(allModems) do pcall(rednet.open, s) end
    end
    return found
end

local function initStore()
    if not fs.exists("storage_api.lua") then
        io.write("[net] Downloading storage_api.lua... ")
        local ok = download(STORAGE_API_URL, "storage_api.lua")
        print(ok and "OK" or "FAILED")
        if not ok then return nil end
    end
    -- Only probe when there are multiple modems (single-modem setups need no help)
    local modemCount = 0
    for _, side in ipairs(peripheral.getNames()) do
        if peripheral.getType(side) == "modem" then modemCount = modemCount + 1 end
    end
    if modemCount > 1 then
        io.write("[net] Probing modems for storage controller... ")
        local found = findStorageModem()
        if found then print("found on " .. found)
        else print("not found — trying all modems") end
    end
    local ok, store = pcall(require, "storage_api")
    if not ok then
        print("[net] storage_api load failed: " .. tostring(store))
        return nil
    end
    return store
end

local function uploadToNetwork(name, manifest, store)
    local count = manifest.frame_count or 0
    local fext  = manifest.frame_ext or "nfp"
    local audio = manifest.has_audio == "true"
    local video = manifest.has_video == "true"

    term.clear(); term.setCursorPos(1,1)
    print(("=== Uploading '%s' to storage network ==="):format(name))

    -- Check network stats before starting
    local info = store.stats()
    if info then
        print(("  Network: %d node(s)  %d KB free"):format(
            #info.nodes, math.floor(info.totalFree / 1024)))
    end

    -- Audio
    if audio then
        local audioKey = "media/" .. name .. "/audio"
        if store.exists(audioKey) then
            print("  Audio: already in network.")
        else
            io.write("  Fetching audio from GitHub... ")
            local res = http.get(GITHUB_RAW .. "/output/" .. name .. "/audio.dfpwm", nil, true)
            if not res then
                print("FAILED")
            else
                local data = res.readAll(); res.close()
                print(("OK (%d KB)"):format(math.ceil(#data / 1024)))
                io.write("  Uploading audio to network... ")
                local ok, err = store.put(audioKey, data)
                print(ok and "OK" or ("FAILED: " .. tostring(err)))
            end
        end
    end

    -- Frames
    if video and count > 0 then
        local failed = 0
        for i = 1, count do
            local frameKey = ("media/%s/frames/%06d"):format(name, i)
            if not store.exists(frameKey) then
                local url = ("%s/output/%s/frames/%06d.%s"):format(GITHUB_RAW, name, i, fext)
                local res = http.get(url)
                if not res then
                    failed = failed + 1
                else
                    local data = res.readAll(); res.close()
                    local ok, err = store.put(frameKey, data)
                    if not ok then failed = failed + 1 end
                end
            end
            term.write(("\r  Frames %d/%d (%d%%)  fail=%d   "):format(
                i, count, math.floor(i * 100 / count), failed))
        end
        print()
        if failed > 0 then
            print(("[warn] %d item(s) failed to upload."):format(failed))
        else
            print("[net] Upload complete. All frames in network.")
        end
    end

    print("\n[net] Ready — press Enter to start playback.")
    io.read()
end

local function preDownload(name, manifest)
    local count = manifest.frame_count or 0
    local fext  = manifest.frame_ext or "nfp"
    local audio = manifest.has_audio == "true"
    local video = manifest.has_video == "true"

    term.clear(); term.setCursorPos(1,1)
    print(("=== Pre-downloading '%s' ==="):format(name))

    -- Disk space check
    if count > 0 then
        local fw    = manifest.width  or 51
        local fh    = manifest.height or 19
        local estKB = math.ceil(((fw + 1) * fh * count) / 1024)
        local freeKB = math.ceil(fs.getFreeSpace("/") / 1024)
        print(("  %d frames  ~%d KB needed  %d KB free"):format(count, estKB, freeKB))
        if freeKB < estKB + 300 then
            print("[warn] Disk may be too small to fit all frames.")
            io.write("Continue anyway? (y/n): ")
            if io.read():lower() ~= "y" then return end
        end
    end

    -- Audio
    if audio then
        local ap = "media/" .. name .. "/audio.dfpwm"
        if fs.exists(ap) then
            print("  Audio: already cached.")
        else
            io.write("  Downloading audio... ")
            local ok = download(GITHUB_RAW .. "/output/" .. name .. "/audio.dfpwm", ap)
            print(ok and "OK" or "FAILED")
        end
    end

    -- Frames
    if video and count > 0 then
        local failed = 0
        for i = 1, count do
            local p   = ("media/%s/frames/%06d.%s"):format(name, i, fext)
            local url = ("%s/output/%s/frames/%06d.%s"):format(GITHUB_RAW, name, i, fext)
            if not fs.exists(p) then
                if not download(url, p) then failed = failed + 1 end
            end
            term.write(("\r  Frames %d/%d (%d%%)  fail=%d   "):format(
                i, count, math.floor(i * 100 / count), failed))
        end
        print()
        if failed > 0 then
            print(("[warn] %d frame(s) could not be downloaded."):format(failed))
        else
            print("[preload] All frames cached successfully.")
        end
    end

    print("\n[preload] Done — press Enter to start playback.")
    io.read()
end

local function mediaActionMenu(name)
    term.clear(); term.setCursorPos(1,1)
    print("=================================")
    print(("  %s"):format(name))
    print("=================================")
    print("  1. Play now  (stream on demand)")
    print("  2. Pre-download to local disk")
    print("  3. Upload to storage network")
    print("---------------------------------")
    print("  0. Back"); print()
    io.write("Choice: ")
    local n = tonumber(io.read())
    if n == 1 then return "play"
    elseif n == 2 then return "predownload"
    elseif n == 3 then return "network"
    else return nil end
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

local function playMedia(mon, speakers, name, manifest, store)
    local fps   = manifest.fps or 5
    local count = manifest.frame_count or 0
    local audio = manifest.has_audio == "true"
    local video = manifest.has_video == "true" and mon ~= nil
    local FRAME_BUFFER = calcBuffer(manifest)
    local source = store and "network" or "stream/disk"
    print(("[player] Playing '%s'  source=%s  buffer=%d frames"):format(name, source, FRAME_BUFFER))
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

    -- Shared stats table written by both loops
    local stats = { skipped=0, dlSlow=0, dlFailed=0, audioStalls=0, audioFailed=false }
    local framePeriod = 1 / fps
    local totalSecs   = count / fps

    -- For network playback, pre-fetch audio from the store into memory so the
    -- audioLoop can play it without any HTTP during playback.
    local audioData = nil
    if store and audio then
        io.write("[player] Fetching audio from network... ")
        local data, err = store.get("media/" .. name .. "/audio")
        if data then
            audioData = data
            print(("OK (%d KB)"):format(math.ceil(#data / 1024)))
        else
            print("FAILED: " .. tostring(err))
            stats.audioFailed = true
        end
    end

    local t0 = os.clock()
    local function videoLoop()
        for frame = 1, count do
            local due     = (frame - 1) * framePeriod
            local elapsed = os.clock() - t0
            local frameData = nil

            if store then
                -- Fetch frame from storage network
                local dlT0 = os.clock()
                local key  = ("media/%s/frames/%06d"):format(name, frame)
                local data, err = store.get(key)
                local dlMs = math.floor((os.clock() - dlT0) * 1000)
                if data then
                    frameData = data
                    if dlMs > framePeriod * 1000 then
                        stats.dlSlow = stats.dlSlow + 1
                    end
                else
                    stats.dlFailed = stats.dlFailed + 1
                    print(("\n[warn] Frame %d network FAILED: %s"):format(frame, tostring(err)))
                end
            else
                -- Download to local disk (original streaming path)
                local p = framePath(frame)
                if not fs.exists(p) then
                    local dlT0 = os.clock()
                    local ok   = download(frameURL(frame), p)
                    local dlMs = math.floor((os.clock() - dlT0) * 1000)
                    if not ok then
                        stats.dlFailed = stats.dlFailed + 1
                        print(("\n[warn] Frame %d download FAILED"):format(frame))
                    elseif dlMs > framePeriod * 1000 then
                        stats.dlSlow = stats.dlSlow + 1
                        print(("\n[warn] Frame %d download slow (%dms, budget %dms)"):format(
                            frame, dlMs, math.floor(framePeriod * 1000)))
                    end
                end
                if fs.exists(p) then
                    local fh = fs.open(p, "r")
                    if fh then frameData = fh.readAll(); fh.close() end
                end
            end

            -- Live status line (overwrites itself)
            local timeLeft = math.max(0, totalSecs - elapsed)
            term.write(("\r  Frame %d/%d (%d%%)  %.0fs left  skip=%d  slow=%d  fail=%d   "):format(
                frame, count,
                math.floor(frame * 100 / count),
                timeLeft,
                stats.skipped, stats.dlSlow, stats.dlFailed))

            elapsed = os.clock() - t0
            if elapsed <= due + framePeriod then
                local wait = due - elapsed
                if wait > 0 then os.sleep(wait) end
                if frameData and video then
                    if fext == "nfphc" then renderNFPHC(mon, frameData)
                    elseif fext == "nfph" then renderNFPH(mon, frameData)
                    elseif fext == "nfpc" then renderNFPC(mon, frameData)
                    else renderNFP(mon, frameData) end
                end
            else
                stats.skipped = stats.skipped + 1
            end

            if not store then
                -- Local disk: delete rendered frame and pre-fetch lookahead
                local p = framePath(frame)
                if fs.exists(p) then fs.delete(p) end
                local nx = frame + FRAME_BUFFER
                if nx <= count and fs.getFreeSpace("/") > 400 * 1024 then
                    download(frameURL(nx), framePath(nx))
                end
            end
        end
        print()  -- newline after the final status line
    end
    local function audioLoop()
        if audio and #speakers > 0 then playAudio(speakers, name, stats, audioData) end
    end
    if audio and video and count > 0 then parallel.waitForAll(audioLoop, videoLoop)
    elseif audio then audioLoop()
    elseif count > 0 then videoLoop() end

    -- Playback summary
    print("[player] Playback complete.")
    if stats.skipped   > 0 then print(("  Skipped frames : %d"):format(stats.skipped)) end
    if stats.dlSlow    > 0 then print(("  Slow downloads : %d"):format(stats.dlSlow)) end
    if stats.dlFailed  > 0 then print(("  Failed downloads: %d"):format(stats.dlFailed)) end
    if stats.audioStalls > 0 then print(("  Audio stalls   : %d"):format(stats.audioStalls)) end
    if stats.audioFailed   then print("  Audio          : FAILED to fetch") end
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
            else
                local subaction = mediaActionMenu(pick)
                if subaction == "predownload" then
                    preDownload(pick, manifest)
                    playMedia(mon, speakers, pick, manifest, nil)
                elseif subaction == "network" then
                    local store = initStore()
                    if store then
                        uploadToNetwork(pick, manifest, store)
                        playMedia(mon, speakers, pick, manifest, store)
                    else
                        print("[error] Could not connect to storage network.")
                        print("Press Enter..."); io.read()
                    end
                elseif subaction == "play" then
                    playMedia(mon, speakers, pick, manifest, nil)
                end
            end
        end
    end
end

main()