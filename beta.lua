
local Player = game.Players.LocalPlayer
local PlaceId = game.PlaceId


local Scripts = {
    [12991635726] = "https://raw.githubusercontent.com/Sakuras-Hub/Script-Hub/refs/heads/main/Beta-SRS.lua",
    [16018721946] = "https://raw.githubusercontent.com/Sakuras-Hub/Script-Hub/refs/heads/main/BETA-Siper.lua",
	  [17321021033] = "https://raw.githubusercontent.com/Sakuras-Hub/Script-Hub/refs/heads/main/BETA-Siper.lua",
}

if Scripts[PlaceId] then
    print("Script found for this game, loading...")
    loadstring(game:HttpGet(Scripts[PlaceId]))()
else
    print("No custom script for this game: " .. PlaceId)
end
