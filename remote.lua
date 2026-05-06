-- CC:Tweaked Media Remote v2
-- Full wireless remote for the CC:T Media Player.
-- Run on a pocket computer with a wireless modem upgrade.
--
-- From the remote you can:
--   Browse the media library (videos & audio)
--   Play Now  or  Add to Queue
--   View and clear the queue
--   Pause/Resume, Volume Up/Down, Stop
--   All of the above work whether the player is idle OR currently playing.
--
-- Controls depend on current screen — options are always printed on-screen.

local REMOTE_PROTOCOL = "cct-media-ctrl"
local POLL_INTERVAL   = 3  -- seconds between automatic status refreshes

-- ────────────────────────────────────────────────────────────────────────────
-- Open wireless modem
-- ────────────────────────────────────────────────────────────────────────────
local modemSide = nil
for _, name in ipairs(peripheral.getNames()) do
    local m = peripheral.wrap(name)
    if m and m.isWireless and m.isWireless() then modemSide = name; break end
end
if not modemSide then
    for _, s in ipairs({"back","left","right","top","bottom","front"}) do
        if peripheral.getType(s) == "modem" then modemSide = s; break end
    end
end
if not modemSide then
    print("No wireless modem found!")
    print("Attach a wireless modem upgrade to this pocket computer.")
    return
end
rednet.open(modemSide)

-- ────────────────────────────────────────────────────────────────────────────
-- Low-level helpers
-- ────────────────────────────────────────────────────────────────────────────
local function send(playerID, t)
    rednet.send(playerID, t, REMOTE_PROTOCOL)
end

-- Send a message and wait for a matching reply (with timeout)
local function ask(playerID, t, timeout)
    send(playerID, t)
    local deadline = os.clock() + (timeout or 4)
    while os.clock() < deadline do
        local remaining = deadline - os.clock()
        if remaining <= 0 then break end
        local id, msg = rednet.receive(REMOTE_PROTOCOL, remaining)
        if id == playerID and type(msg) == "table" then return msg end
    end
    return nil
end

local function clr() term.clear(); term.setCursorPos(1,1) end
local SEP  = "--------------------------"
local SEP2 = "=========================="
local function header(title)
    print(SEP2)
    print(" "..title)
    print(SEP2)
end

-- Read one char, optionally with a timeout (returns nil on timeout)
local function readCharTimeout(timeout)
    local t = timeout and os.startTimer(timeout)
    while true do
        local ev = {os.pullEvent()}
        if ev[1] == "char" then return ev[2]
        elseif ev[1] == "key" then
            if ev[2] == keys.equals or ev[2] == keys.rightBracket then return "="
            elseif ev[2] == keys.minus then return "-" end
        elseif ev[1] == "timer" and ev[2] == t then return nil end
    end
end

-- ────────────────────────────────────────────────────────────────────────────
-- Connect to player
-- ────────────────────────────────────────────────────────────────────────────
local function connect()
    clr(); header("CC:T Remote - Connect")
    print()
    print("Scanning for player...")
    print("(press any key to type ID)")
    print()
    local timer = os.startTimer(15)
    while true do
        local ev = {os.pullEvent()}
        if ev[1] == "rednet_message" then
            local id, msg, proto = ev[2], ev[3], ev[4]
            if proto == REMOTE_PROTOCOL and type(msg) == "table" then
                if msg.cmd == "player_online" or msg.cmd == "now_playing" then
                    print("Found player ID: "..id)
                    os.sleep(0.5)
                    return id
                end
            end
        elseif ev[1] == "key" or ev[1] == "char" then
            clr(); header("Connect")
            io.write("Player ID: ")
            local s = io.read()
            local n = tonumber(s)
            if n then return n end
            print("Invalid."); os.sleep(1)
            return connect()
        elseif ev[1] == "timer" and ev[2] == timer then
            clr(); header("Connect")
            print("No broadcast found.")
            io.write("Player ID (blank=rescan): ")
            local s = io.read()
            local n = tonumber(s)
            if n then return n end
            return connect()
        end
    end
end

-- ────────────────────────────────────────────────────────────────────────────
-- Status and library fetch
-- ────────────────────────────────────────────────────────────────────────────
local function fetchStatus(playerID)
    local r = ask(playerID, {cmd="status"}, 2)
    if r and r.cmd == "status_reply" then return r end
    return {state="unknown", media=nil, frame=0, count=0, volume=1.0, queue=0}
end

local function fetchLibrary(playerID)
    local r = ask(playerID, {cmd="list"}, 4)
    if r and r.cmd == "list_reply" then
        return r.videos or {}, r.audio or {}
    end
    return {}, {}
end

local function fetchQueue(playerID)
    local r = ask(playerID, {cmd="queue_list"}, 3)
    return (r and r.queue) or {}
end

-- ────────────────────────────────────────────────────────────────────────────
-- Status bar (drawn at top of every main screen)
-- ────────────────────────────────────────────────────────────────────────────
local function statusBar(status)
    local st   = status.state or "?"
    local med  = (status.media or "-"):sub(1, 14)
    local icon = st=="playing" and "\16" or st=="paused" and "||" or "--"
    local pct  = 0
    if (status.count or 0) > 0 then
        pct = math.floor((status.frame or 0) * 100 / status.count)
    end
    -- Two lines, each <=26 chars
    print((" %s %-14s %3d%%"):format(icon, med, pct))
    print((" Vol:%.1f  Q:%d"):format(status.volume or 1.0, status.queue or 0))
end

-- ────────────────────────────────────────────────────────────────────────────
-- Browse list (paginated)
-- Returns selected item name, or nil for back
-- ────────────────────────────────────────────────────────────────────────────
local function browseList(title, items, playerID, status)
    if #items == 0 then
        clr(); header(title); print(" (nothing here yet)")
        print(); print("Press any key..."); readCharTimeout(10); return nil
    end
    local PAGE = 6
    local page = 1
    while true do
        clr(); header(title)
        statusBar(status)
        print(SEP)
        local s = (page-1)*PAGE+1
        local e = math.min(s+PAGE-1, #items)
        for i = s, e do
            -- truncate name to 22 chars so "N. " prefix fits in 26
            local label = items[i]:sub(1,22)
            print((" %d. %s"):format(i-s+1, label))
        end
        print(SEP)
        local pages = math.ceil(#items/PAGE)
        if pages > 1 then
            print((" N=Next B=Prev %d/%d"):format(page,pages))
        end
        print(" 0=Back")
        print(); io.write("Select: ")
        local c = readCharTimeout(30)
        if not c or c == "0" then return nil
        elseif c:lower() == "n" and page < pages then page = page+1
        elseif c:lower() == "b" and page > 1 then page = page-1
        else
            local n = tonumber(c)
            if n and n >= 1 and n <= (e-s+1) then return items[s+n-1] end
        end
    end
end

-- ────────────────────────────────────────────────────────────────────────────
-- Item action (play now / queue)
-- ────────────────────────────────────────────────────────────────────────────
local function itemAction(name, playerID)
    clr(); header(name:sub(1,24))
    print()
    print(" 1. Play Now")
    print(" 2. Add to Queue")
    print(" 0. Back")
    print(); io.write("Choice: ")
    local c = readCharTimeout(20)
    if c == "1" then
        local r = ask(playerID, {cmd="play_now", name=name, action="play"}, 3)
        print(); print(r and "Play Now sent!" or "No response."); os.sleep(0.8)
        return true
    elseif c == "2" then
        local r = ask(playerID, {cmd="queue_add", name=name, action="play"}, 3)
        print(); print(r and ("Queued. Q:"..tostring(r.queue or "?")) or "No response."); os.sleep(0.8)
    end
    return false
end

-- ────────────────────────────────────────────────────────────────────────────
-- Queue viewer
-- ────────────────────────────────────────────────────────────────────────────
local function queueScreen(playerID, status)
    while true do
        clr(); header("Queue")
        statusBar(status)
        print(SEP)
        local q = fetchQueue(playerID)
        if #q == 0 then print(" (empty)")
        else
            for i, item in ipairs(q) do
                print((" %d. %s"):format(i, item.name:sub(1,22)))
            end
        end
        print(SEP)
        print(" C=Clear  0=Back")
        print(); io.write("Choice: ")
        local c = readCharTimeout(20)
        if not c or c == "0" then return
        elseif c:lower() == "c" then
            send(playerID, {cmd="queue_clear"})
            print("Queue cleared."); os.sleep(0.6)
        end
    end
end

-- ────────────────────────────────────────────────────────────────────────────
-- Main remote loop
-- ────────────────────────────────────────────────────────────────────────────
local function remoteMain(playerID)
    local status   = fetchStatus(playerID)
    local videos   = {}
    local audio    = {}
    videos, audio  = fetchLibrary(playerID)

    local function refresh()
        status = fetchStatus(playerID)
    end

    while true do
        local playing = status.state == "playing" or status.state == "paused"

        clr(); header("Remote ID:"..playerID)
        statusBar(status)
        print(SEP2)
        print(" 1. Videos")
        print(" 2. Audio")
        print(" 3. Queue")
        print(" 4. Refresh library")
        print(SEP)
        if playing then
            print(" P=Pause  S=Stop")
            print(" +=Vol+  -=Vol-")
        end
        print(" R=Refresh  Q=Quit")
        print(); io.write("Choice: ")

        -- Wait for input; auto-refresh status after POLL_INTERVAL
        local c = readCharTimeout(POLL_INTERVAL)
        if c == nil then
            -- Timer fired: auto-refresh status silently
            refresh()
        elseif c == "1" then
            local pick = browseList("Videos", videos, playerID, status)
            if pick then
                local done = itemAction(pick, playerID)
                if done then refresh() end
            end
        elseif c == "2" then
            local pick = browseList("Audio", audio, playerID, status)
            if pick then
                local done = itemAction(pick, playerID)
                if done then refresh() end
            end
        elseif c == "3" then
            queueScreen(playerID, status)
            refresh()
        elseif c == "4" then
            clr(); header("Fetching library...")
            videos, audio = fetchLibrary(playerID)
            refresh()
            print(("Videos: %d  Audio: %d"):format(#videos, #audio)); os.sleep(0.8)
        elseif c:lower() == "p" and playing then
            send(playerID, {cmd="toggle_pause"}); refresh()
        elseif c == "=" and playing then
            send(playerID, {cmd="vol_up"}); refresh()
        elseif c == "-" and playing then
            send(playerID, {cmd="vol_down"}); refresh()
        elseif c:lower() == "s" and playing then
            send(playerID, {cmd="stop"})
            print("Stop sent."); os.sleep(0.6); refresh()
        elseif c:lower() == "r" then
            refresh()
        elseif c:lower() == "q" then
            print("Disconnecting..."); os.sleep(0.4); break
        end
    end
end

-- ────────────────────────────────────────────────────────────────────────────
-- Entry point
-- ────────────────────────────────────────────────────────────────────────────
local playerID = connect()
if playerID then
    -- Broadcast our presence so player knows a remote is connected
    rednet.broadcast({cmd="remote_connected"}, REMOTE_PROTOCOL)
    remoteMain(playerID)
end
rednet.close(modemSide)
print("Remote closed.")

-- Controls:
--   P   = Pause / Resume
--   +   = Volume Up  (0.0 → 3.0 in 0.2 steps)
--   -   = Volume Down
--   Q   = Stop the player and return to its menu
--   R   = Reconnect (look for a new player broadcast)

local REMOTE_PROTOCOL = "cct-media-ctrl"
local SCAN_TIMEOUT    = 20  -- seconds to wait for a player announcement

-- ---------------------------------------------------------------------------
-- Find and open any wireless modem
-- ---------------------------------------------------------------------------
local modemSide = nil
for _, name in ipairs(peripheral.getNames()) do
    local m = peripheral.wrap(name)
    if m and m.isWireless and m.isWireless() then
        modemSide = name; break
    end
end
if not modemSide then
    -- Fallback: check cardinal sides
    for _, side in ipairs({"back","left","right","top","bottom","front"}) do
        if peripheral.getType(side) == "modem" then
            modemSide = side; break
        end
    end
end
if not modemSide then
    print("No wireless modem found!")
    print("Attach a wireless modem upgrade to the pocket computer.")
    return
end

rednet.open(modemSide)

-- ---------------------------------------------------------------------------
-- Wait for player announcement
-- ---------------------------------------------------------------------------
local function scanForPlayer()
    term.clear(); term.setCursorPos(1,1)
    print("=== CC:T Media Remote ===")
    print()
    print("Scanning for player...")
    print(("(waiting up to %ds)"):format(SCAN_TIMEOUT))
    local id, msg, protocol = rednet.receive(REMOTE_PROTOCOL, SCAN_TIMEOUT)
    if id and type(msg) == "table" and msg.cmd == "announce" then
        return id, tostring(msg.media)
    end
    return nil, nil
end

local playerID, mediaName = scanForPlayer()
if not playerID then
    print()
    print("No player found.")
    print("Make sure the player is running and a")
    print("wireless modem is attached to the player computer.")
    rednet.close(modemSide)
    return
end

-- ---------------------------------------------------------------------------
-- Main remote UI
-- ---------------------------------------------------------------------------
local function send(cmd)
    rednet.send(playerID, {cmd = cmd}, REMOTE_PROTOCOL)
end

while true do
    term.clear(); term.setCursorPos(1,1)
    print("=========================")
    print("  CC:T Media Remote")
    print("=========================")
    print()
    print(("Player ID : %d"):format(playerID))
    print(("Now playing: %s"):format(mediaName))
    print()
    print("  [P]  Pause / Resume")
    print("  [=]  Volume Up")
    print("  [-]  Volume Down")
    print("  [Q]  Stop player")
    print("  [R]  Reconnect")
    print()
    print("=========================")

    local _, key = os.pullEvent("key")

    if key == keys.p then
        send("toggle_pause")
    elseif key == keys.equals then   -- = / + key (no shift needed)
        send("vol_up")
    elseif key == keys.minus then
        send("vol_down")
    elseif key == keys.q then
        send("stop")
        print("Stopped player. Closing remote.")
        os.sleep(1)
        break
    elseif key == keys.r then
        playerID, mediaName = scanForPlayer()
        if not playerID then
            print("No player found. Exiting.")
            os.sleep(2)
            break
        end
    end
end

rednet.close(modemSide)
