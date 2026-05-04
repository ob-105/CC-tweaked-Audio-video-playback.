-- CC:Tweaked Storage Server Node
-- Drop this on any computer connected to the player via wired modem + cables.
-- Set it as startup.lua or run manually: lua storage_server.lua
-- Each computer provides ~1MB of frame storage.

local PROTOCOL = "cct-media-store"

-- Open every modem we can find
local opened = 0
for _, side in ipairs(peripheral.getNames()) do
    if peripheral.getType(side) == "modem" then
        pcall(rednet.open, side)
        opened = opened + 1
    end
end
if opened == 0 then error("No modem found! Attach a wired modem and connect cables.") end

local ID    = os.getComputerID()
local LABEL = os.getComputerLabel() or ("node-"..ID)
os.setComputerLabel(LABEL)

term.clear(); term.setCursorPos(1,1)
print("=== CC:T Storage Node ===")
print("ID:    "..ID)
print("Label: "..LABEL)
print("Free:  "..math.floor(fs.getFreeSpace("/")/1024).."KB / "..math.floor(fs.getCapacity("/")/1024).."KB")
print("========================")
print("Listening for requests...")

local function walk(dir, results)
    if not fs.exists(dir) then return end
    for _, name in ipairs(fs.list(dir)) do
        local p = dir.."/"..name
        if fs.isDir(p) then walk(p, results)
        else results[#results+1] = p:sub(#"store/"+1) end
    end
end

local function handle(sender, msg)
    local cmd = msg.cmd

    if cmd == "ping" then
        rednet.send(sender, {
            ok    = true,
            id    = ID,
            label = LABEL,
            free  = fs.getFreeSpace("/"),
            cap   = fs.getCapacity("/"),
        }, PROTOCOL)

    elseif cmd == "put" then
        local path = "store/"..(msg.path or "")
        local dir  = path:match("^(.*)/[^/]+$")
        if dir and dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
        local f, err = fs.open(path, "w")
        if not f then
            rednet.send(sender, {ok=false, err=tostring(err)}, PROTOCOL)
            return
        end
        f.write(msg.data); f.close()
        rednet.send(sender, {ok=true, free=fs.getFreeSpace("/")}, PROTOCOL)

    elseif cmd == "get" then
        local path = "store/"..(msg.path or "")
        if not fs.exists(path) then
            rednet.send(sender, {ok=false}, PROTOCOL)
            return
        end
        local f = fs.open(path, "r")
        local data = f.readAll(); f.close()
        rednet.send(sender, {ok=true, data=data}, PROTOCOL)

    elseif cmd == "has" then
        rednet.send(sender, {ok=fs.exists("store/"..(msg.path or ""))}, PROTOCOL)

    elseif cmd == "delete" then
        local path = "store/"..(msg.path or "")
        if fs.exists(path) then fs.delete(path) end
        rednet.send(sender, {ok=true, free=fs.getFreeSpace("/")}, PROTOCOL)

    elseif cmd == "wipe" then
        if fs.exists("store") then fs.delete("store") end
        print("[store] Wiped all stored frames.")
        rednet.send(sender, {ok=true, free=fs.getFreeSpace("/")}, PROTOCOL)

    elseif cmd == "list" then
        local results = {}
        walk("store", results)
        rednet.send(sender, {ok=true, files=results}, PROTOCOL)

    elseif cmd == "free" then
        rednet.send(sender, {ok=true, free=fs.getFreeSpace("/")}, PROTOCOL)
    end
end

-- Main loop
while true do
    local ok, err = pcall(function()
        local sender, msg = rednet.receive(PROTOCOL)
        if type(msg) == "table" then
            handle(sender, msg)
        end
    end)
    if not ok then
        print("[store] Error: "..tostring(err))
    end
end
