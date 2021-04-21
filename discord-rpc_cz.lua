
--  ▀▀█▀▀ █▀▀▀█ ▀▀▀▀█ █▀█▀█ █▀▀▀█ █▀▀▀▀
--    █   █  █    █ █ █ █ █ █   █ █
--    █   █ █    █  █ █ █ █ █   █ ▀▀▀▀█
--    ▀   ▀▀▀▀▀ ▀▀▀▀▀ ▀ ▀ ▀ █   █     █
--       TEAM NSHON'YAKU    ▀   ▀ ▀▀▀▀▀  

-- Discord RPC
-- Outputs current editing session to Discord Rich Presence
--
-- Original code: muhdnurhidayat (https://github.com/MuhdNurHidayat/Aegisub-DiscordRPC)


local ffi = require "ffi"
local discordRPClib = ffi.load("discord-rpc")
local appId = "830097553595826216"

script_name = "Discord RPC"
script_description = "Výstup Aegisub informací do Discord Rich Presence"
script_author = "KDan"
script_version = "3.1"

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

dis_ikona = "aegisub"
discordRPC.initialize(appId, true)

local now = os.time(os.date('*t'))
presence = {
	state = "KDan#7873 / TeamNS",
    details = "Nečinný | Skript vytvořil",
    startTimestamp = now,
    largeImageKey = "aegisub",
    smallImageKey = "",
}

discordRPC.updatePresence(presence)

dialog_buttons={"Zapnout","Vypnout"}
dialog_config=
{
    {
        class="dropdown",name="zprava",
        x=1,y=0,width=1,height=1,
        items={"Překlad anime","Korekce anime"},
        value="Překlad anime"
    },
    {
        class="checkbox",name="zprava_check",
        x=0,y=1,width=1,height=1,
        label="Vlastní zpráva:",
        value=false
    },
    {
        class="dropdown",name="ikona_menu",
        x=1,y=2,width=1,height=1,
        items={"Výchozí","Překlad","Korekce"},
        value="Výchozí"
    },
    {
        class="label",
        x=0,y=0,width=1,height=1,
        label="Zpráva:"
    },
	{
        class="label",
        x=0,y=2,width=1,height=1,
        label="Ikona:"
    },
    {
        class="textbox",name="vlastni_zprava",
        x=1,y=1,width=1,height=1,
        value=nil
    }
}

function refreshIkona()
	if results["ikona_menu"] == "Výchozí" then
		if results["zprava_check"] == false then
			if results["zprava"] == "Překlad anime" then
				dis_ikona = "preklad"
			elseif results["zprava"] == "Korekce anime" then
				dis_ikona = "korekce"
			end
		end
		if results["zprava_check"] == true then 
			dis_ikona = "aegisub"
		end
	elseif results["ikona_menu"]=="Překlad" then
		dis_ikona = "preklad"
	elseif results["ikona_menu"]=="Korekce" then
		dis_ikona = "korekce"
	end
end

function rpc_setup()
	tlacitko, results = aegisub.dialog.display(dialog_config,dialog_buttons)	
	if tlacitko=="Vypnout" then
		discordRPC.clearPresence()
	elseif tlacitko=="Zapnout" then
		discordRPC.initialize(appId, true)
		local now = os.time(os.date('*t'))
		if results["zprava_check"] == false then
			if results["zprava"]=="Překlad anime" then
				refreshIkona()
				update_rpc_1()
			elseif results["zprava"]=="Korekce anime" then
				refreshIkona()
				update_rpc_2()
			end
		else
			if(string.len(results["vlastni_zprava"]) > 117) then
				videoname = string.sub(results["vlastni_zprava"], 1, 117) .. "…"
			end 
			if (aegisub.project_properties() ~= nil) then
				local videoname = aegisub.project_properties().video_file;
				if (videoname ~= " ") then
					videoname = videoname:match("[^\\]*$")
					if(string.len(videoname) > 117) then
						videoname = string.sub(videoname, 1, 117) .. "…"
					end                
					refreshIkona()
					presence = {
						state = "Video: " .. videoname,
						details = results["vlastni_zprava"],
						startTimestamp = now,
						largeImageKey = dis_ikona,
						smallImageKey = "",
					}
					discordRPC.updatePresence(presence)
				else
					aegisub.debug.out("Please ensure your subtitle file has video file path defined before updating the RPC")
				end
			else
				aegisub.debug.out("Please ensure your subtitle file has video file path defined before updating the RPC")
			end
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
            presence = {
                state = "Video: " .. videoname,
                details = "Překládání anime",
                startTimestamp = now,
                largeImageKey = dis_ikona,
                smallImageKey = "",
            }
            discordRPC.updatePresence(presence)
        else
            aegisub.debug.out("Please ensure your subtitle file has video file path defined before updating the RPC")
        end
    else
        aegisub.debug.out("Please ensure your subtitle file has video file path defined before updating the RPC")
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
            presence = {
                state = "Video: " .. videoname,
                details = "Korekce anime",
                startTimestamp = now,
                largeImageKey = dis_ikona,
                smallImageKey = "",
            }
            discordRPC.updatePresence(presence)
        else
            aegisub.debug.out("Please ensure your subtitle file has video file path defined before updating the RPC")
        end
    else
        aegisub.debug.out("Please ensure your subtitle file has video file path defined before updating the RPC")
    end
end

aegisub.register_macro("Discord RPC", "Nastavit Discord RPC", rpc_setup)
