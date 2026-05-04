-- CC:Tweaked Storage Client
-- Standalone tool to pre-load videos onto storage node computers and play
-- them back at full speed without downloading from GitHub during playback.
--
-- Setup:
--   1. Connect storage node computers via Wired Modem + Networking Cable
--   2. Run  storage_server.lua  on each node (set as startup)
--   3. Run  lua storage_client.lua  on the player computer
--
-- The more nodes you attach, the more storage you have (1MB per computer).

local GITHUB_RAW = "https://raw.githubusercontent.com/ob-105/CC-tweaked-Audio-video-playback./main"
local PROTOCOL   = "cct-media-store"
local TIMEOUT    = 3  -- seconds to wait for node responses

-- ── Modem setup ────────────────────────────────────────────────────────────
local function openModems()
    local opened = 0
    for _, side in ipairs(peripheral.getNames()) do
        if peripheral.getType(side) == "modem" then
            pcall(rednet.open, side)
            opened = opened + 1
        end
    end
    return opened
end

-- ── Node discovery ─────────────────────────────────────────────────────────
local function discoverNodes()
    rednet.broadcast({cmd="ping"}, PROTOCOL)
    local nodes = {}
    local deadline = os.clock() + TIMEOUT
    while os.clock() < deadline do
        local sender, msg = rednet.receive(PROTOCOL, deadline - os.clock())
        if sender and type(msg) == "table" and msg.ok then
            nodes[#nodes+1] = {
                id    = sender,
                label = msg.label or ("node-"..sender),
                free  = msg.free  or 0,
                cap   = msg.cap   or 0,
            }
        end
    end
    return nodes
end

-- ── RPC helpers ────────────────────────────────────────────────────────────
local function rpc(nodeId, req, timeout)
    timeout = timeout or TIMEOUT
    rednet.send(nodeId, req, PROTOCOL)
    local sender, resp = rednet.receive(PROTOCOL, timeout)
    if sender == nodeId and type(resp) == "table" then return resp end
    return nil
end

local function wipeNodes(nodes)
    print("Wiping all nodes...")
    for _, n in ipairs(nodes) do
        local r = rpc(n.id, {cmd="wipe"})
        if r then
            print(("  %s: freed %dKB"):format(n.label, math.floor((r.free or 0)/1024)))
        end
    end
end

-- ── Index loading ──────────────────────────────────────────────────────────
local function loadIndex()
    local res = http.get(GITHUB_RAW.."/output/index.lua")
    if not res then error("Could not fetch index from GitHub") end
    local data = res.readAll(); res.close()
    local f = fs.open("sc_index_tmp.lua", "w"); f.write(data); f.close()
    local fn = loadfile("sc_index_tmp.lua")
    fs.delete("sc_index_tmp.lua")
    if not fn then error("Could not parse index") end
    local ok, r = pcall(fn)
    if not ok or type(r) ~= "table" then return {video={}, audio={}} end
    r.video = r.video or {}; r.audio = r.audio or {}
    return r
end

local function loadManifest(name)
    local url = GITHUB_RAW.."/output/"..name.."/manifest.lua"
    local res = http.get(url)
    if not res then error("Could not fetch manifest for "..name) end
    local data = res.readAll(); res.close()
    local f = fs.open("sc_manifest_tmp.lua", "w"); f.write(data); f.close()
    local fn = loadfile("sc_manifest_tmp.lua")
    fs.delete("sc_manifest_tmp.lua")
    if not fn then error("Bad manifest") end
    return fn()
end

-- ── Distribute a file to the least-full node ───────────────────────────────
local function putFile(nodes, path, data)
    -- pick node with most free space
    table.sort(nodes, function(a,b) return a.free > b.free end)
    for _, n in ipairs(nodes) do
        if n.free > #data + 2048 then
            local r = rpc(n.id, {cmd="put", path=path, data=data}, 5)
            if r and r.ok then
                n.free = r.free or n.free
                return n.label
            end
        end
    end
    return nil  -- no space
end

-- ── Pre-load a video onto the storage network ──────────────────────────────
local function loadVideo(name, manifest, nodes)
    local count  = manifest.frame_count or 0
    local fext   = manifest.frame_ext or "nfp"
    local audio  = manifest.has_audio == "true"
    print(("[loader] Pre-loading '%s'  frames=%d  ext=%s"):format(name, count, fext))

    -- Audio
    if audio then
        io.write("  Downloading audio... ")
        local res = http.get(GITHUB_RAW.."/output/"..name.."/audio.dfpwm", nil, true)
        if res then
            local data = res.readAll(); res.close()
            local node = putFile(nodes, name.."/audio.dfpwm", data)
            if node then print("stored on "..node)
            else print("FAILED (no space)") end
        else print("FAILED (download)") end
    end

    -- Frames
    local stored = 0; local skipped = 0
    for i = 1, count do
        local fname = ("%06d.%s"):format(i, fext)
        local url   = GITHUB_RAW.."/output/"..name.."/frames/"..fname
        local res   = http.get(url)
        if res then
            local data = res.readAll(); res.close()
            local node = putFile(nodes, name.."/frames/"..fname, data)
            if node then stored = stored + 1
            else skipped = skipped + 1; break end
        else skipped = skipped + 1 end
        if i % 20 == 0 or i == count then
            io.write(("\r  Frames: %d/%d stored, %d skipped  "):format(stored, count, skipped))
        end
    end
    print(("\n  Done. Stored %d/%d frames across %d node(s)."):format(stored, count, #nodes))
    return stored
end

-- ── Playback from storage network ──────────────────────────────────────────
local BLIT = "0123456789abcdef"
local function renderLines(mon, lines)
    local nh = #lines; if nh == 0 then return end
    local nw = #lines[1]; if nw == 0 then return end
    local mw, mh = mon.getSize()
    for row = 1, mh do
        local srcRow = math.max(1, math.min(nh, math.ceil(row * nh / mh)))
        local line   = lines[srcRow]
        for col = 1, mw do
            local srcCol = math.max(1, math.min(nw, math.ceil(col * nw / mw)))
            local c = line:sub(srcCol, srcCol)
            local ci = BLIT:find(c, 1, true)
            if ci then local bc = BLIT:sub(ci,ci); mon.setCursorPos(col,row); mon.blit(" ",bc,bc) end
        end
    end
end

local function decodeNFP(data)
    local lines = {}
    for line in (data.."\n"):gmatch("([^\n]*)\n") do lines[#lines+1] = line end
    return lines
end

local function decodeNFPC(data)
    local lines = {}
    for rowstr in (data.."\n"):gmatch("([^\n]*)\n") do
        local line = ""
        for run in (rowstr.."|"):gmatch("([^|]*)|") do
            local c, n = run:match("^(.):(%d+)$")
            if c and n then line = line .. c:rep(tonumber(n)) end
        end
        lines[#lines+1] = line
    end
    return lines
end

local function getFrame(nodes, name, fext, i)
    local path = name.."/frames/"..("%06d.%s"):format(i, fext)
    -- ask nodes in round-robin until one has it
    for _, n in ipairs(nodes) do
        local r = rpc(n.id, {cmd="get", path=path}, 2)
        if r and r.ok and r.data then return r.data end
    end
    return nil
end

local function playFromNetwork(name, manifest, nodes)
    local fps    = manifest.fps or 5
    local count  = manifest.frame_count or 0
    local fext   = manifest.frame_ext or "nfp"
    local audio  = manifest.has_audio == "true"
    local mon    = peripheral.find("monitor")
    if mon then mon.setTextScale(0.5) end

    local speakers = {peripheral.find("speaker")}
    print(("[player] monitor=%s  speakers=%d"):format(tostring(mon~=nil), #speakers))

    -- Audio coroutine: fetch audio from nodes and stream to speakers
    local function audioLoop()
        if not audio or #speakers == 0 then return end
        local path = name.."/audio.dfpwm"
        local data = nil
        for _, n in ipairs(nodes) do
            local r = rpc(n.id, {cmd="get", path=path}, 5)
            if r and r.ok and r.data then data = r.data; break end
        end
        if not data then print("[player] Audio not found on network."); return end
        -- write to tmp file and stream
        local tmp = "sc_audio_tmp.dfpwm"
        local f = fs.open(tmp, "wb"); f.write(data); f.close()
        local dfpwm = require("cc.audio.dfpwm")
        local decoder = dfpwm.make_decoder()
        local fh = fs.open(tmp, "rb")
        while true do
            local chunk = fh.read(16384)
            if not chunk then break end
            local pcm = decoder(chunk)
            local busy = true
            while busy do
                busy = false
                for _, spk in ipairs(speakers) do
                    if not spk.playAudio(pcm) then busy = true end
                end
                if busy then os.pullEvent("speaker_audio_empty") end
            end
        end
        fh.close(); fs.delete(tmp)
    end

    local t0 = os.clock(); local skipped = 0
    local function videoLoop()
        for frame = 1, count do
            local due     = (frame - 1) / fps
            local elapsed = os.clock() - t0
            local data    = getFrame(nodes, name, fext, frame)
            if elapsed <= due + (1/fps) then
                local wait = due - elapsed
                if wait > 0 then os.sleep(wait) end
                if data and mon then
                    local lines = (fext == "nfpc") and decodeNFPC(data) or decodeNFP(data)
                    renderLines(mon, lines)
                end
            else
                skipped = skipped + 1
            end
        end
        if skipped > 0 then print(("[player] Skipped %d frame(s)."):format(skipped)) end
    end

    print(("[player] Playing '%s' from storage network..."):format(name))
    if audio and count > 0 then parallel.waitForAll(audioLoop, videoLoop)
    elseif audio then audioLoop()
    elseif count > 0 then videoLoop() end
    print("\n[player] Done. Press Enter..."); io.read()
end

-- ── Menus ───────────────────────────────────────────────────────────────────
local function drawMenu(title, items)
    term.clear(); term.setCursorPos(1,1)
    print("===========================")
    print("  Storage Client | "..title)
    print("===========================")
    if #items == 0 then print("  (none)") end
    for i, item in ipairs(items) do
        if type(item) == "table" then
            print(("  %d. %s  [free: %dKB]"):format(i, item.label, math.floor(item.free/1024)))
        else
            print(("  %d. %s"):format(i, item))
        end
    end
    print("---------------------------"); print("  0. Back"); print()
    io.write("Select: ")
    local n = tonumber(io.read())
    if not n or n == 0 then return nil end
    return items[n]
end

-- ── Main ───────────────────────────────────────────────────────────────────
local function main()
    term.clear(); term.setCursorPos(1,1)
    print("=== CC:T Storage Client ==="); print()
    if openModems() == 0 then print("No modem found! Attach a wired modem."); return end

    print("Discovering storage nodes...")
    local nodes = discoverNodes()
    if #nodes == 0 then
        print("No storage nodes found.")
        print("Make sure storage_server.lua is running on connected computers.")
        return
    end
    local totalFree = 0
    for _, n in ipairs(nodes) do totalFree = totalFree + n.free end
    print(("Found %d node(s), %dKB total free."):format(#nodes, math.floor(totalFree/1024)))
    print()

    while true do
        term.clear(); term.setCursorPos(1,1)
        print("=== Storage Client ===")
        print(("  Nodes: %d  |  Free: %dKB"):format(#nodes, math.floor(totalFree/1024)))
        print("======================")
        print("  1. Pre-load video onto network")
        print("  2. Play video from network")
        print("  3. Wipe all nodes")
        print("  4. Rescan nodes")
        print("  Q. Quit"); print()
        io.write("Choice: ")
        local inp = (io.read() or ""):lower()

        if inp == "q" then return

        elseif inp == "1" then
            print("Fetching index from GitHub...")
            local ok, idx = pcall(loadIndex)
            if not ok then print("Error: "..tostring(idx)); io.read(); goto continue end
            if #idx.video == 0 then print("No videos in index."); os.sleep(1); goto continue end
            local pick = drawMenu("Choose video to load", idx.video)
            if pick then
                local ok2, manifest = pcall(loadManifest, pick)
                if not ok2 then print("Error: "..tostring(manifest)); io.read()
                else
                    loadVideo(pick, manifest, nodes)
                    totalFree = 0
                    for _, n in ipairs(nodes) do totalFree = totalFree + n.free end
                end
            end

        elseif inp == "2" then
            print("Fetching index from GitHub...")
            local ok, idx = pcall(loadIndex)
            if not ok then print("Error: "..tostring(idx)); io.read(); goto continue end
            if #idx.video == 0 then print("No videos."); os.sleep(1); goto continue end
            local pick = drawMenu("Choose video to play", idx.video)
            if pick then
                local ok2, manifest = pcall(loadManifest, pick)
                if not ok2 then print("Error: "..tostring(manifest)); io.read()
                else playFromNetwork(pick, manifest, nodes) end
            end

        elseif inp == "3" then
            io.write("Wipe ALL stored data? (y/n): ")
            if (io.read() or ""):lower() == "y" then
                wipeNodes(nodes)
                totalFree = 0
                for _, n in ipairs(nodes) do totalFree = totalFree + n.free end
            end

        elseif inp == "4" then
            print("Rescanning...")
            nodes = discoverNodes()
            totalFree = 0
            for _, n in ipairs(nodes) do totalFree = totalFree + n.free end
            print(("Found %d node(s), %dKB free."):format(#nodes, math.floor(totalFree/1024)))
            os.sleep(1)
        end
        ::continue::
    end
end

main()
