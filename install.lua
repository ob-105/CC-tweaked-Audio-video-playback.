-- CC:Tweaked Media Player - Bootstrap/Installer
-- Run this ONE time on your CC:T computer to install the player.
--
-- In-game, run:
--   wget https://raw.githubusercontent.com/ob-105/CC-tweaked-Audio-video-playback./main/install.lua install.lua
--   lua install.lua

local GITHUB_RAW = "https://raw.githubusercontent.com/ob-105/CC-tweaked-Audio-video-playback./main"

local FILES = {
    { url = GITHUB_RAW .. "/player.lua", path = "player.lua" },
}

print("=== CC:Tweaked Media Player Installer ===")
print()

for _, file in ipairs(FILES) do
    io.write("Downloading " .. file.path .. "... ")
    local res = http.get(file.url)
    if res then
        local data = res.readAll()
        res.close()
        local f = fs.open(file.path, "w")
        f.write(data)
        f.close()
        print("OK")
    else
        print("FAILED")
        print("Could not reach: " .. file.url)
        print("Make sure HTTP is enabled in ComputerCraft config and the repo is public.")
        return
    end
end

print()
print("Installation complete!")
print("Run the player with:  lua player.lua")
print()

-- Optionally add a startup alias
io.write("Add 'player' shortcut to startup? (y/n): ")
local ans = io.read()
if ans and ans:lower() == "y" then
    local f = fs.open("player", "w")
    f.write('shell.run("player.lua")\n')
    f.close()
    print("Done. You can now type 'player' to launch.")
end
