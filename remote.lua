-- CC:Tweaked Media Remote
-- Run this on a wireless pocket computer (with a wireless modem upgrade).
-- The media player broadcasts its ID when it starts; the remote picks it up
-- and lets you control playback wirelessly.
--
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
