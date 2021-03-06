
--  ▀▀█▀▀ █▀▀▀█ ▀▀▀▀█ █▀█▀█ █▀▀▀█ █▀▀▀▀
--    █   █  █    █ █ █ █ █ █   █ █
--    █   █ █    █  █ █ █ █ █   █ ▀▀▀▀█
--    ▀   ▀▀▀▀▀ ▀▀▀▀▀ ▀ ▀ ▀ █   █     █
--       TEAM NSHON'YAKU    ▀   ▀ ▀▀▀▀▀  

-- Původní kód: mnh48 (https://github.com/mnh48/Aegisub-DiscordRPC)


local ffi = require "ffi"
local discordRPClib = ffi.load("discord-rpc")
local appId = "830097553595826216"

script_name = "Discord RPC"
script_description = "Výstup Aegisub informací do Discord Rich Presence"
script_author = "KDan"
script_version = "4"

ffi.cdef[[
typedef struct DiscordRichPresence {
	const char* state;   /* max 128 bytes */
	const char* details; /* max 128 bytes */
	int64_t startTimestamp;
	int64_t endTimestamp;
	const char* largeImageKey;  /* max 32 bytes */
	const char* largeImageText; /* max 128 bytes */
	const char* smallImageKey;  /* max 32 bytes */
	const char* smallImageText; /* max 128 bytes */
	const char* partyId;        /* max 128 bytes */
	int partySize;
	int partyMax;
	const char* matchSecret;    /* max 128 bytes */
	const char* joinSecret;     /* max 128 bytes */
	const char* spectateSecret; /* max 128 bytes */
	int8_t instance;
} DiscordRichPresence;

typedef struct DiscordUser {
	const char* userId;
	const char* username;
	const char* discriminator;
	const char* avatar;
} DiscordUser;

typedef void (*readyPtr)(const DiscordUser* request);
typedef void (*disconnectedPtr)(int errorCode, const char* message);
typedef void (*erroredPtr)(int errorCode, const char* message);
typedef void (*joinGamePtr)(const char* joinSecret);
typedef void (*spectateGamePtr)(const char* spectateSecret);
typedef void (*joinRequestPtr)(const DiscordUser* request);

typedef struct DiscordEventHandlers {
	readyPtr ready;
	disconnectedPtr disconnected;
	erroredPtr errored;
	joinGamePtr joinGame;
	spectateGamePtr spectateGame;
	joinRequestPtr joinRequest;
} DiscordEventHandlers;

void Discord_Initialize(const char* applicationId,
						DiscordEventHandlers* handlers,
						int autoRegister,
						const char* optionalSteamId);

void Discord_Shutdown(void);

void Discord_RunCallbacks(void);

void Discord_UpdatePresence(const DiscordRichPresence* presence);

void Discord_ClearPresence(void);

void Discord_Respond(const char* userid, int reply);

void Discord_UpdateHandlers(DiscordEventHandlers* handlers);
]]

local discordRPC = {} -- module table

-- proxy to detect garbage collection of the module
discordRPC.gcDummy = newproxy(true)

local function unpackDiscordUser(request)
	return ffi.string(request.userId), ffi.string(request.username),
		ffi.string(request.discriminator), ffi.string(request.avatar)
end

-- callback proxies
-- note: callbacks are not JIT compiled (= SLOW), try to avoid doing performance critical tasks in them
-- luajit.org/ext_ffi_semantics.html
local ready_proxy = ffi.cast("readyPtr", function(request)
	if discordRPC.ready then
		discordRPC.ready(unpackDiscordUser(request))
	end
end)

local disconnected_proxy = ffi.cast("disconnectedPtr", function(errorCode, message)
	if discordRPC.disconnected then
		discordRPC.disconnected(errorCode, ffi.string(message))
	end
end)

local errored_proxy = ffi.cast("erroredPtr", function(errorCode, message)
	if discordRPC.errored then
		discordRPC.errored(errorCode, ffi.string(message))
	end
end)

-- helpers
function checkArg(arg, argType, argName, func, maybeNil)
	assert(type(arg) == argType or (maybeNil and arg == nil),
		string.format("Argument \"%s\" to function \"%s\" has to be of type \"%s\"",
			argName, func, argType))
end

function checkStrArg(arg, maxLen, argName, func, maybeNil)
	if maxLen then
		assert(type(arg) == "string" and arg:len() <= maxLen or (maybeNil and arg == nil),
			string.format("Argument \"%s\" of function \"%s\" has to be of type string with maximum length %d",
				argName, func, maxLen))
	else
		checkArg(arg, "string", argName, func, true)
	end
end

function checkIntArg(arg, maxBits, argName, func, maybeNil)
	maxBits = math.min(maxBits or 32, 52) -- lua number (double) can only store integers < 2^53
	local maxVal = 2^(maxBits-1) -- assuming signed integers, which, for now, are the only ones in use
	assert(type(arg) == "number" and math.floor(arg) == arg
		and arg < maxVal and arg >= -maxVal
		or (maybeNil and arg == nil),
		string.format("Argument \"%s\" of function \"%s\" has to be a whole number <= %d",
			argName, func, maxVal))
end

-- function wrappers
function discordRPC.initialize(applicationId, autoRegister, optionalSteamId)
	local func = "discordRPC.Initialize"
	checkStrArg(applicationId, nil, "applicationId", func)
	checkArg(autoRegister, "boolean", "autoRegister", func)
	if optionalSteamId ~= nil then
		checkStrArg(optionalSteamId, nil, "optionalSteamId", func)
	end

	local eventHandlers = ffi.new("struct DiscordEventHandlers")
	eventHandlers.ready = ready_proxy
	eventHandlers.disconnected = disconnected_proxy
	eventHandlers.errored = errored_proxy
	eventHandlers.joinGame = joinGame_proxy
	eventHandlers.spectateGame = spectateGame_proxy
	eventHandlers.joinRequest = joinRequest_proxy

	discordRPClib.Discord_Initialize(applicationId, eventHandlers,
		autoRegister and 1 or 0, optionalSteamId)
end

function discordRPC.shutdown()
	discordRPClib.Discord_Shutdown()
end

function discordRPC.runCallbacks()
	-- http://luajit.org/ext_ffi_semantics.html#callback :
	-- One thing that's not allowed, is to let an FFI call into a C function (runCallbacks)
	-- get JIT-compiled, which in turn calls a callback, calling into Lua again (i.e. discordRPC.ready).
	-- Usually this attempt is caught by the interpreter first and the C function
	-- is blacklisted for compilation.
	-- solution:
	-- Then you'll need to manually turn off JIT-compilation with jit.off() for
	-- the surrounding Lua function that invokes such a message polling function.
	jit.off()
	discordRPClib.Discord_RunCallbacks()
	jit.on()
end

function discordRPC.updatePresence(presence)
	local func = "discordRPC.updatePresence"
	checkArg(presence, "table", "presence", func)

	-- -1 for string length because of 0-termination
	checkStrArg(presence.state, 127, "presence.state", func, true)
	checkStrArg(presence.details, 127, "presence.details", func, true)

	checkIntArg(presence.startTimestamp, 64, "presence.startTimestamp", func, true)
	checkIntArg(presence.endTimestamp, 64, "presence.endTimestamp", func, true)

	checkStrArg(presence.largeImageKey, 31, "presence.largeImageKey", func, true)
	checkStrArg(presence.largeImageText, 127, "presence.largeImageText", func, true)
	checkStrArg(presence.smallImageKey, 31, "presence.smallImageKey", func, true)
	checkStrArg(presence.smallImageText, 127, "presence.smallImageText", func, true)
	checkStrArg(presence.partyId, 127, "presence.partyId", func, true)

	checkIntArg(presence.partySize, 32, "presence.partySize", func, true)
	checkIntArg(presence.partyMax, 32, "presence.partyMax", func, true)

	checkStrArg(presence.matchSecret, 127, "presence.matchSecret", func, true)
	checkStrArg(presence.joinSecret, 127, "presence.joinSecret", func, true)
	checkStrArg(presence.spectateSecret, 127, "presence.spectateSecret", func, true)

	checkIntArg(presence.instance, 8, "presence.instance", func, true)

	local cpresence = ffi.new("struct DiscordRichPresence")
	cpresence.state = presence.state
	cpresence.details = presence.details
	cpresence.startTimestamp = presence.startTimestamp or 0
	cpresence.endTimestamp = presence.endTimestamp or 0
	cpresence.largeImageKey = presence.largeImageKey
	cpresence.largeImageText = presence.largeImageText
	cpresence.smallImageKey = presence.smallImageKey
	cpresence.smallImageText = presence.smallImageText
	cpresence.partyId = presence.partyId
	cpresence.partySize = presence.partySize or 0
	cpresence.partyMax = presence.partyMax or 0
	cpresence.matchSecret = presence.matchSecret
	cpresence.joinSecret = presence.joinSecret
	cpresence.spectateSecret = presence.spectateSecret
	cpresence.instance = presence.instance or 0

	discordRPClib.Discord_UpdatePresence(cpresence)
end

function discordRPC.clearPresence()
	discordRPClib.Discord_ClearPresence()
end

local replyMap = {
	no = 0,
	yes = 1,
	ignore = 2
}

-- maybe let reply take ints too (0, 1, 2) and add constants to the module
function discordRPC.respond(userId, reply)
	checkStrArg(userId, nil, "userId", "discordRPC.respond")
	assert(replyMap[reply], "Argument 'reply' to discordRPC.respond has to be one of \"yes\", \"no\" or \"ignore\"")
	discordRPClib.Discord_Respond(userId, replyMap[reply])
end

-- garbage collection callback
getmetatable(discordRPC.gcDummy).__gc = function()
	discordRPC.shutdown()
	ready_proxy:free()
	disconnected_proxy:free()
	errored_proxy:free()
end

function discordRPC.ready(userId, username, discriminator, avatar)
    print("[discordrpc] Discord: ready (" .. userId .. ", " .. username .. ", " .. discriminator ", " .. avatar .. ")")
end

function discordRPC.disconnected(errorCode, message)
    print("[discordrpc] Discord: disconnected (" .. errorCode .. ": " .. message .. ")")
end

function discordRPC.errored(errorCode, message)
    print("[discordrpc] Discord: error (" .. errorCode .. ": " .. message .. ")")
end

config_path = "C:\\aegisub_discord_rpc.cfg"
dis_ikona = "aegisub"

function zapsatConfig()
	config_soubor = io.open(config_path, "w")
	io.output(config_soubor)
	io.write("--Konfigurační soubor RPC skriptu--", "\n")
	if results["zprava_check"] == false then
		io.write("zprava=" .. results["zprava"], "\n")
	else
		io.write("zprava=" .. results["vlastni_zprava"], "\n")
	end
	io.write("ikona=" .. results["ikona_menu"], "\n")
	io.write("skrytNazev=" .. tostring(results["video_check"]), "\n")
	io.write("autostart=" .. tostring(results["start_check"]))
	io.close(config_soubor)
end

function cistConfig()
	config_soubor = io.open(config_path, "r")
	if config_soubor == nil then
		config_soubor = io.open(config_path, "w")
		io.output(config_soubor)
		io.write("--Konfigurační soubor RPC skriptu--", "\n")
		io.write("zprava=Překlad anime", "\n")
		io.write("ikona=Výchozí" , "\n")
		io.write("skrytNazev=false", "\n")
		io.write("autostart=false")
		io.close(config_soubor)
		config_soubor = io.open(config_path, "r")
	end
	io.input(config_soubor)
	configInfo=io.read("*line")
	configZprava=io.read("*line")
	configIkona=io.read("*line")
	configSkrytNazev=io.read("*line")
	configAutostart=io.read("*line")
	io.close(config_soubor)
	
	zprava_checkValue = false
	vlastni_zpravaValue = nil
	if configZprava == "zprava=Překlad anime" then
		zpravaValue = "Překlad anime"
	elseif configZprava == "zprava=Korekce anime" then
		zpravaValue = "Korekce anime"
	else
		zprava_checkValue = true
		vlastni_zpravaValue = configZprava:gsub("zprava=", "")
	end
	if configIkona == "ikona=Překlad" then
		ikonaValue = "Překlad"
	elseif configIkona == "ikona=Korekce" then
		ikonaValue = "Korekce"
	else
		ikonaValue = "Výchozí"
	end
	if configSkrytNazev == "skrytNazev=true" then
		skrytNazevValue = true
	else
		skrytNazevValue = false
	end
	if configAutostart == "autostart=false" then
		autostartValue = false
	else
		autostartValue = true
	end
	dialog_config=
	{
		{
			class="dropdown",name="zprava",
			x=1,y=0,width=1,height=1,
			items={"Překlad anime","Korekce anime"},
			value=zpravaValue
		},
		{
			class="checkbox",name="zprava_check",
			x=0,y=2,width=1,height=1,
			label="Vlastní zpráva:",
			value=zprava_checkValue
		},
		{
			class="checkbox",name="video_check",
			x=0,y=4,width=1,height=1,
			label="Skrýt název videa",
			value=skrytNazevValue
		},
		{
			class="checkbox",name="start_check",
			x=1,y=4,width=1,height=1,
			label="Zakázat automatické spouštění",
			value=autostartValue
		},
		{
			class="dropdown",name="ikona_menu",
			x=1,y=1,width=1,height=1,
			items={"Výchozí","Překlad","Korekce"},
			value=ikonaValue
		},
		{
			class="label",
			x=0,y=0,width=1,height=1,
			label="Zpráva:"
		},
		{
			class="label",
			x=0,y=1,width=1,height=1,
			label="Ikona:"
		},
		{
			class="textbox",name="vlastni_zprava",
			x=1,y=2,width=1,height=2,
			value=vlastni_zpravaValue
		}
	}
end

cistConfig()

if autostartValue == false then

	discordRPC.initialize(appId, true)

	now = os.time(os.date('*t'))

	presence = {
		state = "KDan#7873 / TeamNS",
		details = "Nečinný | Skript vytvořil",
		startTimestamp = now,
		largeImageKey = "aegisub",
		smallImageKey = "",
	}

	discordRPC.updatePresence(presence)
end

dialog_buttons={"Ulozit"}

function refreshIkona()
	if ikonaValue == "Výchozí" then
		if zprava_checkValue == false then
			if zpravaValue == "Překlad anime" then
				dis_ikona = "preklad"
			elseif zpravaValue == "Korekce anime" then
				dis_ikona = "korekce"
			end
		end
		if zprava_checkValue == true then 
			dis_ikona = "aegisub"
		end
	elseif ikonaValue=="Překlad" then
		dis_ikona = "preklad"
	elseif ikonaValue=="Korekce" then
		dis_ikona = "korekce"
	end
end

function rpc_setup()
	cistConfig()
	tlacitko, results = aegisub.dialog.display(dialog_config,dialog_buttons)	
	if tlacitko=="Ulozit" then
		zapsatConfig()
	end
end

function rpc_refresh()
	cistConfig()
	now = os.time(os.date('*t'))
	discordRPC.initialize(appId, true)
	if zprava_checkValue == false then
		if zpravaValue=="Překlad anime" then
			refreshIkona()
			update_rpc_1()
		elseif zpravaValue=="Korekce anime" then
			refreshIkona()
			update_rpc_2()
		end
	else
		if(string.len(vlastni_zpravaValue) > 117) then
			videoname = string.sub(vlastni_zpravaValue, 1, 117) .. "…"
		end 
		if (aegisub.project_properties() ~= nil) then
			local videoname = aegisub.project_properties().video_file;
			if (videoname ~= " ") then
				videoname = videoname:match("[^\\]*$")
				if(string.len(videoname) > 117) then
					videoname = string.sub(videoname, 1, 117) .. "…"
				end                
				status2 = "Video: " .. videoname
				if skrytNazevValue == true then
					status2 = "teamnshonyaku.cz"
				end
				refreshIkona()
				presence = {
					state = status2,
					details = vlastni_zpravaValue,
					startTimestamp = now,
					largeImageKey = dis_ikona,
					smallImageKey = "",
				}
				discordRPC.updatePresence(presence)
			else
				aegisub.debug.out("Před aktualizací zkontroluj videosoubor")
			end
		else
			aegisub.debug.out("Před aktualizací zkontroluj videosoubor")
		end
	end
end


function update_rpc_1()
    if (aegisub.project_properties() ~= nil) then
        local videoname = aegisub.project_properties().video_file;
        if (videoname ~= " ") then
            videoname = videoname:match("[^\\]*$")
            if(string.len(videoname) > 117) then
                videoname = string.sub(videoname, 1, 117) .. "…"
            end                
            status2 = "Video: " .. videoname
			if skrytNazevValue == true then
				status2 = "teamnshonyaku.cz"
		    end
			presence = {
                state = status2,
                details = "Překládání anime",
                startTimestamp = now,
                largeImageKey = dis_ikona,
                smallImageKey = "",
            }
            discordRPC.updatePresence(presence)
        else
            aegisub.debug.out("Před aktualizací zkontroluj videosoubor")
        end
    else
        aegisub.debug.out("Před aktualizací zkontroluj videosoubor")
    end
end
function update_rpc_2()
    if (aegisub.project_properties() ~= nil) then
        local videoname = aegisub.project_properties().video_file;
        if (videoname ~= " ") then
            videoname = videoname:match("[^\\]*$")
            if(string.len(videoname) > 117) then
                videoname = string.sub(videoname, 1, 117) .. "…"
            end                
            status2 = "Video: " .. videoname
			if skrytNazevValue == true then
				status2 = "teamnshonyaku.cz"
			end
			presence = {
                state = status2,
                details = "Korekce anime",
                startTimestamp = now,
                largeImageKey = dis_ikona,
                smallImageKey = "",
            }
            discordRPC.updatePresence(presence)
        else
            aegisub.debug.out("Před aktualizací zkontroluj videosoubor")
        end
    else
        aegisub.debug.out("Před aktualizací zkontroluj videosoubor")
    end
end

function o_skriptu()
	aegisub.debug.out("Skript vytvořil KDan ze skupiny Team NShon'yaku\nPůvodní kód: mnh48\nNejnovější verzi skriptu najdete na:\nhttps://github.com/KDan69/Aegisub-DiscordRPC_CZ\n\nV případě jakéhokoliv problému mě neváhejte kontaktovat na Discordu ^_^ (KDan#7873)")
end

aegisub.register_macro("Discord RPC/Aktualizovat údaje", "Aktualizace Discord RPC", rpc_refresh)
aegisub.register_macro("Discord RPC/Vypnout", "Vypnutí Discord RPC", discordRPC.clearPresence)
aegisub.register_macro("Discord RPC/Nastavení", "Nastavení Discord RPC", rpc_setup)
aegisub.register_macro("Discord RPC/O skriptu...", "Zobrazí info o skriptu", o_skriptu)
