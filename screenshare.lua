-- screenshare.lua
-- CC:Tweaked Screen Mirror — displays your PC screen on a CC:T monitor.
-- Run screenshare.py on your PC first, then run this script.
--
-- Controls: Ctrl+T (or just terminate) to quit.

local HALF = "\x8f"  -- ▄ half-block character

-- ─────────────────────────────────────────────────────────────────
-- Find a monitor
-- ─────────────────────────────────────────────────────────────────
local mon = nil
for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "monitor" then
        mon = peripheral.wrap(name); break
    end
end
if not mon then
    print("No monitor found!")
    print("Attach a monitor and re-run.")
    return
end

mon.setTextScale(0.5)
local mW, mH = mon.getSize()

-- ─────────────────────────────────────────────────────────────────
-- Get server URL
-- ─────────────────────────────────────────────────────────────────
term.clear(); term.setCursorPos(1, 1)
print("=== CC:T Screen Share ===")
print()
print("Monitor: " .. mW .. " cols x " .. mH .. " rows")
print("Pixels:  " .. mW .. " x " .. (mH*2) .. " (half-block)")
print()
print("In server.py:")
print("  1. Server tab -> Start Server")
print("  2. Screen Share tab -> Start")
print("  3. Copy the URL shown there")
print()
io.write("URL: ")
local BASE = io.read()
if not BASE or BASE:match("^%s*$") then
    print("No URL entered."); return
end
BASE = BASE:gsub("%s+", ""):gsub("/$", "")

print("Connecting to " .. BASE .. " ...")

-- ─────────────────────────────────────────────────────────────────
-- Pre-build reusable blit text string (▄ repeated mW times)
-- NFP format: each row = mW hex chars, one char per pixel
-- CC:T blit() fg/bg strings are directly the NFP hex chars!
-- ─────────────────────────────────────────────────────────────────
local BLIT_TEXT  = HALF:rep(mW)
local BLACK_LINE = ("f"):rep(mW)   -- all-black fallback line

-- ─────────────────────────────────────────────────────────────────
-- Render one NFP frame onto the monitor
-- data: string of (W hex chars + \n) × H
-- ─────────────────────────────────────────────────────────────────
local function renderFrame(data)
    -- Split into rows
    local rows = {}
    for line in (data .. "\n"):gmatch("([^\n]*)\n") do
        rows[#rows + 1] = line
    end

    for y = 1, mH do
        -- top half of character = foreground color
        -- bottom half            = background color
        local fg = rows[y * 2 - 1] or BLACK_LINE
        local bg = rows[y * 2]     or BLACK_LINE

        -- Pad to mW if server resolution doesn't exactly match
        if #fg < mW then fg = fg .. BLACK_LINE:sub(1, mW - #fg) end
        if #bg < mW then bg = bg .. BLACK_LINE:sub(1, mW - #bg) end

        mon.setCursorPos(1, y)
        mon.blit(BLIT_TEXT, fg:sub(1, mW), bg:sub(1, mW))
    end
end

-- ─────────────────────────────────────────────────────────────────
-- Main loop
-- ─────────────────────────────────────────────────────────────────
local frameCount = 0
local startTime  = os.epoch("utc")
local lastFPS    = -1
local errors     = 0
local URL        = BASE .. "/screenshare/frame"

while true do
    local res, err = http.get(URL)
    if res then
        local data = res.readAll()
        res.close()
        errors = 0

        if #data > 0 then
            renderFrame(data)
            frameCount = frameCount + 1

            -- Update FPS on terminal (don't spam every frame)
            local elapsed = (os.epoch("utc") - startTime) / 1000.0
            if elapsed > 0 then
                local fps = frameCount / elapsed
                if math.abs(fps - lastFPS) >= 0.2 then
                    lastFPS = fps
                    term.setCursorPos(1, 1); term.clearLine()
                    io.write(("FPS: %.1f  Frames: %d"):format(fps, frameCount))
                end
            end
        end
    else
        errors = errors + 1
        term.setCursorPos(1, 1); term.clearLine()
        io.write("Error #" .. errors .. ": " .. tostring(err or "unknown"))
        os.sleep(1)
        if errors >= 10 then
            print()
            print("URL: " .. URL)
            print("Too many errors. Check server.")
            print("Press any key to retry.")
            os.pullEvent("key")
            errors = 0
            frameCount = 0
            startTime  = os.epoch("utc")
        end
    end
end
