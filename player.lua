-- CC:Tweaked Media Player v4
local GITHUB_RAW = "https://raw.githubusercontent.com/ob-105/CC-tweaked-Audio-video-playback./main"
local SELF_URL   = GITHUB_RAW .. "/player.lua"
local SELF_PATH  = "player.lua"
local VERSION    = "35"
local BASE_URL   = GITHUB_RAW  -- set at startup; may be overridden by tunnel URL
local REMOTE_PROTOCOL = "cct-media-ctrl"
local _playQueue    = {}   -- {name=str, action=str} items queued by remote
local _playerIndex  = {video={}, audio={}}  -- cached for remote queries during playback
local _playerStatus = {state="startup", media=nil, frame=0, count=0, volume=1.0}
local _remoteOpen   = false

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
    local url  = BASE_URL .. "/output/index.lua"
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
    local url  = BASE_URL .. "/output/" .. name .. "/manifest.lua"
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

-- Half-block glyph ▄: background = top pixel, foreground = bottom pixel.
local HALF_BLOCK = string.char(0x8f)

-- Scale decoded top/bot string arrays to fill the actual monitor size.
-- Fixes the "zoomed-in top-left" bug when frame dims != monitor dims.
local function renderHalfLines(mon, topLines, botLines)
    if not mon then return end
    local nh = #topLines
    if nh == 0 then return end
    local nw = #topLines[1]
    if nw == 0 then return end
    local mw, mh = mon.getSize()
    for row = 1, mh do
        local srcRow = math.max(1, math.min(nh, math.ceil(row * nh / mh)))
        local tLine  = topLines[srcRow]
        local bLine  = botLines[srcRow]
        local tStr, bStr = {}, {}
        for col = 1, mw do
            local srcCol = math.max(1, math.min(nw, math.ceil(col * nw / mw)))
            tStr[col] = tLine:sub(srcCol, srcCol)
            bStr[col] = bLine:sub(srcCol, srcCol)
        end
        mon.setCursorPos(1, row)
        mon.blit(HALF_BLOCK:rep(mw), table.concat(bStr), table.concat(tStr))
    end
end

local function decodeHalfRLE(rle)
    local s = ""
    for run in (rle.."|" ):gmatch("([^|]*)|" ) do
        local c, n = run:match("^(.):(%d+)$")
        if c and n then s = s .. c:rep(tonumber(n)) end
    end
    return s
end

-- NFPH: half-block, each line = "topColours|botColours"
local function renderNFPH(mon, data)
    if not mon then return end
    local topLines, botLines = {}, {}
    for line in (data.."\n"):gmatch("([^\n]*)\n") do
        local ln  = line:gsub("\r", "")
        local sep = ln:find("|", 1, true)
        if sep then
            topLines[#topLines+1] = ln:sub(1, sep - 1)
            botLines[#botLines+1] = ln:sub(sep + 1)
        end
    end
    renderHalfLines(mon, topLines, botLines)
end

-- NFPHC: half-block + RLE, each line = "topRLE;botRLE"
local function renderNFPHC(mon, data)
    if not mon then return end
    local topLines, botLines = {}, {}
    for line in (data.."\n"):gmatch("([^\n]*)\n") do
        local ln  = line:gsub("\r", "")
        local sep = ln:find(";", 1, true)
        if sep then
            topLines[#topLines+1] = decodeHalfRLE(ln:sub(1, sep - 1))
            botLines[#botLines+1] = decodeHalfRLE(ln:sub(sep + 1))
        end
    end
    renderHalfLines(mon, topLines, botLines)
end

-- NFPHCD: half-block + RLE + delta encoding.
-- First line of each file: "K" = full keyframe, "D" = delta (unchanged rows = "-").
-- Returns new {top=..., bot=...} state table for the next frame.
local function renderNFPHCD(mon, data, prevState)
    local nl     = data:find("\n")
    local marker = nl and data:sub(1, nl - 1):gsub("\r", "") or "K"
    local body   = nl and data:sub(nl + 1) or data
    local topLines, botLines = {}, {}
    if marker ~= "D" or not prevState then
        -- Keyframe: decode every row
        for line in (body.."\n"):gmatch("([^\n]*)\n") do
            local ln  = line:gsub("\r", "")
            local sep = ln:find(";", 1, true)
            if sep then
                topLines[#topLines+1] = decodeHalfRLE(ln:sub(1, sep - 1))
                botLines[#botLines+1] = decodeHalfRLE(ln:sub(sep + 1))
            end
        end
    else
        -- Delta frame: "-" = keep row from prevState, otherwise new row
        local prevTop, prevBot = prevState.top, prevState.bot
        local row = 0
        for line in (body.."\n"):gmatch("([^\n]*)\n") do
            row = row + 1
            local ln = line:gsub("\r", "")
            if ln == "-" then
                topLines[row] = prevTop[row] or ""
                botLines[row] = prevBot[row] or ""
            else
                local sep = ln:find(";", 1, true)
                if sep then
                    topLines[row] = decodeHalfRLE(ln:sub(1, sep - 1))
                    botLines[row] = decodeHalfRLE(ln:sub(sep + 1))
                else
                    topLines[row] = prevTop[row] or ""
                    botLines[row] = prevBot[row] or ""
                end
            end
        end
    end
    renderHalfLines(mon, topLines, botLines)
    return { top = topLines, bot = botLines }
end

local function playAudio(speakers, name, stats, audioData, stopped, paused, volume)
    local dfpwm   = require("cc.audio.dfpwm")
    local decoder = dfpwm.make_decoder()
    local stalls  = 0

    local function processChunks(readFn, closeFn)
        while true do
            -- Wait while paused
            while paused and paused.value and not (stopped and stopped.value) do
                os.sleep(0.05)
            end
            if stopped and stopped.value then break end
            local t0chunk = os.clock()
            -- Use pcall so a closed/dropped handle is treated as end-of-stream
            -- rather than crashing with "attempt to use a closed file"
            local ok, chunk = pcall(readFn)
            if not ok or not chunk then break end
            local fetchTime = os.clock() - t0chunk
            if fetchTime > 0.5 then
                stalls = stalls + 1
                if stats then stats.audioStalls = (stats.audioStalls or 0) + 1 end
                print(("\n[warn] Audio fetch slow: %.2fs"):format(fetchTime))
            end
            local pcm  = decoder(chunk)
            local vol  = (volume and volume.value) or 1.0
            local busy = true
            local underrun = false
            while busy do
                busy = false
                for _, spk in ipairs(speakers) do
                    if not spk.playAudio(pcm, vol) then busy = true end
                end
                if busy then
                    underrun = true
                    os.pullEvent("speaker_audio_empty")
                    if stopped and stopped.value then busy = false end
                    if paused and paused.value then busy = false end
                end
            end
            if stopped and stopped.value then break end
            if underrun then
                stalls = stalls + 1
                if stats then stats.audioStalls = (stats.audioStalls or 0) + 1 end
            end
        end
        if closeFn then pcall(closeFn) end
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
        local url = BASE_URL .. "/output/" .. name .. "/audio.dfpwm"
        print(("[player] Downloading audio on %d speaker(s)..."):format(#speakers))
        local res = http.get(url, nil, true)
        if not res then
            print("[player] Audio fetch FAILED.")
            if stats then stats.audioFailed = true end; return
        end
        -- Read entire file into memory immediately so the handle can be closed
        -- before prefetchLoop has any chance to interact with it.
        local allData = res.readAll()
        pcall(function() res.close() end)
        if not allData or #allData == 0 then
            print("[player] Audio data empty.")
            if stats then stats.audioFailed = true end; return
        end
        print(("[player] Audio buffered (%d KB)."):format(math.ceil(#allData / 1024)))
        local pos = 1
        processChunks(function()
            if pos > #allData then return nil end
            local chunk = allData:sub(pos, pos + 16383)
            pos = pos + 16384
            return chunk
        end, nil)
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
            local res = http.get(BASE_URL .. "/output/" .. name .. "/audio.dfpwm", nil, true)
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
                local url = ("%s/output/%s/frames/%06d.%s"):format(BASE_URL, name, i, fext)
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
            local ok = download(BASE_URL .. "/output/" .. name .. "/audio.dfpwm", ap)
            print(ok and "OK" or "FAILED")
        end
    end

    -- Frames
    if video and count > 0 then
        local failed = 0
        for i = 1, count do
            local p   = ("media/%s/frames/%06d.%s"):format(name, i, fext)
            local url = ("%s/output/%s/frames/%06d.%s"):format(BASE_URL, name, i, fext)
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

local function mediaActionMenu(name, handler)
    term.clear(); term.setCursorPos(1,1)
    print("=================================")
    print(("  %s"):format(name))
    print("=================================")
    print("  1. Stream  (rolling disk buffer)")
    print("  2. Pre-download to disk, then play")
    print("  3. Upload to storage network, then play")
    print("  4. Play from storage network  (already uploaded)")
    print("---------------------------------")
    print("  0. Back"); print()
    io.write("Choice: ")
    local inp = readChar(handler)
    if inp == "\1" then return "remote_play" end
    local n = tonumber(inp)
    if n == 1 then return "play"
    elseif n == 2 then return "predownload"
    elseif n == 3 then return "upload_play"
    elseif n == 4 then return "network_play"
    else return nil end
end

local function calcBuffer(manifest)
    local fw   = manifest.width  or 51
    local fh   = manifest.height or 19
    local fext = manifest.frame_ext or "nfp"
    -- Estimate worst-case bytes per frame based on format:
    --   nfp:    fw chars/row  → (fw+1)*fh
    --   nfpc:   RLE can be larger than raw if content varies → same as nfp
    --   nfph:   two colour strings + separator per row → (fw*2+2)*fh
    --   nfphc:  RLE on both halves; dithered = ~4 bytes/char → (fw*8+2)*fh
    --   nfphcd: similar to nfphc in worst case
    local frame_bytes
    if fext == "nfphc" or fext == "nfphcd" then
        frame_bytes = (fw * 8 + 2) * fh   -- pessimistic RLE on dithered content
    elseif fext == "nfph" then
        frame_bytes = (fw * 2 + 2) * fh
    else
        frame_bytes = (fw + 1) * fh
    end
    -- Leave 200 KB headroom for the OS, player.lua and index files
    local free = fs.getFreeSpace("/") - 200 * 1024
    if free <= 0 then return 1 end
    -- Use at most half the remaining free space for the frame buffer
    local buf = math.floor((free / 2) / frame_bytes)
    return math.max(1, math.min(buf, 30))  -- clamp: at least 1, at most 30
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
    local prevHalfState = nil  -- persistent state for nfphcd delta rendering
    local function framePath(i)
        return ("media/%s/frames/%06d.%s"):format(name, i, fext)
    end
    local function frameURL(i)
        return ("%s/output/%s/frames/%06d.%s"):format(BASE_URL, name, i, fext)
    end

    -- Shared stats table written by both loops
    local stats = { skipped=0, dlSlow=0, dlFailed=0, audioStalls=0, audioFailed=false }
    -- Shared control state
    local stopped = {value = false}  -- Q pressed: abort
    local done    = {value = false}  -- video/audio finished naturally
    local paused  = {value = false}  -- P pressed: freeze
    local volume  = {value = 1.0}    -- 0.0-3.0; +/- to adjust
    local framePeriod = 1 / fps
    local totalSecs   = count / fps

    -- Announce playback start to any listening remotes
    if _remoteOpen then
        rednet.broadcast({cmd="now_playing", id=os.getComputerID(), media=name}, REMOTE_PROTOCOL)
    end

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

    -- Prefetch ring-buffer for network play.
    -- prefetchBuf[i] = data string when ready, false if fetch failed, nil if not yet fetched.
    -- The prefetcher coroutine runs in parallel with the renderer and stays NET_AHEAD frames
    -- ahead. store.get() and os.sleep() both yield in CC:T, so the two coroutines interleave
    -- naturally: prefetcher fetches while renderer is sleeping for frame timing.
    local prefetchBuf = {}
    local renderIdx   = 0      -- frame the renderer is currently waiting for
    local NET_AHEAD   = store and 4 or 12  -- prefetch window (larger for parallel HTTP)

    local function prefetchLoop()
        if store then
            -- Sequential store.get() for storage-network playback
            for i = 1, count do
                if stopped.value then break end
                while i > renderIdx + NET_AHEAD do
                    if stopped.value then break end
                    os.sleep(0)
                end
                if stopped.value then break end
                if prefetchBuf[i] == nil then
                    local key  = ("media/%s/frames/%06d"):format(name, i)
                    local data = store.get(key)
                    prefetchBuf[i] = data or false
                end
            end
        else
            -- Parallel async HTTP (or instant disk read if already pre-downloaded)
            local inFlight  = {}   -- url -> frame index
            local nextFetch = 1
            local HTTP_PAR  = 6    -- max concurrent HTTP requests
            local function flightCount()
                local n = 0; for _ in pairs(inFlight) do n = n + 1 end; return n
            end
            while (nextFetch <= count or next(inFlight) ~= nil) and not stopped.value do
                -- Fire off HTTP requests or read disk up to limits
                while nextFetch <= count
                      and nextFetch <= renderIdx + NET_AHEAD
                      and flightCount() < HTTP_PAR
                      and not stopped.value do
                    local p = framePath(nextFetch)
                    if fs.exists(p) then
                        -- Pre-downloaded: read directly into buffer, no HTTP needed
                        local fh = fs.open(p, "r")
                        prefetchBuf[nextFetch] = fh and fh.readAll() or false
                        if fh then fh.close() end
                        nextFetch = nextFetch + 1
                    else
                        -- Stream: fire async HTTP request
                        local url = frameURL(nextFetch)
                        http.request(url, nil, nil, true)
                        inFlight[url] = nextFetch
                        nextFetch = nextFetch + 1
                    end
                end
                if next(inFlight) ~= nil then
                    -- Collect whichever HTTP response arrives next
                    local ev = {os.pullEvent()}
                    local evType = ev[1]
                    if evType == "http_success" then
                        local url, resp = ev[2], ev[3]
                        local idx = inFlight[url]
                        if idx then
                            prefetchBuf[idx] = resp.readAll()
                            resp.close()
                            inFlight[url] = nil
                        end
                        -- If url not in inFlight (e.g. audio response) leave it alone;
                        -- closing it here would corrupt the audio coroutine's handle.
                    elseif evType == "http_failure" then
                        local url = ev[2]
                        local idx = inFlight[url]
                        if idx then
                            prefetchBuf[idx] = false
                            inFlight[url] = nil
                        end
                    end
                    -- Other events (timer, speaker_audio_empty, key, etc.) are broadcast
                    -- to all coroutines by parallel.waitForAll — no action needed here
                elseif nextFetch > count then
                    break   -- all frames dispatched, no in-flight requests
                else
                    os.sleep(0)  -- waiting for renderIdx to advance; yield
                end
            end
        end
    end

    local function videoLoop()
        for frame = 1, count do
            if stopped.value then break end

            -- Handle pause: freeze frame timing by shifting t0 forward
            if paused.value then
                local pauseStart = os.clock()
                while paused.value and not stopped.value do os.sleep(0.05) end
                t0 = t0 + (os.clock() - pauseStart)
            end
            if stopped.value then break end

            renderIdx = frame
            _playerStatus.state  = paused.value and "paused" or "playing"
            _playerStatus.media  = name
            _playerStatus.frame  = frame
            _playerStatus.count  = count
            _playerStatus.volume = volume.value
            local due     = (frame - 1) * framePeriod
            local elapsed = os.clock() - t0
            local frameData = nil

            -- Wait for prefetcher to deliver this frame (works for both store and HTTP paths)
            local giveUp = os.clock() + framePeriod * 2
            while prefetchBuf[frame] == nil and os.clock() < giveUp and not stopped.value do
                os.sleep(0)
            end
            local fd = prefetchBuf[frame]
            prefetchBuf[frame] = nil  -- release memory immediately
            if fd then
                frameData = fd
            else
                if not stopped.value then stats.dlFailed = stats.dlFailed + 1 end
            end

            -- Live status line (overwrites itself)
            elapsed = os.clock() - t0
            local timeLeft = math.max(0, totalSecs - elapsed)
            local pauseTag = paused.value and "  ||PAUSED||" or ""
            term.write(("\r  Frame %d/%d (%d%%)  %.0fs  Vol:%.1f  [P]/[Q]  skip=%d fail=%d%s   "):format(
                frame, count,
                math.floor(frame * 100 / count),
                timeLeft, volume.value,
                stats.skipped, stats.dlFailed, pauseTag))

            elapsed = os.clock() - t0
            if elapsed <= due + framePeriod then
                local wait = due - elapsed
                if wait > 0 then os.sleep(wait) end
                if frameData and video and not stopped.value then
                    if fext == "nfphcd" then prevHalfState = renderNFPHCD(mon, frameData, prevHalfState)
                    elseif fext == "nfphc" then renderNFPHC(mon, frameData)
                    elseif fext == "nfph" then renderNFPH(mon, frameData)
                    elseif fext == "nfpc" then renderNFPC(mon, frameData)
                    else renderNFP(mon, frameData) end
                    -- Progress bar overlay on the bottom row of the monitor
                    local mw, mh = mon.getSize()
                    local barW = mw - 7
                    local filled = math.max(0, math.floor(barW * frame / count))
                    local bar = string.rep("=", filled) .. string.rep("-", barW - filled)
                    local pct = math.floor(frame * 100 / count)
                    mon.setCursorPos(1, mh)
                    mon.setBackgroundColor(colors.black)
                    mon.setTextColor(paused.value and colors.yellow or colors.lime)
                    mon.write(("[%s]%3d%%"):format(bar, pct):sub(1, mw))
                end
            else
                if not stopped.value then stats.skipped = stats.skipped + 1 end
            end
        end
        -- Signal inputLoop that video is done so it can exit cleanly
        done.value = true
        os.queueEvent("playback_done")
        print()  -- newline after the final status line
    end
    local function audioLoop()
        if audio and #speakers > 0 then playAudio(speakers, name, stats, audioData, stopped, paused, volume) end
        -- Signal inputLoop to exit (needed for audio-only playback where videoLoop never runs)
        done.value = true
        os.queueEvent("playback_done")
    end
    local function inputLoop()
        local function doStop()
            stopped.value = true
            for _, spk in ipairs(speakers) do pcall(function() spk.stop() end) end
            os.queueEvent("speaker_audio_empty")
        end
        local function doTogglePause()
            paused.value = not paused.value
            -- Wake audio if it's sleeping on speaker_audio_empty while we unpause
            if not paused.value then os.queueEvent("speaker_audio_empty") end
        end
        while true do
            local ev = {os.pullEvent()}
            if ev[1] == "key" then
                local k = ev[2]
                if k == keys.q then
                    doStop(); return
                elseif k == keys.p then
                    doTogglePause()
                elseif k == keys.equals then  -- = / + key
                    volume.value = math.min(3.0, math.floor((volume.value + 0.2) * 10 + 0.5) / 10)
                elseif k == keys.minus then
                    volume.value = math.max(0.0, math.floor((volume.value - 0.2) * 10 + 0.5) / 10)
                end
            elseif ev[1] == "rednet_message" then
                local senderID, msg, protocol = ev[2], ev[3], ev[4]
                if protocol == REMOTE_PROTOCOL and type(msg) == "table" then
                    local cmd = msg.cmd
                    if     cmd == "stop"         then doStop(); return
                    elseif cmd == "toggle_pause" then doTogglePause()
                    elseif cmd == "pause"        then paused.value = true
                    elseif cmd == "resume"       then paused.value = false; os.queueEvent("speaker_audio_empty")
                    elseif cmd == "vol_up" then
                        volume.value = math.min(3.0, math.floor((volume.value + 0.2)*10+0.5)/10)
                        _playerStatus.volume = volume.value
                    elseif cmd == "vol_down" then
                        volume.value = math.max(0.0, math.floor((volume.value - 0.2)*10+0.5)/10)
                        _playerStatus.volume = volume.value
                    elseif cmd == "status" then
                        rednet.send(senderID, {
                            cmd="status_reply", state=_playerStatus.state,
                            media=name, frame=_playerStatus.frame,
                            count=count, volume=volume.value, queue=#_playQueue,
                        }, REMOTE_PROTOCOL)
                    elseif cmd == "list" then
                        rednet.send(senderID, {
                            cmd="list_reply",
                            videos=_playerIndex.video, audio=_playerIndex.audio,
                        }, REMOTE_PROTOCOL)
                    elseif cmd == "queue_add" and type(msg.name)=="string" then
                        table.insert(_playQueue, {name=msg.name, action=msg.action or "play"})
                        rednet.send(senderID, {cmd="ok", queue=#_playQueue}, REMOTE_PROTOCOL)
                    elseif cmd == "queue_list" then
                        rednet.send(senderID, {cmd="queue_reply", queue=_playQueue}, REMOTE_PROTOCOL)
                    elseif cmd == "queue_clear" then
                        _playQueue = {}
                        rednet.send(senderID, {cmd="ok"}, REMOTE_PROTOCOL)
                    end
                end
            end
            if done.value then return end
        end
    end
    -- Always run inputLoop in parallel so Q-to-stop works for all playback modes
    if audio and video and count > 0 then parallel.waitForAll(audioLoop, videoLoop, prefetchLoop, inputLoop)
    elseif audio then parallel.waitForAll(audioLoop, inputLoop)
    elseif count > 0 then parallel.waitForAll(videoLoop, prefetchLoop, inputLoop) end

    -- Playback summary
    if stopped.value then
        print("[player] Stopped.")
    else
        print("[player] Playback complete.")
        if stats.skipped   > 0 then print(("  Skipped frames : %d"):format(stats.skipped)) end
        if stats.dlSlow    > 0 then print(("  Slow downloads : %d"):format(stats.dlSlow)) end
        if stats.dlFailed  > 0 then print(("  Failed downloads: %d"):format(stats.dlFailed)) end
        if stats.audioStalls > 0 then print(("  Audio stalls   : %d"):format(stats.audioStalls)) end
        if stats.audioFailed   then print("  Audio          : FAILED to fetch") end
    end
    -- Clean up any leftover buffered frames (downloaded but not yet rendered)
    local mediaDir = "media/"..name
    if fs.exists(mediaDir) then fs.delete(mediaDir) end
    os.sleep(2)
end

-- Read one char from terminal, also dispatching rednet messages to handler.
-- If handler(senderID, msg) returns non-nil, that value is returned immediately
-- (used to inject remote commands into the menu as if the user typed them).
local function readChar(handler)
    while true do
        local ev = {os.pullEvent()}
        if ev[1] == "char" then
            return ev[2]
        elseif ev[1] == "key" and ev[2] == keys.enter then
            return "\n"
        elseif ev[1] == "rednet_message" then
            local senderID, msg, protocol = ev[2], ev[3], ev[4]
            if protocol == REMOTE_PROTOCOL and handler then
                local r = handler(senderID, msg)
                if r ~= nil then return r end
            end
        end
    end
end

local function drawMenu(title, items, handler)
    term.clear(); term.setCursorPos(1,1)
    print("=================================")
    print("  CC:T Media Player  |  "..title)
    print("=================================")
    if #items == 0 then print("  (none available)")
    else for i, n in ipairs(items) do print(("  %d. %s"):format(i, n)) end end
    print("---------------------------------"); print("  0. Back"); print()
    io.write("Select: ")
    local inp = readChar(handler)
    if inp == "\1" then return "\1" end  -- remote_play sentinel: pass to caller
    local n = tonumber(inp)
    if not n or n == 0 then return nil end
    return items[n]
end

local function mainMenu(idx, handler)
    while true do
        _playerStatus.state = "menu"
        term.clear(); term.setCursorPos(1,1)
        print("=================================")
        print("  CC:T Media Player")
        print("=================================")
        print(("  1. Videos  (%d available)"):format(#idx.video))
        print(("  2. Audio   (%d available)"):format(#idx.audio))
        if #_playQueue > 0 then
            print(("  3. Queue   (%d item(s) pending)"):format(#_playQueue))
        end
        print("---------------------------------")
        print("  R. Refresh    Q. Quit"); print()
        io.write("Choice: ")
        local inp = readChar(handler)
        if inp == "\1" then return "remote_play", nil end
        inp = inp:lower()
        if inp == "1" then
            if #idx.video == 0 then print("No videos yet."); os.sleep(1)
            else
                local p = drawMenu("Videos", idx.video, handler)
                if p == "\1" then return "remote_play", nil end
                if p then return "play", p end
            end
        elseif inp == "2" then
            if #idx.audio == 0 then print("No audio yet."); os.sleep(1)
            else
                local p = drawMenu("Audio", idx.audio, handler)
                if p == "\1" then return "remote_play", nil end
                if p then return "play", p end
            end
        elseif inp == "3" and #_playQueue > 0 then
            term.clear(); term.setCursorPos(1,1)
            print("=================================")
            print("  Play Queue")
            print("=================================")
            for i, item in ipairs(_playQueue) do
                print(("  %d. %s"):format(i, item.name))
            end
            print("---------------------------------")
            print("  C. Clear queue   0. Back"); print()
            io.write("Choice: ")
            local qi = readChar(handler)
            if qi == "\1" then return "remote_play", nil end
            if qi:lower() == "c" then _playQueue = {} end
        elseif inp == "r" then return "refresh", nil
        elseif inp == "q" then return "quit", nil end
    end
end

local function main()
    term.clear(); term.setCursorPos(1,1)
    print("=== CC:Tweaked Media Player ==="); print()
    selfUpdate()
    -- Prompt for server URL (Cloudflare tunnel or leave blank for GitHub)
    print("[player] Enter server URL (blank = use GitHub):")
    io.write("URL: ")
    local _inp = io.read()
    if _inp and _inp:match("^https?://") then
        BASE_URL = _inp:gsub("/$", "")
        io.write("[player] Testing connection... ")
        local _ok, _err = pcall(function()
            local _r = http.get(BASE_URL .. "/output/index.lua")
            if _r then _r.close() else error("fail") end
        end)
        if _ok then print("OK")
        else print("FAILED — falling back to GitHub."); BASE_URL = GITHUB_RAW end
    else
        print("[player] Using GitHub.")
    end
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
    -- Open wireless modems for remote control (kept open for entire session)
    for _, side in ipairs(peripheral.getNames()) do
        local m = peripheral.wrap(side)
        if m and m.isWireless and m.isWireless() then
            pcall(rednet.open, side)
            _remoteOpen = true
        end
    end
    if _remoteOpen then
        print(("[remote] Wireless remote enabled. Player ID: %d"):format(os.getComputerID()))
        print("[remote] Run remote.lua on a pocket computer with wireless modem.")
    end
    local idx = loadIndex()
    _playerIndex = idx  -- expose to remote queries during playback

    -- Remote command handler used while player is at the menu
    local handleMenuRemote
    handleMenuRemote = function(senderID, msg)
        if type(msg) ~= "table" then return nil end
        local cmd = msg.cmd
        if cmd == "status" then
            rednet.send(senderID, {
                cmd="status_reply", state="menu",
                queue=#_playQueue, queue_list=_playQueue,
            }, REMOTE_PROTOCOL)
        elseif cmd == "list" then
            rednet.send(senderID, {
                cmd="list_reply", videos=idx.video, audio=idx.audio,
            }, REMOTE_PROTOCOL)
        elseif cmd == "play_now" and type(msg.name)=="string" then
            table.insert(_playQueue, 1, {name=msg.name, action=msg.action or "play"})
            rednet.send(senderID, {cmd="ok"}, REMOTE_PROTOCOL)
            return "\1"  -- sentinel: causes readChar to return it, triggering remote_play
        elseif cmd == "queue_add" and type(msg.name)=="string" then
            table.insert(_playQueue, {name=msg.name, action=msg.action or "play"})
            rednet.send(senderID, {cmd="ok", queue=#_playQueue}, REMOTE_PROTOCOL)
        elseif cmd == "queue_list" then
            rednet.send(senderID, {cmd="queue_reply", queue=_playQueue}, REMOTE_PROTOCOL)
        elseif cmd == "queue_clear" then
            _playQueue = {}
            rednet.send(senderID, {cmd="ok"}, REMOTE_PROTOCOL)
        end
        return nil
    end

    -- Helper: execute a play action (shared by local menu and queue drain)
    local function playWithAction(name, manifest, action)
        if action == "predownload" then
            preDownload(name, manifest)
            playMedia(mon, speakers, name, manifest, nil)
        elseif action == "upload_play" then
            local store = initStore()
            if store then
                uploadToNetwork(name, manifest, store)
                playMedia(mon, speakers, name, manifest, store)
            else
                print("[error] Could not connect to storage network."); os.sleep(1)
            end
        elseif action == "network_play" then
            local store = initStore()
            if store then
                playMedia(mon, speakers, name, manifest, store)
            else
                print("[error] Could not connect to storage network."); os.sleep(1)
            end
        else  -- "play" or any default: stream
            playMedia(mon, speakers, name, manifest, nil)
        end
    end

    while true do
        -- Drain play queue before showing menu (filled by remote or local queue viewer)
        while #_playQueue > 0 do
            local item = table.remove(_playQueue, 1)
            local ok, manifest = pcall(loadManifest, item.name)
            if ok then
                playWithAction(item.name, manifest, item.action or "play")
            else
                print("[error] Could not load '"..tostring(item.name).."': "..tostring(manifest))
                os.sleep(1)
            end
        end

        local action, pick = mainMenu(idx, handleMenuRemote)

        if action == "quit" then
            term.clear(); term.setCursorPos(1,1); print("Goodbye!"); return
        elseif action == "refresh" then
            print("Refreshing..."); idx = loadIndex(); _playerIndex = idx; print("Done."); os.sleep(0.5)
        elseif action == "remote_play" then
            -- _playQueue updated by handleMenuRemote; drain at top of loop
        elseif action == "play" and pick then
            local ok, manifest = pcall(loadManifest, pick)
            if not ok then
                print("[error] "..tostring(manifest)); os.sleep(1)
            else
                local subaction = mediaActionMenu(pick, handleMenuRemote)
                if subaction == "remote_play" then
                    -- Remote sent play_now while user was in action menu; queue drains next iteration
                elseif subaction then
                    playWithAction(pick, manifest, subaction)
                end
            end
        end
    end
end

main()