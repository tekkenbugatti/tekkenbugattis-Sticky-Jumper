-- Sticky Jumper
-- TF2-style sticky launcher, client-side, no damage.
--
-- Drops a Tool called "Sticky Jumper" into your hotbar. Equip it and:
--   LMB  fire a sticky / hold to charge it up / release to launch
--   RMB  blow up every sticky you've got out, all at once
--
-- Stickies glue to whatever they hit. A detonation throws you along the line
-- from the bomb to your body - exactly the way TF2 does it. Your aim only
-- decides WHERE the bomb lands; it never steers the launch. Stand on the bomb
-- and you fire straight up, put it on a wall behind you and you fly forward.
-- Stack a few in one spot for a stronger blast.
--
-- Bombs leave the barrel: they spawn at the launcher's muzzle and fly out
-- along your crosshair. In first person the launcher itself turns to follow the
-- camera, so the barrel points wherever you aim; the rest of the time it just
-- rides the hand. On its LEFT face it has a little screen (speed + charge, and
-- the RightShift colour picker) that you can read in first person.
--
-- All of it is local. No damage to you or anyone else, no knockback for other
-- players, and only you can see the stickies and the explosions.
--
-- Extras: a speedometer with your peak speed, bunny-hop chain and best launch;
-- sound cues for the launcher, the blast and the chute; a pop-open parachute
-- animation; and an optional auto air-strafe assist.
--
-- P toggles everything, J toggles the auto air-strafe assist. To reload, run
-- getgenv().__StickyJumper.destroy() and then run this file again.

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local SoundService = game:GetService("SoundService")

local player = Players.LocalPlayer

-- JetBrains Mono isn't exposed as an Enum.Font member on every client build, so
-- reach it through a FontFace instead and fall back to the built-in monospace
-- enum if even that is unavailable. useMono() applies it to any text object.
local MONO_FACE = nil
pcall(function()
	MONO_FACE = Font.new("rbxasset://fonts/families/JetBrainsMono.json")
end)

local function useMono(obj)
	if MONO_FACE then
		if pcall(function() obj.FontFace = MONO_FACE end) then return end
	end
	pcall(function() obj.Font = Enum.Font.RobotoMono end)
end

local CONFIG = {
	enabled   = true,
	toggleKey = Enum.KeyCode.P,
	strafeKey = Enum.KeyCode.J,  -- toggles the auto air-strafe assist

	sticky = {
		max         = 8,    -- most stickies out at once
		minSpeed    = 55,   -- launch speed with no charge
		maxSpeed    = 115,  -- launch speed at a full charge
		chargeTime  = 1.0,  -- seconds of holding LMB for a full charge
		upBias      = 8,    -- small upward arc so a shot doesn't just roll
		-- Your momentum rides along with the bomb: walk forward and it flies
		-- further, jump and it flies higher, do both and it does both. 1 adds
		-- your whole velocity, 0 fires as if you were standing still.
		inherit     = 1,
		radius      = 0.55, -- sticky ball radius
		stickOffset = 0.6,  -- rest this far off the surface it hits
		lifetime    = 30,   -- seconds before an idle sticky disappears
	},

	blast = {
		radius      = 16,   -- blast reach; past this there's no launch
		speed       = 235,  -- blast impulse speed
		maxSpeed    = 260,  -- cap on the blast's own push, so big stacks stay sane
		aimUp       = 0,    -- extra upward tilt on the push (TF2 has none)
		minUp       = 70,   -- never give less than this much upward speed
		-- TF2 sends you along the line from the bomb to your body, full stop.
		-- 0 = pure TF2, 1 = the launch follows your crosshair instead.
		steer       = 0,
		fxTime      = 0.5,  -- how long the blast visual lasts
		stackRadius = 4,    -- stickies within this many studs count as one blast
		stackBonus  = 0.6,  -- extra power per sticky stacked in the same spot
		maxStack    = 2.2,  -- ceiling on the stacked multiplier, so 8 bombs don't nuke you
		-- How much of the speed you already had survives the blast. 0 = the bomb
		-- fully overrides your momentum, 1 = it only ever adds. A little carry
		-- keeps a running start (or a previous jump) worth having.
		momentum    = 0.35,
		-- Blast "grace": the launch is shielded from ground friction and the
		-- velocity resync for this long, so blowing up a bomb at your feet
		-- actually lifts you off instead of being braked back down the same frame.
		hold        = 0.18,
		-- The movement controller caps horizontal speed. A blast may exceed that
		-- cap; the extra bleeds off over roughly half a second (ceilingDecay
		-- studs/s per second) rather than snapping down, so the arc stays smooth.
		ceilingDecay = 220,
	},

	parachute = {
		enabled       = true,
		-- Which canopy shape flies. Chosen from the picker on the launcher
		-- screen: "classic" (gores alternating), "stripe" (white with red
		-- stripes), "army" (one flat matte colour) or "wing" (ram-air).
		design        = "classic",
		designs       = { "classic", "stripe", "army", "wing" },
		safeSpeed     = 16,   -- descent speed while the chute is open (studs/s)
		minFallSpeed  = 20,   -- only open once you're falling faster than this
		minFallHeight = 20,   -- ...and you've fallen at least this far (studs)
		-- Deploy window. This used to be a couple of frames before you landed:
		-- the ground probe only looked deployHeight + speed * deployTime studs
		-- down, so at glide speeds it could never see the ground in time and the
		-- canopy stayed stowed until you were 16 studs up, and at dive speeds it
		-- opened 0.45 s out. Either way there was nothing to look at. Now the
		-- probe reaches probeRange and the chute opens when the ground is inside
		-- openDist = clamp(speed * deployTime, deployHeight, maxDeployDist), so
		-- deployHeight (85) buys about five seconds of float at safeSpeed, the
		-- speed term still catches a dive in time, and maxDeployDist stops it
		-- popping a quarter mile up and leaving you hanging there.
		deployTime    = 1.1,  -- open when impact is this many seconds away...
		deployHeight  = 85,   -- ...or when the ground is this close (whichever is higher)
		maxDeployDist = 170,  -- never open higher than this above the ground
		probeRange    = 220,  -- how far down the ground probe looks (studs)
		light         = true, -- emit a light while the chute is open
		-- OFF on purpose, and it should stay that way.
		--
		-- Zoomed in, this leaned the whole rig forward so the leading edge of the
		-- canopy swung down over your head and into frame. It did exactly that -
		-- and then kept going: the canopy ended up sitting across the middle of
		-- the screen, hiding whatever you were aiming at. The chute now just
		-- flies overhead, out of the way of the view. The number is degrees of
		-- forward lean; 0 is off.
		firstPersonLean = 0,
	},

	-- First person and shift lock aim with the camera. The launcher is welded
	-- to the right hand, so left alone it points wherever the arm animation
	-- leaves it - dead level even when you are staring at your feet. While you
	-- are in either of those camera modes the launcher is turned to follow the
	-- view, and handed straight back to the arm the moment you leave them.
	aim = {
		enabled     = true,
		-- Tip the barrel this many degrees off the exact crosshair line, if the
		-- model reads better aimed a touch high. 0 aims dead on the crosshair.
		pitchOffset = 0,
		},

	-- All cues use assets that already exist in this place or ship with the
	-- client, so nothing has to download from a cold catalog. Volume and range
	-- are for the 2D-ish playback below (further away = quieter).
	sounds = {
		enabled = true,
		volume  = 0.55,
		range   = 90,   -- studs; past this a positioned cue is silent
		-- TF2's sticky launcher is all low thumps and soft clacks, so these cues
		-- are stacked out of the client's own sounds and pitched into that same
		-- register: the shot is a hollow "thoomp" with the launcher's clack over
		-- it, the sticky lands with a dull pat, and the blast is a big low boom.
		-- A table plays every layer at once (per-layer volume and pitch).
		launch = {
			{ id = "rbxasset://sounds/bass.wav",    volume = 1,   pitch = 0.85 }, -- hollow thoomp
			{ id = "rbxasset://sounds/switch3.wav", volume = 0.3, pitch = 0.75 }, -- launcher clack
		},
		stick = {
			{ id = "rbxasset://sounds/snap.mp3",          volume = 0.9, pitch = 0.85 }, -- dull pat
			{ id = "rbxasset://sounds/impact_water.mp3", volume = 0.3, pitch = 1.25 }, -- sticky squelch
		},
		explode = {
			{ id = "rbxassetid://9165891420",    volume = 1,    pitch = 0.95 }, -- blast
			{ id = "rbxasset://sounds/bass.wav", volume = 0.75, pitch = 0.5 },  -- low end
		},
		-- One blast in twenty gets TF2's own "Kaboom" instead of the layered boom
		-- above, so every so often a detonation sounds like the real thing.
		explodeAlt       = {
			{ id = "rbxassetid://129442500468813", volume = 1, pitch = 1 }, -- TF2 Kaboom
		},
		explodeAltChance = 0.05, -- 0 = never, 1 = always
		-- Canopy catching air: a cloth flap with a soft thump under it.
		chute   = {
			{ id = "rbxassetid://151760062",     volume = 1,   pitch = 1.1 },  -- fabric
			{ id = "rbxasset://sounds/bass.wav", volume = 0.45, pitch = 0.7 }, -- thump
		},
		-- Charging the sticky launcher.
		charge  = "rbxassetid://140576516515813",
	},
}

CONFIG.colors = {
	uiOpen = false,
	-- The launcher palette. Names match the parts buildLauncher makes, so a
	-- recolour is a straight lookup (see applyLauncherColors).
	launcher = {
		metal  = Color3.fromRGB(66, 68, 76),
		dark   = Color3.fromRGB(34, 35, 40),
		wood   = Color3.fromRGB(122, 74, 40),
		accent = Color3.fromRGB(226, 118, 28),
	},
	-- The canopy palette: the gores alternate canopy/panel down the seams, so
	-- canopy is the body and panel is the stripe.
	parachute = {
		canopy = Color3.fromRGB(245, 245, 248),
		panel  = Color3.fromRGB(220, 40, 44),
		rim    = Color3.fromRGB(34, 40, 60),
		rib    = Color3.fromRGB(226, 230, 236),
		cord   = Color3.fromRGB(238, 238, 238),
		pack   = Color3.fromRGB(54, 56, 62),
		strap  = Color3.fromRGB(28, 29, 34),
		rip    = Color3.fromRGB(232, 140, 40),
		glow   = Color3.fromRGB(255, 226, 130),
	},
	-- One shared ramp. Clicking a swatch steps it to the next colour here.
	palette = {
		Color3.fromRGB(66, 68, 76),
		Color3.fromRGB(34, 35, 40),
		Color3.fromRGB(122, 74, 40),
		Color3.fromRGB(226, 118, 28),
		Color3.fromRGB(245, 245, 248),
		Color3.fromRGB(220, 40, 44),
		Color3.fromRGB(40, 120, 220),
		Color3.fromRGB(240, 200, 60),
		Color3.fromRGB(120, 200, 120),
		Color3.fromRGB(180, 80, 200),
		Color3.fromRGB(34, 40, 60),
		Color3.fromRGB(28, 29, 34),
	},
}

local VERSION = "1.73"

local genv = (getgenv and getgenv()) or _G

-- Settings persistence ---------------------------------------------------------
--
-- Your paint job survives re-running the script. The launcher/parachute colours
-- and the chosen canopy shape are written to a tiny text file in the executor's
-- workspace (StickyJumper.cfg) and read back on start-up, before the launcher
-- and parachute are built, so the first build already comes up in your colours.
-- Executors without a filesystem fall back to getgenv(), which still carries the
-- settings across executions inside one session.

local SETTINGS_FILE = "StickyJumper.cfg"

local function settingsSerialise()
	local lines = {}
	local function dump(group)
		for key, value in pairs(CONFIG.colors[group]) do
			if typeof(value) == "Color3" then
				lines[#lines + 1] = string.format("%s.%s=%d,%d,%d", group, key,
					math.floor(value.R * 255 + 0.5),
					math.floor(value.G * 255 + 0.5),
					math.floor(value.B * 255 + 0.5))
			end
		end
	end
	dump("launcher")
	dump("parachute")
	lines[#lines + 1] = "design=" .. tostring(CONFIG.parachute.design)
	return table.concat(lines, "\n")
end

local function settingsApply(text)
	if type(text) ~= "string" or text == "" then return false end
	local changed = false
	for group, key, r, g, b in text:gmatch("([%a_]+)%.([%a_]+)=(%d+),(%d+),(%d+)") do
		local bucket = CONFIG.colors[group]
		if bucket and typeof(bucket[key]) == "Color3" then
			bucket[key] = Color3.fromRGB(tonumber(r), tonumber(g), tonumber(b))
			changed = true
		end
	end
	local design = text:match("design=([%a_]+)")
	if design and table.find(CONFIG.parachute.designs, design) then
		CONFIG.parachute.design = design
		changed = true
	end
	return changed
end

local function saveSettings()
	local text = settingsSerialise()
	genv.__SJ_SETTINGS = text
	pcall(function()
		if typeof(writefile) == "function" then writefile(SETTINGS_FILE, text) end
	end)
end

local function loadSettings()
	local data
	pcall(function()
		if typeof(isfile) == "function" and isfile(SETTINGS_FILE)
			and typeof(readfile) == "function" then
			data = readfile(SETTINGS_FILE)
		end
	end)
	if type(data) ~= "string" then data = genv.__SJ_SETTINGS end
	return settingsApply(data)
end

local function resetSettings()
	genv.__SJ_SETTINGS = nil
	pcall(function()
		if typeof(delfile) == "function" and typeof(isfile) == "function" and isfile(SETTINGS_FILE) then
			delfile(SETTINGS_FILE)
		end
	end)
end

-- Bring back the previous session's colours before anything is built.
local settingsLoaded = loadSettings()

-- Let an older copy unload before we take over. Re-running the same version
-- does nothing instead of tearing everything down and rebuilding it.
local existing = genv.__StickyJumper
if type(existing) == "table"
	and existing.alive
	and existing.version == VERSION
	and existing.mainConn
	and existing.mainConn.Connected then
	print("[StickyJumper] already running (" .. VERSION .. "), leaving it be. Run getgenv().__StickyJumper.destroy() to reload.")
	return
end

if type(existing) == "table" then
	pcall(existing.destroy)
end

local enabled = CONFIG.enabled
local globalConns = {}

-- Session numbers for the speedometer: fastest you've moved, how long a
-- bunny-hop chain is running, and your best single sticky launch.
local stats = {
	peak = 0,
	chain = 0,
	best = 0,
}

local function disconnectList(list)
	for _, c in ipairs(list) do
		pcall(function() c:Disconnect() end)
	end
	table.clear(list)
end

-- Anything physically joined to the character (held tools, viewmodels) must
-- not block a sticky.
local function buildIgnoreList(character)
	local list = { character }
	local added = {}

	for _, d in ipairs(character:GetDescendants()) do
		if d:IsA("BasePart") then
			local ok, parts = pcall(function() return d:GetConnectedParts(true) end)
			if ok and parts then
				for _, p in ipairs(parts) do
					if not added[p] and not p:IsDescendantOf(character) then
						added[p] = true
						table.insert(list, p)
					end
				end
			end
		end
	end

	return list
end

-- blast ---------------------------------------------------------------------

local effects = {}   -- every blast visual we spawn (for cleanup)

local function pruneEffects()
	for i = #effects, 1, -1 do
		local e = effects[i]
		if not e or not e.Parent then table.remove(effects, i) end
	end
end

local function clearEffects()
	for _, e in ipairs(effects) do
		if e and e.Parent then pcall(function() e:Destroy() end) end
	end
	table.clear(effects)
end

-- Fire-and-forget sound. With a position it fades out with distance from the
-- camera, so a blast across the map is only a distant thud. Pitch is optional.
-- The entry in CONFIG.sounds may also be a list of layers, which all play at
-- once (volume/pitch per layer), for a cue that needs two sounds stacked.
local function sfx(name, position, pitch)
	local cfg = CONFIG.sounds
	if not cfg.enabled then return end
	local id = cfg[name]
	if not id then return end

	local layers = (type(id) == "table") and id or { { id = id } }

	-- One distance check for the whole cue.
	local attenuation = 1
	if position then
		local cam = workspace.CurrentCamera
		local dist = cam and (cam.CFrame.Position - position).Magnitude or 0
		if dist >= cfg.range then return end
		attenuation = math.clamp(1 - dist / cfg.range, 0, 1)
	end

	local sounds = {}
	for _, layer in ipairs(layers) do
		local layerId = layer.id or layer
		if type(layerId) == "string" and layerId ~= "" then
			local s = Instance.new("Sound")
			s.SoundId = layerId
			s.Volume = cfg.volume * (layer.volume or 1) * attenuation
			s.PlaybackSpeed = (pitch or 1) * (layer.pitch or 1)
			s.Parent = SoundService
			s.Ended:Connect(function() if s.Parent then s:Destroy() end end)
			s:Play()
			-- Safety net in case Ended never arrives (e.g. the sound failed to load).
			task.delay(8, function() if s.Parent then s:Destroy() end end)
			sounds[#sounds + 1] = s
		end
	end
	return sounds[1]
end

-- A blast normally plays the layered boom, but a small, configured fraction of
-- them play the alternate cue instead (the whole cue swaps, nothing layers).
local function sfxExplode(position)
	local cfg = CONFIG.sounds
	if cfg.enabled and cfg.explodeAlt and math.random() < (cfg.explodeAltChance or 0) then
		sfx("explodeAlt", position)
	else
		sfx("explode", position)
	end
end

local function spawnBlastFx(position, powerScale)
	powerScale = powerScale or 1
	local radius = CONFIG.blast.radius
	local fxScale = math.clamp(powerScale, 1, 3)

	-- outer fireball
	local fire = Instance.new("Part")
	fire.Shape = Enum.PartType.Ball
	fire.Material = Enum.Material.Neon
	fire.Color = Color3.fromRGB(255, 165, 60)
	fire.Anchored = true
	fire.CanCollide = false
	fire.CanQuery = false
	fire.CanTouch = false
	fire.Size = Vector3.new(2, 2, 2)
	fire.CFrame = CFrame.new(position)
	fire.Transparency = 0.2
	fire.Parent = workspace
	table.insert(effects, fire)

	local t = TweenService:Create(fire,
		TweenInfo.new(CONFIG.blast.fxTime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Size = Vector3.one * (radius * 1.1 * fxScale), Transparency = 1 })
	t:Play()
	t.Completed:Connect(function() if fire.Parent then fire:Destroy() end end)

	-- bright core flash
	local core = Instance.new("Part")
	core.Shape = Enum.PartType.Ball
	core.Material = Enum.Material.Neon
	core.Color = Color3.fromRGB(255, 245, 220)
	core.Anchored = true
	core.CanCollide = false
	core.CanQuery = false
	core.CanTouch = false
	core.Size = Vector3.new(1, 1, 1)
	core.CFrame = CFrame.new(position)
	core.Parent = workspace
	table.insert(effects, core)

	local ct = TweenService:Create(core,
		TweenInfo.new(CONFIG.blast.fxTime * 0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Size = Vector3.one * (radius * 0.45 * fxScale), Transparency = 1 })
	ct:Play()
	ct.Completed:Connect(function() if core.Parent then core:Destroy() end end)

	-- flash light
	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 200, 130)
	light.Brightness = 10
	light.Range = radius * 1.4
	light.Parent = fire
	TweenService:Create(light, TweenInfo.new(CONFIG.blast.fxTime), { Brightness = 0 }):Play()
end

-- If the wall-parkour script happens to be loaded, drop any move it's driving
-- so it doesn't fight the launch. Optional, and fully guarded.
local function releaseMoves()
	local vp = genv.__VectorParkour
	local d = vp and vp._debug
	if not d then return end
	pcall(function() if d.glide and d.glide.active then d.stopGlide() end end)
	pcall(function() if d.wallrun and d.wallrun.active then d.stopWallrun(false) end end)
	pcall(function() if d.climb and d.climb.active then d.stopClimb(false) end end)
	pcall(function() if d.platform and d.platform.active then d.releasePlatformStand() end end)
end

-- Forward declaration. The Source movement section below assigns this;
-- launchPlayer hands its velocity to the movement controller through it.
local smState

local function launchPlayer(position, powerScale)
	powerScale = powerScale or 1
	local character = player.Character
	local hum = character and character:FindFirstChildOfClass("Humanoid")
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	if not hum or not hrp or hum.Health <= 0 then return end

	local delta = hrp.Position - position
	local dist = delta.Magnitude
	local radius = CONFIG.blast.radius
	if dist > radius then return end

	local falloff = math.clamp(1 - dist / radius, 0, 1)
	falloff = 0.3 + 0.7 * falloff

	-- TF2 rules, to the letter: the blast throws you along the line from the
	-- bomb to your body. Your crosshair decides where the bomb goes, never
	-- where the launch goes. Bomb under your feet -> straight up; bomb on a
	-- wall in front of you -> flung backwards; bomb behind you -> fired
	-- forwards. (steer can fold the aim back in, but TF2 leaves it at 0.)
	local away = delta.Magnitude > 1e-3 and delta.Unit or Vector3.new(0, 1, 0)
	local dir = away
	if CONFIG.blast.steer > 0 then
		local cam = workspace.CurrentCamera
		local aim = (cam and cam.CFrame.LookVector) or hrp.CFrame.LookVector
		if aim.Magnitude > 1e-3 then
			dir = away * (1 - CONFIG.blast.steer) + aim.Unit * CONFIG.blast.steer
		end
	end
	if CONFIG.blast.aimUp ~= 0 then
		dir = dir + Vector3.new(0, CONFIG.blast.aimUp, 0)
	end
	if dir.Magnitude < 1e-3 then dir = Vector3.new(0, 1, 0) end
	dir = dir.Unit

	local power = math.min(powerScale, CONFIG.blast.maxStack)
	local speed = math.min(CONFIG.blast.speed * falloff * power, CONFIG.blast.maxSpeed)
	local upSpeed = math.max(dir.Y * speed, CONFIG.blast.minUp * falloff * power)

	releaseMoves()

	hum:ChangeState(Enum.HumanoidStateType.Freefall)
	local vel = hrp.AssemblyLinearVelocity
	local keep = CONFIG.blast.momentum     -- how much of our old speed rides along
	local nx = vel.X * keep + dir.X * speed
	local nz = vel.Z * keep + dir.Z * speed
	hrp.AssemblyLinearVelocity = Vector3.new(nx, math.max(upSpeed, vel.Y * keep + dir.Y * speed), nz)
	-- Hand the launch to the movement controller so its velocity constraint
	-- keeps the speed instead of dragging it back down, and shield it from the
	-- ground for a beat so a bomb at our feet actually lifts us off instead of
	-- being braked away the same frame. The blast also lifts the speed cap; the
	-- extra bleeds off smoothly rather than snapping.
	if smState then
		smState.hv = Vector3.new(nx, 0, nz)
		smState.blastHold = CONFIG.blast.hold
		smState.softCeil = math.max(smState.softCeil or 0, math.sqrt(nx * nx + nz * nz))
	end

	local launched = math.sqrt(nx * nx + nz * nz)
	if launched > stats.best then stats.best = launched end
end

local function explode(position, powerScale)
	powerScale = powerScale or 1
	spawnBlastFx(position, powerScale)
	sfxExplode(position)
	launchPlayer(position, powerScale)
end

-- sticky launcher -----------------------------------------------------------

local stickies = {}        -- { part, stuck, prev, born }
local stickyCharging = false
local stickyChargeStart = 0
local stickyTool = nil

local function clearStickies()
	for _, s in ipairs(stickies) do
		if s.part and s.part.Parent then pcall(function() s.part:Destroy() end) end
	end
	table.clear(stickies)
end

local function stickyToolEquipped()
	return stickyTool ~= nil and stickyTool.Parent ~= nil and stickyTool.Parent == player.Character
end

local function stickyRayParams()
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local character = player.Character
	params.FilterDescendantsInstances = character and buildIgnoreList(character) or {}
	-- Let the engine skip collisionless parts by itself where it can; the flight
	-- loop also checks by hand so this works on every client either way.
	pcall(function() params.RespectCanCollide = true end)
	return params
end

-- A part should only stop a sticky in flight if the map actually treats it as
-- solid. Triggers, kill bricks, water planes, decorations and anything else with
-- its collision switched off have to be flown straight through - otherwise
-- bombs hang in mid-air on invisible geometry.
local function stickyBlocks(inst)
	if not inst then return false end
	if inst:IsA("Terrain") then return true end
	if inst:IsA("BasePart") then return inst.CanCollide end
	return false
end

-- A sticky's worst failure is "it went through the ground", and it comes from
-- one special case: a ray that starts INSIDE a part never reports that part, so
-- a bomb that is born in the floor cannot see the floor it is inside and falls
-- out of the world. Everything below therefore tests solidity with rays that
-- start in places we know are clear air, rather than by asking what is at the
-- bomb itself - which also keeps it working on Terrain floors, where an
-- overlap query on parts would see nothing at all.

-- World CFrame of the launcher's muzzle tip, or nil if the tool isn't in our
-- hands right now. The barrel runs along the tip cylinder's local X axis.
local function launcherMuzzle()
	local tool = stickyTool
	local character = player.Character
	if not tool or not tool.Parent or tool.Parent ~= character then return nil end
	local tip = tool:FindFirstChild("MuzzleTip") or tool:FindFirstChild("Muzzle")
	if tip and tip:IsA("BasePart") then return tip.CFrame end
	return nil
end

-- A quick bloom of orange light at the muzzle, so the shot reads as coming
-- out of the barrel instead of popping into being.
local function spawnMuzzleFlash(pos)
	local p = Instance.new("Part")
	p.Shape = Enum.PartType.Ball
	p.Size = Vector3.new(0.5, 0.5, 0.5)
	p.CFrame = CFrame.new(pos)
	p.Color = Color3.fromRGB(255, 184, 96)
	p.Material = Enum.Material.Neon
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Transparency = 0.15
	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 170, 90)
	light.Brightness = 3
	light.Range = 11
	light.Shadows = false
	light.Parent = p
	p.Parent = workspace
	TweenService:Create(p, TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Size = Vector3.new(1.7, 1.7, 1.7), Transparency = 1 }):Play()
	TweenService:Create(light, TweenInfo.new(0.1), { Brightness = 0 }):Play()
	task.delay(0.14, function() p:Destroy() end)
end

local function startStickyCharge()
	if not enabled or stickyCharging then return end
	if CONFIG.colors and CONFIG.colors.uiOpen then return end
	stickyCharging = true
	stickyChargeStart = os.clock()
end

local function fireSticky()
	local character = player.Character
	local hum = character and character:FindFirstChildOfClass("Humanoid")
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	if not hum or not hrp or hum.Health <= 0 then
		stickyCharging = false
		return
	end

	local charge = 0
	if stickyCharging then
		charge = math.clamp((os.clock() - stickyChargeStart) / CONFIG.sticky.chargeTime, 0, 1)
	end
	stickyCharging = false

	local camera = workspace.CurrentCamera
	local look = (camera and camera.CFrame.LookVector) or hrp.CFrame.LookVector

	-- Cap the count: firing past the limit drops the oldest sticky.
	while #stickies >= CONFIG.sticky.max do
		local oldest = table.remove(stickies, 1)
		if oldest and oldest.part and oldest.part.Parent then oldest.part:Destroy() end
	end

	local diameter = CONFIG.sticky.radius * 2
	local part = Instance.new("Part")
	part.Name = "StickyBomb"
	part.Shape = Enum.PartType.Ball
	part.Size = Vector3.new(diameter, diameter, diameter)
	part.Material = Enum.Material.Metal
	part.Color = Color3.fromRGB(58, 60, 70)
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth

	-- The bomb comes out of the barrel: spawn it just past the muzzle tip and
	-- send it down your crosshair. If the launcher isn't in our hands (say a
	-- direct _debug call), fall back to in front of the chest.
	local origin = hrp.Position + Vector3.new(0, 1.4, 0) + look * 1.6
	local muzzle = launcherMuzzle()
	if muzzle then
		local axis = muzzle.RightVector
		if axis:Dot(look) < 0 then axis = -axis end -- always point out the front
		origin = muzzle.Position + axis * 0.45
	end

	-- Shooting at your own feet, the muzzle tip - and so the spawn point - can
	-- end up inside the floor: the barrel pokes through a thin platform, or past
	-- the lip of a step. That is the one thing a sticky can never recover from,
	-- because a ray that starts inside a part never reports that part, so the
	-- flight sweep below can never see the floor it is inside.
	--
	-- So check the line the shot takes out of your chest: your chest is always in
	-- clear air, and if something solid blocks the way to the muzzle tip then the
	-- tip is behind (or inside) that surface. In that case put the bomb ON the
	-- surface instead, which is also exactly what TF2 does when you shoot the
	-- floor under your feet.
	local chest = hrp.Position + Vector3.new(0, 1.4, 0)
	local block = workspace:Raycast(chest, origin - chest, stickyRayParams())
	if block and stickyBlocks(block.Instance) then
		origin = block.Position + block.Normal * CONFIG.sticky.stickOffset
	end
	if muzzle then spawnMuzzleFlash(origin) end

	part.CFrame = CFrame.new(origin)

	-- The bomb is modelled on TF2's sticky: a squat dark metal ball with a
	-- rubber band round its waist, a short neck and a red lamp on top that
	-- pulses while it sits there. The trim is welded straight onto the ball, so
	-- the whole thing tumbles as one piece and dies with its parent. Every
	-- piece of trim is massless and non-colliding, so the flight and the stick
	-- behave exactly as the plain ball did.
	local function decor(name, shape, size, offset, color, material)
		local d = Instance.new("Part")
		d.Name = name
		d.Shape = shape
		d.Size = size
		d.Color = color
		d.Material = material or Enum.Material.SmoothPlastic
		d.CanCollide = false
		d.CanQuery = false
		d.CanTouch = false
		d.Massless = true
		d.TopSurface = Enum.SurfaceType.Smooth
		d.BottomSurface = Enum.SurfaceType.Smooth
		d.CFrame = part.CFrame * offset
		d.Parent = part
		local w = Instance.new("Weld")
		w.Part0 = part
		w.Part1 = d
		w.C0 = offset
		w.C1 = CFrame.new()
		w.Parent = d
		return d
	end

	local r = CONFIG.sticky.radius
	decor("Band", Enum.PartType.Cylinder, Vector3.new(r * 0.34, r * 2.14, r * 2.14),
		CFrame.Angles(0, 0, math.rad(90)), Color3.fromRGB(28, 29, 33), Enum.Material.Rubber)
	decor("Neck", Enum.PartType.Cylinder, Vector3.new(r * 0.42, r * 0.62, r * 0.62),
		CFrame.new(0, r * 0.9, 0) * CFrame.Angles(0, 0, math.rad(90)),
		Color3.fromRGB(44, 46, 54), Enum.Material.Metal)
	local lamp = decor("Lamp", Enum.PartType.Ball, Vector3.new(r * 0.36, r * 0.36, r * 0.36),
		CFrame.new(0, r * 1.16, 0), Color3.fromRGB(255, 74, 64), Enum.Material.Neon)

	local speed = CONFIG.sticky.minSpeed + (CONFIG.sticky.maxSpeed - CONFIG.sticky.minSpeed) * charge
	-- Momentum: the bomb leaves the barrel carrying whatever you were doing at
	-- that instant, so running forward throws it further and jumping throws it
	-- higher (and both at once do both), exactly like the projectile should.
	local carry = hrp.AssemblyLinearVelocity * CONFIG.sticky.inherit
	part.AssemblyLinearVelocity = look * speed + Vector3.new(0, CONFIG.sticky.upBias, 0) + carry
	part.AssemblyAngularVelocity = Vector3.new(math.random(-8, 8), math.random(-8, 8), math.random(-8, 8))

	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 70, 60)
	light.Brightness = 1.6
	light.Range = 8
	light.Parent = lamp

	part.Parent = workspace
	table.insert(stickies, {
		part = part,
		stuck = false,
		prev = origin,
		born = os.clock(),
		lamp = light,
		lampPart = lamp,
		phase = math.random() * 6.28,
	})
	sfx("launch", origin, 0.95 + math.random() * 0.1)
end

local function releaseSticky()
	if stickyCharging then
		fireSticky()
	end
end

-- Melt stickies within one stack radius into a single, stronger blast.
local function detonateStickies()
	if not enabled or #stickies == 0 then return end

	local positions = {}
	for _, s in ipairs(stickies) do
		if s.part and s.part.Parent then
			table.insert(positions, s.part.Position)
			s.part:Destroy()
		end
	end
	table.clear(stickies)
	stickyCharging = false

	local used = {}
	local groups = {}
	for i = 1, #positions do
		if not used[i] then
			used[i] = true
			local count = 1
			local cx, cy, cz = positions[i].X, positions[i].Y, positions[i].Z
			for j = i + 1, #positions do
				if not used[j] and (positions[j] - positions[i]).Magnitude <= CONFIG.blast.stackRadius then
					used[j] = true
					count = count + 1
					cx = cx + positions[j].X
					cy = cy + positions[j].Y
					cz = cz + positions[j].Z
				end
			end
			table.insert(groups, {
				center = Vector3.new(cx / count, cy / count, cz / count),
				power = 1 + (count - 1) * CONFIG.blast.stackBonus,
			})
		end
	end

	-- Fire the far ones first so the nearest (strongest) push lands last.
	local character = player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	if hrp then
		table.sort(groups, function(a, b)
			return (a.center - hrp.Position).Magnitude > (b.center - hrp.Position).Magnitude
		end)
	end
	for _, g in ipairs(groups) do
		explode(g.center, g.power)
	end
end

local function stepStickies()
	if #stickies == 0 then return end
	local params
	for i = #stickies, 1, -1 do
		local s = stickies[i]
		local part = s.part
		-- TF2's stickies have a lamp that pulses while they sit there.
		if s.lamp and s.lamp.Parent then
			local pulse = 0.5 + 0.5 * math.sin(os.clock() * 7 + (s.phase or 0))
			s.lamp.Brightness = 1 + 2.4 * pulse
			if s.lampPart then s.lampPart.Transparency = 0.3 - 0.25 * pulse end
		end
		if not part or not part.Parent then
			table.remove(stickies, i)
		elseif not s.stuck then
			if os.clock() - s.born > CONFIG.sticky.lifetime then
				part:Destroy()
				table.remove(stickies, i)
			else
				local pos = part.Position
				local delta = pos - s.prev
				if delta.Magnitude > 1e-4 then
					params = params or stickyRayParams()
					-- Walk the ray from the previous position towards where the
					-- bomb is now, stepping over anything collisionless, so it
					-- sticks to the first genuinely solid thing it meets.
					local origin = s.prev
					local remaining = delta
					local hit = nil
					for _ = 1, 12 do
						local h = workspace:Raycast(origin, remaining, params)
						if not h then break end
						if stickyBlocks(h.Instance) then
							hit = h
							break
						end
						local step = (h.Position - origin).Magnitude + 0.05
						if step >= remaining.Magnitude then break end
						origin = origin + remaining.Unit * step
						remaining = pos - origin
						if remaining.Magnitude <= 0.05 then break end
					end
					if hit then
						part.CFrame = CFrame.new(hit.Position + hit.Normal * CONFIG.sticky.stickOffset)
						local surface = hit.Instance
						if surface and surface:IsA("BasePart") and not surface.Anchored then
							-- Moving surface (platform, vehicle, ragdoll). Weld to it
							-- so the sticky rides along instead of hanging in the air.
							part.AssemblyLinearVelocity = Vector3.new()
							part.AssemblyAngularVelocity = Vector3.new()
							part.Massless = true
							local w = Instance.new("WeldConstraint")
							w.Part0 = surface
							w.Part1 = part
							w.Parent = part
							s.weld = w
						else
							part.Anchored = true
						end
						s.stuck = true
						sfx("stick", part.Position, 1 + math.random() * 0.15)
					elseif delta.Y < -0.02 then
						-- Safety net for the same failure: born under a thin floor,
						-- or a pile of collisionless decoration eating the sweep's
						-- step budget. Either way the bomb is now below a surface it
						-- was above last frame, and a ray dropped straight down from
						-- last frame's position meets that surface from the outside
						-- (which also works on Terrain). If it finds one between the
						-- two positions, we fell through it - put the bomb on top.
						params = params or stickyRayParams()
						local cast = math.abs(delta.Y) + CONFIG.sticky.radius * 2 + 0.6
						local above = workspace:Raycast(s.prev, Vector3.new(0, -cast, 0), params)
						if above and stickyBlocks(above.Instance) and above.Position.Y > pos.Y then
							part.CFrame = CFrame.new(above.Position + above.Normal * CONFIG.sticky.stickOffset)
							part.AssemblyLinearVelocity = Vector3.new()
							part.AssemblyAngularVelocity = Vector3.new()
							part.Anchored = true
							s.stuck = true
							sfx("stick", part.Position, 1 + math.random() * 0.15)
						end
					end
				end
				s.prev = pos
			end
		end
	end
end

-- launcher model (a TF2-style sticky launcher, built out of parts) ----------

local launcherRoot = nil
local GRIP = CFrame.new(0, 0, 0)

local LAUNCHER = {
	metal  = Color3.fromRGB(66, 68, 76),
	dark   = Color3.fromRGB(34, 35, 40),
	wood   = Color3.fromRGB(122, 74, 40),
	orange = Color3.fromRGB(226, 118, 28),
}

local launcherScreen = nil

-- The readout that sits on the launcher: your speed and the charge meter, so
-- in first person you can watch both without leaving the weapon. This is a
-- SurfaceGui painted onto the screen panel itself, so the numbers live ON the
-- model - the bezel occludes it, it tilts with the gun, and it never floats.
local function buildLauncherScreen(parent)
	local gui = Instance.new("SurfaceGui")
	gui.Name = "LauncherScreen"
	gui.Face = Enum.NormalId.Back       -- painted on the panel's outward face
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 300            -- enough canvas to keep text crisp
	gui.LightInfluence = 0             -- self-lit, like a real screen
	gui.Enabled = false
	gui.Parent = parent

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.Size = UDim2.new(1, 0, 1, 0)
	panel.BackgroundColor3 = Color3.fromRGB(9, 11, 15)
	panel.BackgroundTransparency = 0.05
	panel.BorderSizePixel = 0
	panel.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = panel
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(226, 118, 28)
	stroke.Thickness = 1.5
	stroke.Transparency = 0.3
	stroke.Parent = panel

	local function label(name, pos, size, align, color, text)
		local l = Instance.new("TextLabel")
		l.Name = name
		l.BackgroundTransparency = 1
		l.Position = pos
		l.Size = size
		useMono(l)
		l.TextScaled = true
		l.TextXAlignment = align
		l.TextColor3 = color
		l.Text = text
		local cap = Instance.new("UITextSizeConstraint")
		cap.MaxTextSize = 48
		cap.MinTextSize = 4
		cap.Parent = l
		l.Parent = panel
		return l
	end

	label("SpeedTag", UDim2.new(0.06, 0, 0.05, 0), UDim2.new(0.3, 0, 0.4, 0),
		Enum.TextXAlignment.Left, Color3.fromRGB(140, 146, 158), "SPD")
	local value = label("Speed", UDim2.new(0.36, 0, 0.02, 0), UDim2.new(0.58, 0, 0.46, 0),
		Enum.TextXAlignment.Right, Color3.fromRGB(255, 255, 255), "0")

	-- charge meter along the bottom
	local bar = Instance.new("Frame")
	bar.Name = "Charge"
	bar.Position = UDim2.new(0.06, 0, 0.57, 0)
	bar.Size = UDim2.new(0.88, 0, 0.35, 0)
	bar.BackgroundColor3 = Color3.fromRGB(24, 27, 34)
	bar.BorderSizePixel = 0
	bar.Parent = panel
	local bc = Instance.new("UICorner")
	bc.CornerRadius = UDim.new(0, 4)
	bc.Parent = bar
	local bs = Instance.new("UIStroke")
	bs.Color = Color3.fromRGB(0, 0, 0)
	bs.Thickness = 1
	bs.Transparency = 0.4
	bs.Parent = bar

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.new(0, 0, 1, 0)
	fill.BackgroundColor3 = Color3.fromRGB(255, 120, 40)
	fill.BorderSizePixel = 0
	fill.Parent = bar
	local fc = Instance.new("UICorner")
	fc.CornerRadius = UDim.new(0, 4)
	fc.Parent = fill

	return { gui = gui, value = value, fill = fill, part = parent }
end

local function buildLauncher(parent)
	local m = {
		metal  = CONFIG.colors.launcher.metal,
		dark   = CONFIG.colors.launcher.dark,
		wood   = CONFIG.colors.launcher.wood,
		orange = CONFIG.colors.launcher.accent,
	}

	local function mk(name, size, cf, color, material, shape)
		local p = Instance.new("Part")
		p.Name = name
		p.Size = size
		p.CFrame = cf
		p.Color = color
		p.Material = material or Enum.Material.Metal
		p.Shape = shape or Enum.PartType.Block
		p.Anchored = false
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.Massless = true
		p.TopSurface = Enum.SurfaceType.Smooth
		p.BottomSurface = Enum.SurfaceType.Smooth
		p.Parent = parent
		return p
	end

	local y90 = CFrame.Angles(0, math.rad(90), 0)

	-- The root IS the Tool's Handle, so Roblox grips it to the hand and plays
	-- the held pose for us. Invisible; everything else welds to it.
	local root = mk("Handle", Vector3.new(0.3, 0.3, 0.3), CFrame.new(), m.dark, Enum.Material.SmoothPlastic)
	root.Transparency = 1

	local parts = {}
	local function add(p) parts[#parts + 1] = p return p end

	-- grip / trigger / receiver ------------------------------------------------
	-- Three stacked tiers (receiver, top deck, lower housing) instead of one
	-- crate, so the body reads as milled rather than boxed.
	add(mk("Body", Vector3.new(0.54, 0.68, 1.6), CFrame.new(0, 0.16, -0.15), m.metal))
	add(mk("TopDeck", Vector3.new(0.5, 0.1, 1.5), CFrame.new(0, 0.55, -0.15), m.dark))
	add(mk("LowerHousing", Vector3.new(0.44, 0.32, 0.9), CFrame.new(0, -0.2, -0.3), m.metal))

	-- a proper top rail with teeth
	add(mk("TopRail", Vector3.new(0.24, 0.06, 1.1), CFrame.new(0, 0.63, -0.3), m.dark))
	for i = 0, 3 do
		add(mk("RailTooth", Vector3.new(0.28, 0.035, 0.06), CFrame.new(0, 0.67, -0.75 + i * 0.3), m.dark))
	end

	-- pistol grip, trigger group
	local gripRot = CFrame.Angles(math.rad(-14), 0, 0)
	add(mk("Grip", Vector3.new(0.26, 1.0, 0.5), CFrame.new(0, -0.62, 0.2) * gripRot, m.dark, Enum.Material.SmoothPlastic))
	add(mk("GripCap", Vector3.new(0.3, 0.1, 0.54), CFrame.new(0, -1.1, 0.32) * gripRot, m.metal))
	add(mk("TriggerGuard", Vector3.new(0.14, 0.3, 0.46), CFrame.new(0, -0.36, -0.1), m.metal))
	add(mk("Trigger", Vector3.new(0.06, 0.17, 0.05), CFrame.new(0, -0.3, -0.16), m.orange, Enum.Material.SmoothPlastic))

	-- wooden shoulder stock: comb, orange cheek riser and a steel butt plate
	local stockRot = CFrame.Angles(math.rad(7), 0, 0)
	add(mk("Stock", Vector3.new(0.4, 0.66, 1.05), CFrame.new(0, -0.06, 1.0) * stockRot, m.wood, Enum.Material.Wood))
	add(mk("Comb", Vector3.new(0.32, 0.14, 0.9), CFrame.new(0, 0.24, 1.0) * stockRot, m.wood, Enum.Material.Wood))
	add(mk("CheekPiece", Vector3.new(0.32, 0.16, 1.0), CFrame.new(0, 0.31, 1.0), m.orange, Enum.Material.SmoothPlastic))
	add(mk("ButtPlate", Vector3.new(0.42, 0.72, 0.1), CFrame.new(0, -0.06, 1.55) * stockRot, m.dark, Enum.Material.Metal))

	-- iron sights
	add(mk("FrontSight", Vector3.new(0.05, 0.2, 0.06), CFrame.new(0, 0.55, -1.78), m.dark))
	add(mk("RearSightBase", Vector3.new(0.3, 0.06, 0.18), CFrame.new(0, 0.62, 0.42), m.dark))
	add(mk("RearSightL", Vector3.new(0.05, 0.12, 0.18), CFrame.new(-0.09, 0.7, 0.42), m.dark))
	add(mk("RearSightR", Vector3.new(0.05, 0.12, 0.18), CFrame.new(0.09, 0.7, 0.42), m.dark))

	-- sticky drum: a fat fore-aft cylinder, ringed in orange, with six sticky
	-- bombs visible on its face so it reads as a loaded magazine rather than a
	-- plain tube.
	add(mk("Drum", Vector3.new(0.8, 1.1, 1.1), CFrame.new(0, -0.02, -1.28) * y90, m.dark, Enum.Material.Metal, Enum.PartType.Cylinder))
	add(mk("DrumFace", Vector3.new(0.06, 1.0, 1.0), CFrame.new(0, -0.02, -1.66) * y90, m.metal, Enum.Material.Metal, Enum.PartType.Cylinder))
	add(mk("DrumHub", Vector3.new(0.16, 0.24, 0.24), CFrame.new(0, -0.02, -1.71) * y90, m.metal, Enum.Material.Metal, Enum.PartType.Cylinder))
	add(mk("DrumBand", Vector3.new(0.1, 1.16, 1.16), CFrame.new(0, -0.02, -1.6) * y90, m.orange, Enum.Material.SmoothPlastic, Enum.PartType.Cylinder))
	add(mk("DrumBand", Vector3.new(0.1, 1.16, 1.16), CFrame.new(0, -0.02, -0.94) * y90, m.orange, Enum.Material.SmoothPlastic, Enum.PartType.Cylinder))
	for i = 0, 5 do
		local a = i * math.pi / 3
		add(mk("DrumBomb", Vector3.new(0.2, 0.2, 0.2),
			CFrame.new(math.cos(a) * 0.33, -0.02 + math.sin(a) * 0.33, -1.73), m.orange,
			Enum.Material.SmoothPlastic, Enum.PartType.Ball))
	end

	-- barrel: a dark core with slotted shroud rings (the gaps are the vents),
	-- then a muzzle with an orange collar and cap.
	add(mk("BarrelCore", Vector3.new(0.95, 0.3, 0.3), CFrame.new(0, 0.22, -2.0) * y90, m.dark, Enum.Material.Metal, Enum.PartType.Cylinder))
	for i = 0, 2 do
		add(mk("ShroudRing", Vector3.new(0.13, 0.5, 0.5), CFrame.new(0, 0.22, -1.78 - i * 0.2) * y90, m.metal, Enum.Material.Metal, Enum.PartType.Cylinder))
	end
	add(mk("Muzzle", Vector3.new(0.28, 0.46, 0.46), CFrame.new(0, 0.22, -2.46) * y90, m.dark, Enum.Material.Metal, Enum.PartType.Cylinder))
	add(mk("MuzzleRing", Vector3.new(0.07, 0.52, 0.52), CFrame.new(0, 0.22, -2.34) * y90, m.orange, Enum.Material.SmoothPlastic, Enum.PartType.Cylinder))
	add(mk("MuzzleTip", Vector3.new(0.09, 0.4, 0.4), CFrame.new(0, 0.22, -2.62) * y90, m.orange, Enum.Material.SmoothPlastic, Enum.PartType.Cylinder))

	-- The screen: a flat panel bolted to the LEFT side of the receiver and lying
	-- flush with it. Held in first person the gun rides the lower-right of the
	-- view, so this face looks away from you during normal play - which is what
	-- you wanted: it is a proper side panel, not something angled into your eye.
	-- Pressing RightShift swings the whole launcher round so this panel turns to
	-- face you (see the aim step). The part is turned ninety degrees about local
	-- Y so its Back face - where the SurfaceGui is - points out to the gun's
	-- left. Long down the receiver and a little taller than the body, so there is
	-- room for a real readout.
	local screenCf = CFrame.new(-0.3, 0.15, -0.1) * CFrame.Angles(0, math.rad(-90), 0)
	add(mk("ScreenBezel", Vector3.new(1.38, 0.64, 0.06), screenCf * CFrame.new(0, 0, -0.05),
		m.orange, Enum.Material.SmoothPlastic))
	local screen = add(mk("Screen", Vector3.new(1.3, 0.56, 0.05), screenCf,
		m.dark, Enum.Material.SmoothPlastic))
	-- Let the mouse ray hit the panel; the launcher's parts are unqueryable
	-- (CanQuery = false) so the cursor passes through them, and a SurfaceGui only
	-- receives clicks on a part the ray can actually strike.
	screen.CanQuery = true

	launcherScreen = buildLauncherScreen(screen)

	for _, p in ipairs(parts) do
		local w = Instance.new("WeldConstraint")
		w.Part0 = root
		w.Part1 = p
		w.Parent = root
	end

	return root
end

-- The launcher lives inside the Tool with its Handle as the root, so Roblox's
-- own tool grip welds it to the hand and plays the held pose. Nothing to
-- attach or detach by hand.

-- Are we looking out of the character's own eyes right now? The HUD stands
-- down in first person, because the launcher's own screen shows your speed and
-- your charge, and reading both twice just clutters the view.
local function inFirstPerson()
	local character = player.Character
	if not character then return false end
	if player.CameraMode == Enum.CameraMode.LockFirstPerson then return true end
	-- Roblox hides your own body once the camera is inside your head, so this
	-- one signal works no matter how the game wires up its camera.
	local head = character:FindFirstChild("Head")
	return head ~= nil and head.LocalTransparencyModifier > 0.5
end

-- Shift lock pins the mouse to the middle of the screen: Roblox holds it at
-- LockCenter, with a brief LockCurrentPosition as it engages. We do NOT also
-- demand the cursor be hidden - several games (this one included) leave it
-- visible, and requiring both is what silently killed shift lock before.
local function shiftLocked()
	local ok, behaviour = pcall(function() return UserInputService.MouseBehavior end)
	if not ok then return false end
	return behaviour == Enum.MouseBehavior.LockCenter or behaviour == Enum.MouseBehavior.LockCurrentPosition
end

-- The launcher turns to the camera in FIRST PERSON only. Shift lock gives the
-- same aim, but the gun reads fine riding the arm there and following in shift
-- lock just wobbled it around.
local function aimingCamera()
	return inFirstPerson()
end

-- Detonating is an aimed action, though: it belongs to either of the two modes
-- where you are genuinely pointing the launcher at something - first person, and
-- shift lock. Wandering around in plain third person, a stray RMB must not set
-- the bombs off under your own feet. Firing is untouched: LMB still lobs stickies
-- from any camera.
local function detonateArmed()
	return inFirstPerson() or shiftLocked()
end

-- charge bar (bottom-centre, like TF2's sticky charge meter) ----------------

local chargeGui, chargeBack, chargeFill, chargeLabel = nil, nil, nil, nil

local function buildChargeBar()
	local pg = player:FindFirstChild("PlayerGui") or player:WaitForChild("PlayerGui")

	local gui = Instance.new("ScreenGui")
	gui.Name = "StickyChargeGui"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 50
	gui.Parent = pg

	local back = Instance.new("Frame")
	back.Name = "Back"
	back.AnchorPoint = Vector2.new(0, 1)
	back.Position = UDim2.new(0, 16, 1, -150)
	back.Size = UDim2.new(0, 240, 0, 16)
	back.BackgroundColor3 = Color3.fromRGB(18, 18, 22)
	back.BackgroundTransparency = 0.25
	back.BorderSizePixel = 0
	back.Visible = false
	back.Parent = gui
	local bc = Instance.new("UICorner")
	bc.CornerRadius = UDim.new(0, 3)
	bc.Parent = back
	local bs = Instance.new("UIStroke")
	bs.Color = Color3.fromRGB(0, 0, 0)
	bs.Thickness = 1
	bs.Transparency = 0.35
	bs.Parent = back

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.new(0, 0, 1, 0)
	fill.BackgroundColor3 = Color3.fromRGB(255, 150, 40)
	fill.BorderSizePixel = 0
	fill.Parent = back
	local fc = Instance.new("UICorner")
	fc.CornerRadius = UDim.new(0, 3)
	fc.Parent = fill

	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.BackgroundTransparency = 1
	label.Size = UDim2.new(1, 0, 1, 0)
	useMono(label)
	label.TextColor3 = Color3.fromRGB(255, 255, 255)
	label.TextStrokeTransparency = 0.4
	label.TextSize = 12
	label.Text = ""
	label.Parent = back

	return gui, back, fill, label
end

local function updateChargeBar()
	if not chargeBack then return end
	-- On the gun there's already a charge meter, so in first person the HUD bar
	-- would be showing the same thing twice.
	if stickyCharging and enabled and not inFirstPerson() then
		local c = math.clamp((os.clock() - stickyChargeStart) / CONFIG.sticky.chargeTime, 0, 1)
		chargeBack.Visible = true
		chargeFill.Size = UDim2.new(c, 0, 1, 0)
		chargeFill.BackgroundColor3 = Color3.fromRGB(255, math.floor(120 + 120 * c), 40)
		chargeLabel.Text = (c >= 1) and "FULL" or ""
	elseif chargeBack.Visible then
		chargeBack.Visible = false
	end
end

-- speedometer (bottom-left) --------------------------------------------------
-- (built and updated further down, once the movement controller exists)

local speedGui, speedPanel, speedValue = nil, nil, nil
local speedTimer = 0

local toolWired = false

local function wireTool()
	stickyTool.Activated:Connect(function() startStickyCharge() end)
	stickyTool.Deactivated:Connect(function() releaseSticky() end)
	stickyTool.Unequipped:Connect(function()
		stickyCharging = false
	end)
	toolWired = true
end

local launcherRole = {
	Body = "metal", TopDeck = "dark", LowerHousing = "metal",
	TopRail = "dark", RailTooth = "dark",
	Grip = "dark", GripCap = "metal", TriggerGuard = "metal", Trigger = "accent",
	Stock = "wood", Comb = "wood", CheekPiece = "accent", ButtPlate = "dark",
	FrontSight = "dark", RearSightBase = "dark", RearSightL = "dark", RearSightR = "dark",
	Drum = "dark", DrumFace = "metal", DrumHub = "metal", DrumBand = "accent", DrumBomb = "accent",
	BarrelCore = "dark", ShroudRing = "metal", Muzzle = "dark", MuzzleRing = "accent", MuzzleTip = "accent",
	ScreenBezel = "accent", Screen = "dark",
}

local function applyLauncherColors()
	if not launcherRoot or not launcherRoot.Parent then return end
	-- The parts are siblings of the Handle under the Tool, not children of it.
	for _, d in ipairs(launcherRoot.Parent:GetChildren()) do
		if d:IsA("BasePart") and d.Name ~= "Handle" then
			local role = launcherRole[d.Name]
			if role then d.Color = CONFIG.colors.launcher[role] end
		end
	end
end

local function giveStickyTool()
	local backpack = player:FindFirstChildOfClass("Backpack") or player:FindFirstChild("Backpack")
	if not backpack then return end
	if stickyTool and not stickyTool.Parent then stickyTool = nil end
	if stickyTool then
		if stickyTool.Parent ~= backpack and (not player.Character or stickyTool.Parent ~= player.Character) then
			stickyTool.Parent = backpack
		end
	else
		local found = backpack:FindFirstChild("Sticky Jumper")
		if found and found:IsA("Tool") then
			stickyTool = found
		else
			local tool = Instance.new("Tool")
			tool.Name = "Sticky Jumper"
			tool.ToolTip = "Sticky Jumper: LMB fire (hold to charge), RMB detonate"
			tool.RequiresHandle = true
			tool.CanBeDropped = false
			tool.Grip = GRIP
			tool.Parent = backpack
			stickyTool = tool
		end
		toolWired = false
	end

	if not toolWired then wireTool() end

	-- Rebuild the launcher if it lost its parent (say the old Tool got
	-- destroyed). It lives inside the Tool so the Tool can grip it.
	if not launcherRoot or not launcherRoot.Parent then
		launcherRoot = buildLauncher(stickyTool)
		applyLauncherColors()
	end
end

-- launcher aim (first person / shift lock) -----------------------------------
--
-- Roblox grips the launcher to the right hand with its own joint ("RightGrip",
-- Part0 = the arm, Part1 = the Tool's Handle). The arm's pose comes from the
-- animation, so the barrel just sits where the arm happens to point - level,
-- even when you look at your feet. While you are in first person or shift lock
-- we rewrite that joint's C0 every render step, which swings the whole welded
-- rig round to the camera while leaving it exactly on the hand. The moment you
-- leave those modes the original grip is put back.

local aimGrip = nil       -- the grip joint we are driving
local aimGripC0 = nil     -- its untouched C0 / C1, to restore on the way out
local aimGripC1 = nil
local aimDriving = false  -- are we overriding the grip right now?
local aimLastC0 = nil     -- the last C0 we wrote (so we can skip repeats)
local aimMenuYaw = 0      -- eased yaw that swings the screen round when the picker is open
local AIM_MENU_YAW = 55   -- degrees to turn so the gun's left-side panel faces the camera

-- The joint that holds the launcher to the hand (on a Tool that is one Weld
-- whose Part1 is the Handle). We locate it by scanning the character rather than
-- assuming a name, because the engine creates it when the Tool is equipped.
local function findAimGrip()
	local character = player.Character
	if not character or not launcherRoot then return nil end
	for _, x in ipairs(character:GetDescendants()) do
		if (x:IsA("Weld") or x:IsA("Motor6D"))
			and (x.Part0 == launcherRoot or x.Part1 == launcherRoot) then
			return x
		end
	end
	return nil
end

local function releaseAimGrip()
	if aimDriving and aimGrip and aimGrip.Parent then
		pcall(function()
			aimGrip.C0 = aimGripC0
			aimGrip.C1 = aimGripC1
		end)
	end
	aimDriving = false
	aimLastC0 = nil
end

local function stepLauncherAim(dt)
	if not launcherRoot or not launcherRoot.Parent or not stickyToolEquipped() then
		aimGrip = nil
		releaseAimGrip()
		return
	end

	-- The grip disappears with the tool (unequip, respawn); find the new one.
	if not aimGrip or not aimGrip.Parent
		or (aimGrip.Part0 ~= launcherRoot and aimGrip.Part1 ~= launcherRoot) then
		aimDriving = false
		aimLastC0 = nil
		aimGrip = findAimGrip()
		if aimGrip then
			aimGripC0 = aimGrip.C0
			aimGripC1 = aimGrip.C1
		end
		applyLauncherColors()
	end
	if not aimGrip then return end

	if not (CONFIG.aim.enabled and (aimingCamera() or CONFIG.colors.uiOpen)) then
		releaseAimGrip()
		return
	end

	local camera = workspace.CurrentCamera
	if not camera then return end

	local anchor = (aimGrip.Part1 == launcherRoot) and aimGrip.Part0 or aimGrip.Part1
	if not anchor then return end
	local handleIsPart1 = (aimGrip.Part1 == launcherRoot)

	-- Where the grip would hold the launcher untouched, so we turn it in place.
	local restPos
	if handleIsPart1 then
		restPos = (anchor.CFrame * aimGripC0 * aimGripC1:Inverse()).Position
	else
		restPos = (anchor.CFrame * aimGripC1 * aimGripC0:Inverse()).Position
	end

	-- The barrel runs down the model's -Z, which is the CFrame's LookVector, so
	-- copying the camera's Right/Up axes aims it exactly where you are looking.
	local camCf = camera.CFrame
	if CONFIG.aim.pitchOffset ~= 0 then
		camCf = camCf * CFrame.Angles(math.rad(CONFIG.aim.pitchOffset), 0, 0)
	end
	local desired = CFrame.fromMatrix(restPos, camCf.RightVector, camCf.UpVector)

	-- Pressing RightShift swings the launcher round so the panel bolted to its
	-- left side turns to face you, which is the whole point of putting it on the
	-- side. Eased, so it sweeps round rather than snapping.
	local targetYaw = CONFIG.colors.uiOpen and AIM_MENU_YAW or 0
	aimMenuYaw = aimMenuYaw + (targetYaw - aimMenuYaw) * math.min(1, (dt or 0.016) * 12)
	if math.abs(aimMenuYaw) > 0.05 then
		desired = desired * CFrame.Angles(0, math.rad(aimMenuYaw), 0)
	end

	local c0
	if handleIsPart1 then
		c0 = anchor.CFrame:Inverse() * desired * aimGripC1
	else
		c0 = desired:Inverse() * anchor.CFrame * aimGripC1
	end

	-- Skip the write when nothing moved: every C0 change re-solves that joint.
	if aimLastC0
		and (c0.Position - aimLastC0.Position).Magnitude < 1e-4
		and math.abs(c0.LookVector:Dot(aimLastC0.LookVector)) > 0.99995
		and math.abs(c0.UpVector:Dot(aimLastC0.UpVector)) > 0.99995 then
		return
	end

	aimGrip.C0 = c0
	aimLastC0 = c0
	aimDriving = true
end

-- Source movement: air-strafe + auto-bhop (TF2 feel) ------------------------
--
-- The game owns Humanoid.WalkSpeed (a weight script resets it whenever it
-- changes), so we never touch it. Instead we drive the character's horizontal
-- velocity ourselves every physics step with a plane LinearVelocity, which
-- overrides both the humanoid's own movement and the weight cap.

local SOURCE = {
	enabled        = true,  -- master switch for the movement override
	maxSpeed       = 18,    -- ground target speed (studs/s)
	groundAccel    = 12,    -- Quake sv_accelerate (higher = less "slippery")
	airAccel       = 12,    -- Quake/TF2 sv_airaccelerate
	airWishCap     = 2.0,   -- max speed each frame of air-strafing can add
	friction       = 7,     -- Quake sv_friction (while you're steering)
	stopFriction   = 18,    -- stronger friction with no input, so you don't slide
	stopSpeed      = 2,     -- Quake sv_stopspeed
	jumpPower      = 45,    -- bhop jump velocity (studs/s)
	autoBhop       = true,  -- hold Space to bunny-hop
	overrideGround = true,  -- also drive ground movement (false = air only)
	resync         = 8,     -- adopt the real velocity (grounded only) when it drops this much
	ceiling        = 150,   -- hard cap on horizontal speed (safety)
	autoStrafe     = false, -- assist: while airborne, aim the wish sideways for max gain
	autoStrafeTurn = 150,   -- degrees/sec the assist may turn you (stops it spinning)
}

smState = {
	hv = Vector3.new(),      -- our authoritative horizontal velocity
	override = nil,          -- test hook: a wish direction to use instead of input
	holdJump = false,        -- test hook: pretend Space is held
	ignoreKeys = false,      -- test hook: pretend no movement keys are held
	strafeLeft = false,      -- which way the auto-strafe is currently curving
	blastHold = 0,           -- seconds of post-blast grace (no friction / resync)
	softCeil = 0,            -- temporary lift on the speed cap after a blast
}

-- speedometer (bottom-centre). Lives here so it can read the movement config.
-- Just your speed: the launcher's own screen carries it while you're in first
-- person (and the charge meter with it).
local function buildSpeedo()
	local pg = player:FindFirstChild("PlayerGui") or player:WaitForChild("PlayerGui")

	local gui = Instance.new("ScreenGui")
	gui.Name = "StickySpeedoGui"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 50
	gui.Parent = pg

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(0, 1)
	-- Left side, lifted just above the hotbar and below the charge meter.
	panel.Position = UDim2.new(0, 16, 1, -84)
	panel.Size = UDim2.new(0, 132, 0, 50)
	panel.BackgroundColor3 = Color3.fromRGB(14, 14, 18)
	panel.BackgroundTransparency = 0.35
	panel.BorderSizePixel = 0
	panel.Parent = gui
	local pc = Instance.new("UICorner")
	pc.CornerRadius = UDim.new(0, 5)
	pc.Parent = panel
	local ps = Instance.new("UIStroke")
	ps.Color = Color3.fromRGB(0, 0, 0)
	ps.Thickness = 1
	ps.Transparency = 0.4
	ps.Parent = panel

	local value = Instance.new("TextLabel")
	value.Name = "Value"
	value.BackgroundTransparency = 1
	value.Position = UDim2.new(0, 0, 0, 0)
	value.Size = UDim2.new(1, 0, 1, 0)
	useMono(value)
	value.TextXAlignment = Enum.TextXAlignment.Center
	value.TextSize = 28
	value.TextColor3 = Color3.fromRGB(255, 255, 255)
	value.Text = "0"
	value.Parent = panel

	return gui, panel, value
end

local function updateSpeedo(dt)
	if not speedPanel then return end
	-- In first person the launcher's own screen is showing your speed (and the
	-- charge meter), so the HUD panel steps aside entirely.
	speedPanel.Visible = enabled and not inFirstPerson()
	if not speedPanel.Visible then return end

	speedTimer = speedTimer + dt
	if speedTimer < 0.05 then return end
	speedTimer = 0

	local character = player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	local speed = 0
	if hrp then
		local v = hrp.AssemblyLinearVelocity
		speed = math.sqrt(v.X * v.X + v.Z * v.Z)
	end

	speedValue.Text = string.format("%d", math.floor(speed + 0.5))
	-- White while you're at normal running speed, heating to orange as you fly
	-- past it (roughly the point where a blast or a bhop chain is carrying you).
	local heat = math.clamp(speed / (SOURCE.maxSpeed * 2), 0, 1)
	speedValue.TextColor3 = Color3.fromRGB(255, 255 - math.floor(120 * heat), 255 - math.floor(255 * heat))
end

-- Feed the launcher's own screen. Same numbers as the HUD, just mounted on the
-- gun so first-person play keeps them in view. The panel stays dark unless
-- you're actually looking through the gun: in third person the HUD is doing
-- the readouts, so there's no reason for the model's screen to be lit (and a
-- glowing screen floating on your back is just noise).
local screenTimer = 0
local function updateLauncherScreen(dt)
	if not launcherScreen then return end
	local tool = stickyTool
	local held = enabled and tool ~= nil and tool.Parent ~= nil and tool.Parent == player.Character
	local on = held and (inFirstPerson() or CONFIG.colors.uiOpen)
	if launcherScreen.gui.Enabled ~= on then launcherScreen.gui.Enabled = on end
	if not on then return end

	screenTimer = screenTimer + dt
	if screenTimer < 0.05 then return end
	screenTimer = 0

	local character = player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	local speed = 0
	if hrp then
		local v = hrp.AssemblyLinearVelocity
		speed = math.sqrt(v.X * v.X + v.Z * v.Z)
	end
	launcherScreen.value.Text = string.format("%d", math.floor(speed + 0.5))
	local heat = math.clamp(speed / (SOURCE.maxSpeed * 2), 0, 1)
	launcherScreen.value.TextColor3 = Color3.fromRGB(255, 255 - math.floor(120 * heat), 255 - math.floor(255 * heat))

	local c = 0
	if stickyCharging and enabled then
		c = math.clamp((os.clock() - stickyChargeStart) / CONFIG.sticky.chargeTime, 0, 1)
	end
	launcherScreen.fill.Size = UDim2.new(c, 0, 1, 0)
	launcherScreen.fill.BackgroundColor3 = Color3.fromRGB(255, math.floor(120 + 120 * c), 40)
end

local function smGroundFriction(hv, dt, friction)
	friction = friction or SOURCE.friction
	local speed = hv.Magnitude
	if speed < 1e-3 then return Vector3.new() end
	local control = math.max(speed, SOURCE.stopSpeed)
	local newSpeed = math.max(speed - control * friction * dt, 0)
	return hv * (newSpeed / speed)
end

local function smAccelerate(hv, dir, wishSpeed, accel, dt)
	local current = hv:Dot(dir)
	local add = wishSpeed - current
	if add <= 0 then return hv end
	local accelSpeed = math.min(accel * wishSpeed * dt, add)
	return hv + dir * accelSpeed
end

local function smAirAccelerate(hv, dir, wishSpeed, accel, cap, dt)
	local wishSpd = math.min(wishSpeed, cap)
	local current = hv:Dot(dir)
	local add = wishSpd - current
	if add <= 0 then return hv end
	local accelSpeed = math.min(accel * wishSpeed * dt, add)
	return hv + dir * accelSpeed
end

-- Rotate `new` toward `old`'s heading by at most maxAng, keeping `new`'s length.
-- Used by the auto-strafe assist: it keeps the full speed gain but only lets the
-- velocity swing around slowly, so you curve instead of pirouetting.
local function smLimitTurn(old, new, maxAng)
	local om, nm = old.Magnitude, new.Magnitude
	if om < 1e-3 or nm < 1e-3 then return new end
	local a, b = old / om, new / nm
	local ang = math.acos(math.clamp(a:Dot(b), -1, 1))
	if ang <= maxAng then return new end
	local axis = a:Cross(b)
	if axis.Magnitude < 1e-4 then return new end
	return (CFrame.fromAxisAngle(axis.Unit, maxAng) * a) * nm
end

local function smWishDir()
	if smState.override then return smState.override end
	if smState.ignoreKeys then return nil end
	-- Keys pressed while a chat/text box has focus belong to that text box. Read
	-- with IsKeyDown they still look like movement keys, so typing "w" used to
	-- walk you forward; bail out instead.
	if UserInputService:GetFocusedTextBox() then return nil end
	local cam = workspace.CurrentCamera
	if not cam then return nil end
	local forward = (UserInputService:IsKeyDown(Enum.KeyCode.W) and 1 or 0) - (UserInputService:IsKeyDown(Enum.KeyCode.S) and 1 or 0)
	local strafe  = (UserInputService:IsKeyDown(Enum.KeyCode.D) and 1 or 0) - (UserInputService:IsKeyDown(Enum.KeyCode.A) and 1 or 0)
	if forward == 0 and strafe == 0 then return nil end
	local f = cam.CFrame.LookVector
	local r = cam.CFrame.RightVector
	f = Vector3.new(f.X, 0, f.Z)
	r = Vector3.new(r.X, 0, r.Z)
	if f.Magnitude < 1e-3 then f = Vector3.new(0, 0, -1) end
	if r.Magnitude < 1e-3 then r = Vector3.new(1, 0, 0) end
	local wish = f.Unit * forward + r.Unit * strafe
	if wish.Magnitude < 1e-3 then return nil end
	return wish.Unit
end

local function smTeardown()
	if smState.constraint then
		smState.constraint:Destroy()
		smState.constraint = nil
	end
	if smState.attachment then
		smState.attachment:Destroy()
		smState.attachment = nil
	end
end

-- Destroy anything a previous run leaked onto the character (an older build
-- used to error after parenting and leave an Attachment behind every frame).
local function smCleanStrays(character)
	if not character then return end
	for _, d in ipairs(character:GetDescendants()) do
		if (d.Name == "SourceMoveAtt" or d.Name == "SourceMove")
			and d ~= smState.attachment and d ~= smState.constraint then
			pcall(function() d:Destroy() end)
		end
	end
end

-- A LinearVelocity in Plane mode holds the horizontal (X/Z) velocity steady
-- while leaving Y to gravity. It overpowers the humanoid's own ground/air
-- movement, so the character keeps whatever speed we give it (and can exceed
-- the game's weight-capped WalkSpeed).
--
-- IMPORTANT: build the instances completely before parenting anything, and
-- destroy them if any step fails. Parenting early and then erroring leaks one
-- instance per physics step, which freezes the client.
local function smEnsureMovement(hrp)
	if smState.constraint and smState.constraint.Parent == hrp then return true end
	if smState.buildFailed then return false end
	smTeardown()

	local att = Instance.new("Attachment")
	att.Name = "SourceMoveAtt"
	local lv = Instance.new("LinearVelocity")
	lv.Name = "SourceMove"
	local ok, err = pcall(function()
		lv.Attachment0 = att
		lv.RelativeTo = Enum.ActuatorRelativeTo.World
		lv.VelocityConstraintMode = Enum.VelocityConstraintMode.Plane
		-- The plane is defined by the two tangent axes (their cross product is
		-- the normal), so gravity along Y is left alone.
		lv.PrimaryTangentAxis = Vector3.new(1, 0, 0)
		lv.SecondaryTangentAxis = Vector3.new(0, 0, 1)
		lv.PlaneVelocity = Vector2.new(0, 0)
		lv.MaxForce = 1e6
	end)
	if not ok then
		lv:Destroy()
		att:Destroy()
		if smState.warn == nil then
			smState.warn = tostring(err)
			warn("[StickyJumper] Source movement disabled (LinearVelocity unsupported): " .. smState.warn)
		end
		smState.buildFailed = true
		return false
	end

	-- Parent only once everything above succeeded.
	lv.Parent = hrp
	att.Parent = hrp
	smState.constraint = lv
	smState.attachment = att
	return true
end

local function stepSource(dt)
	if not enabled or not SOURCE.enabled then
		smTeardown()
		return
	end
	local character = player.Character
	if not character then return end
	local hum = character:FindFirstChildOfClass("Humanoid")
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if not hum or not hrp or hum.Health <= 0 then
		smTeardown()
		return
	end

	if not smEnsureMovement(hrp) then
		-- Can't build the velocity constraint here; turn the whole override off
		-- rather than fight the humanoid every frame.
		SOURCE.enabled = false
		smTeardown()
		return
	end

	local v = hrp.AssemblyLinearVelocity
	local actual = Vector3.new(v.X, 0, v.Z)
	local grounded = hum.FloorMaterial ~= Enum.Material.Air

	local realSpeed = actual.Magnitude
	if realSpeed > stats.peak then stats.peak = realSpeed end

	-- A blast shields the launch for a beat and lifts the speed cap; the lift
	-- then bleeds back down so the arc settles smoothly instead of snapping.
	if (smState.blastHold or 0) > 0 then
		smState.blastHold = math.max(0, smState.blastHold - dt)
	end
	local ceiling = SOURCE.ceiling
	if (smState.softCeil or 0) > ceiling then ceiling = smState.softCeil end

	-- On the ground the real velocity is the truth (we hit a wall, a slope, a
	-- moving part). In the air we deliberately keep our own value: the humanoid
	-- air-brakes a little every step, and adopting that "real" velocity used to
	-- wipe out everything air-strafing had built up. During the blast grace we
	-- keep our own value even on the ground, or a bomb at your feet would be
	-- dragged straight back to a standstill.
	if grounded and smState.blastHold <= 0
		and actual.Magnitude < smState.hv.Magnitude - SOURCE.resync then
		smState.hv = actual
	end
	if smState.hv.Magnitude > ceiling then
		smState.hv = smState.hv.Unit * ceiling
	end

	local wish = smWishDir()
	local hv = smState.hv
	-- Spacebar is a movement key for us but a plain character in chat.
	local typing = UserInputService:GetFocusedTextBox() ~= nil
	local jumpHeld = smState.holdJump
		or (not typing and UserInputService:IsKeyDown(Enum.KeyCode.Space))

	-- Jump FIRST (Quake order). Jumping clears "grounded" before friction runs,
	-- so the frame you touch down is the frame you leave again and a bunny-hop
	-- keeps 100% of the speed it landed with.
	if smState.blastHold > 0 then
		-- Blast grace: leave the launch untouched. Skipping ground friction and
		-- the "adopt the real velocity" branch is what lets a bomb at your feet
		-- throw you instead of being braked away the frame it fires.
	elseif grounded and SOURCE.autoBhop and jumpHeld then
		local vy = math.max(SOURCE.jumpPower, hum.JumpPower)
		hrp.AssemblyLinearVelocity = Vector3.new(hv.X, vy, hv.Z)
		grounded = false
		-- another link in the bunny-hop chain
		stats.chain = stats.chain + 1
	elseif grounded and SOURCE.overrideGround then
		-- Coast to a stop hard with no input, so the character doesn't feel
		-- like it's standing on ice.
		stats.chain = 0
		hv = smGroundFriction(hv, dt, wish and SOURCE.friction or SOURCE.stopFriction)
		if wish then
			hv = smAccelerate(hv, wish, SOURCE.maxSpeed, SOURCE.groundAccel, dt)
		elseif hv.Magnitude < SOURCE.stopSpeed then
			hv = Vector3.new()
		end
	elseif grounded then
		stats.chain = 0
		hv = actual
	end

	-- Auto air-strafe assist: while airborne, point the wish straight sideways
	-- off your current heading, which is where air-acceleration gives the most.
	-- (With the default small airWishCap you only gain speed when the wish is
	-- near-perpendicular.) It only engages while you're holding a movement key.
	local turning = false
	if not grounded and SOURCE.autoStrafe and wish then
		local flat = Vector3.new(hv.X, 0, hv.Z)
		if flat.Magnitude > 4 then
			local vdir = flat.Unit
			local perp = Vector3.new(-vdir.Z, 0, vdir.X)   -- right of the heading
			-- Which way to curve: the side the player's input is on. Deciding it
			-- from the input's angle to the *velocity* re-flipped it every frame
			-- as the heading drifted, so the assist wobbled on the spot instead
			-- of banking; against the camera it stays put (and W alone, sitting
			-- dead ahead, leaves the last choice alone).
			local cam = workspace.CurrentCamera
			if cam then
				local r = cam.CFrame.RightVector
				r = Vector3.new(r.X, 0, r.Z)
				if r.Magnitude > 1e-3 then
					local side = wish:Dot(r.Unit)
					if math.abs(side) > 0.2 then smState.strafeLeft = side < 0 end
				end
			end
			if smState.strafeLeft then perp = -perp end
			wish = perp
			turning = true
		end
	end

	if not grounded and wish then
		local before = hv
		hv = smAirAccelerate(hv, wish, SOURCE.maxSpeed, SOURCE.airAccel, SOURCE.airWishCap, dt)
		if turning then
			hv = smLimitTurn(before, hv, math.rad(SOURCE.autoStrafeTurn) * dt)
		end
	end

	if hv.Magnitude > ceiling then
		hv = hv.Unit * ceiling
	end

	-- Bleed the post-blast cap lift back down to the real ceiling so the extra
	-- speed fades out over about half a second instead of stopping dead.
	if (smState.softCeil or 0) > SOURCE.ceiling then
		smState.softCeil = math.max(SOURCE.ceiling,
			smState.softCeil - (CONFIG.blast.ceilingDecay or 220) * dt)
	end

	smState.hv = hv
	smState.constraint.PlaneVelocity = Vector2.new(hv.X, hv.Z)
end

-- parachute (fall-damage saver) ---------------------------------------------
-- Fall damage comes from how fast you're going when you hit the ground, so the
-- chute only has to beat that: the moment you're falling fast and the ground is
-- close, clamp the descent to a gentle speed. The landing is then too soft to
-- hurt, and air-strafing keeps working all the way down.

local chuteOpen = false
local chuteYaw = 0   -- the heading the canopy is currently trimmed to
local chuteRepair = 0 -- last time we had to rebuild a swept-away rig
local chute = { model = nil, root = nil, rig = nil, torso = nil, hrp = nil, rootWeld = nil, align = nil, socket = nil, parts = {}, wear = {}, d = 1, lastE = nil, roll = nil, lean = 0, lastC0 = nil }

-- The canopy palette lives in CONFIG.colors.parachute, so the colour picker can
-- retune it and a rebuilt rig simply reads the new values. This table forwards
-- every lookup there (with a couple of legacy aliases), which keeps the build
-- code below unchanged.
local CHUTE = setmetatable({}, {
	__index = function(_, k)
		local P = CONFIG.colors.parachute
		if k == "pack2" then return P.pack end
		if k == "rip" then return P.rip or P.glow end
		return P[k]
	end,
})

-- Chute geometry, in the root's local frame - an UPRIGHT frame built at the
-- torso's centre, with no pitch or roll of its own. The rig is CARRIED by the
-- HumanoidRootPart and re-aimed there every frame (see stepChute), so the canopy
-- hangs off your torso's centre - following a crouch or a prone - without ever
-- inheriting the torso's own pitch. The canopy hangs a long way up - its lower
-- edge sits 9 studs above the torso centre, about 7.5 above the top of your
-- head - and is leaned 20 degrees back over the backpack, so the cloth never
-- crosses your face.
local CHUTE_HARNESS = Vector3.new(0, 0.15, 0.6) -- the harness point (in the pack)
local CHUTE_TILT    = math.rad(20)              -- lean the canopy back
local CHUTE_BACK    = 0.6                       -- set the canopy this far back
local CHUTE_RIM     = 9.0    -- height of the canopy's lower edge
local CHUTE_EDGE    = 4.4    -- radius of the canopy's lower edge
local CHUTE_DOME    = 3.0    -- how far the cloth rises above that edge
local CHUTE_GLOW    = 8.4    -- lantern, hanging under the canopy
local CHUTE_DEPLOY  = 0.3    -- seconds for the canopy to snap open
local CHUTE_SHRINK  = 0.12   -- size of the canopy at the very start of the pop

-- A thin part spanning a -> b, for the shroud lines and canopy seams.
local function makeBeam(a, b, thickness, color, transparency)
	local d = b - a
	local len = math.max(d.Magnitude, 0.05)
	local p = Instance.new("Part")
	p.Size = Vector3.new(thickness, thickness, len)
	p.CFrame = CFrame.lookAt(a + d * 0.5, b)
	p.Color = color
	p.Material = Enum.Material.SmoothPlastic
	p.Transparency = transparency or 0
	p.Anchored = false
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Massless = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	return p
end

-- A round part (canopy, cap, scallop beads).
local function makeBall(size, cf, color, transparency)
	local p = Instance.new("Part")
	p.Shape = Enum.PartType.Ball
	p.Size = size
	p.CFrame = (typeof(cf) == "Vector3") and CFrame.new(cf) or cf
	p.Color = color
	p.Material = Enum.Material.Fabric
	p.Transparency = transparency or 0
	p.Anchored = false
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Massless = true
	return p
end

-- A box part (harness pack, ripcord).
local function makeBox(size, cf, color, transparency, material)
	local p = Instance.new("Part")
	p.Size = size
	p.CFrame = (typeof(cf) == "Vector3") and CFrame.new(cf) or cf
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	p.Transparency = transparency or 0
	p.Anchored = false
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Massless = true
	return p
end

local chuteTweens = {}
local function cancelChuteTweens()
	for _, tw in ipairs(chuteTweens) do
		pcall(function() tw:Cancel() end)
	end
	table.clear(chuteTweens)
end

local function buildParachute(base, gearBase)
	gearBase = gearBase or base
	chute.parts = {}
	chute.wear = {}
	local model = Instance.new("Model")
	model.Name = "ParachuteModel"

	local root = Instance.new("Part")
	root.Name = "ChuteRoot"
	root.Size = Vector3.new(0.2, 0.2, 0.2)
	root.CFrame = base
	root.Transparency = 1
	-- The root is the rig's hub: attachParachute welds it to the torso, and every
	-- canopy part is welded to it. That chain is what makes the canopy follow you
	-- exactly - the engine solves it inside the same physics step that moves your
	-- body, instead of us re-posing the rig by hand one step behind. It has to be
	-- unanchored for those welds to have any effect (an anchored root ignores
	-- them), and massless so a small hub part never fights your character.
	root.Anchored = false
	root.CanCollide = false
	root.CanQuery = false
	root.CanTouch = false
	root.Massless = true
	root.Parent = model
	model.PrimaryPart = root

	-- add(part, visibleTransparency, alwaysVisible, wornOnBody)
	-- Canopy parts are NEVER anchored: attachParachute welds each one to the root
	-- (and the root to your torso), which is what makes the engine carry the
	-- whole canopy inside the same physics step that moves your body. A weld
	-- cannot move an anchored part, so leaving one anchored would strand that
	-- panel in the sky.
	-- driveChute only writes those welds while the canopy is popping open. Once
	-- it is out there is nothing left to update per frame.
	-- Worn parts (pack, ripcord) aren't driven at all: attachParachute welds
	-- them straight to the torso so they sit on the body like real gear.
	local function add(part, t, always, wear)
		part.Parent = model
		local rel
		if wear then
			chute.wear[#chute.wear + 1] = part
		else
			rel = root.CFrame:Inverse() * part.CFrame
		end
		-- Remember which palette slot this part was painted from, so the colour
		-- picker can repaint a live rig in place instead of rebuilding it.
		local role
		local P = CONFIG.colors.parachute
		for k, v in pairs(P) do
			if v == part.Color then role = k break end
		end
		chute.parts[#chute.parts + 1] = { part = part, t = t, always = always, size = part.Size, rel = rel, role = role, color = part.Color }
		return part
	end

	local BACK = CHUTE_BACK
	-- Pivot the whole canopy backwards about the harness point.
	local canopy = base * CFrame.new(CHUTE_HARNESS) * CFrame.Angles(CHUTE_TILT, 0, 0) * CFrame.new(-CHUTE_HARNESS)

	-- Which canopy the user picked on the launcher screen. The palette is
	-- shared; only the shape and the striping change. "classic" alternates the
	-- gores, "stripe" is white with red stripes, "army" is one matte colour and
	-- "wing" is the rectangular ram-air below.
	local design = (CONFIG.parachute and CONFIG.parachute.design) or "classic"

	local function buildWingCanopy()
		-- A ram-air wing: a row of inflated cells along a lightly anhedral span,
		-- closed by a rounded leading edge, with a shroud line off each cell
		-- corner. Where the round canopy is revolved, this is extruded - the same
		-- palette, an entirely different silhouette.
		local SPAN = 9.4
		local NC = 8
		local CELLW = SPAN / NC
		local CHORD = 3.4
		local THICK = 1.15
		local TOPY = CHUTE_RIM + 2.3
		local ANHEDRAL = 1.1
		local clothMat = (design == "army") and Enum.Material.Fabric or Enum.Material.SmoothPlastic
		local function spanY(x)
			local t = x / (SPAN * 0.5)
			return TOPY - ANHEDRAL * t * t
		end
		local function cellColour(i)
			if design == "army" then return CHUTE.canopy end
			if i == 0 or i == NC - 1 then return CHUTE.panel end
			if design == "stripe" and (i % 2 == 1) then return CHUTE.panel end
			return CHUTE.canopy
		end
		local centers = {}
		for i = 0, NC - 1 do
			local x = -SPAN * 0.5 + (i + 0.5) * CELLW
			local y = spanY(x)
			centers[i + 1] = Vector3.new(x, y, BACK)
			add(makeBox(Vector3.new(CELLW * 0.98, THICK, CHORD),
				canopy * CFrame.new(x, y, BACK), cellColour(i), 0.03, clothMat), 0.03)
			local nose = makeBox(Vector3.new(CELLW * 0.99, THICK, THICK),
				canopy * CFrame.new(x, y, BACK - CHORD * 0.5), cellColour(i), 0.03, clothMat)
			nose.Shape = Enum.PartType.Cylinder
			add(nose, 0.03)
		end
		-- seam ribs stood proud between the cells
		for i = 0, NC - 2 do
			local xs = -SPAN * 0.5 + (i + 1) * CELLW
			add(makeBox(Vector3.new(0.09, THICK + 0.14, CHORD * 0.94),
				canopy * CFrame.new(xs, spanY(xs), BACK), CHUTE.rim, 0.1, clothMat), 0.1)
		end
		-- rigging: a line off the leading and trailing bottom corner of each cell
		local gather = canopy * Vector3.new(0, CHUTE_RIM - 2.1, BACK)
		for i = 1, NC do
			local c = centers[i]
			add(makeBeam(canopy * (c + Vector3.new(0, -THICK * 0.5, -CHORD * 0.5)), gather, 0.055, CHUTE.cord, 0.18), 0.18)
			add(makeBeam(canopy * (c + Vector3.new(0, -THICK * 0.5, CHORD * 0.5)), gather, 0.055, CHUTE.cord, 0.18), 0.18)
		end
		local harness = base * CFrame.new(CHUTE_HARNESS)
		for l = 0, 3 do
			local a = l * (math.pi / 2)
			add(makeBeam(gather, harness.p + Vector3.new(math.cos(a) * 0.3, 0, math.sin(a) * 0.3),
				0.08, CHUTE.cord, 0.2), 0.2)
		end
	end

	if design ~= "wing" then
		-- The canopy is a HOLLOW SHELL, not a ball: thin cloth panels laid along a
		-- domed profile, OPEN UNDERNEATH, so from below you are looking up into it.
		--
		-- The pattern is the classic round canopy: TWELVE WEDGE GORES, with the
		-- colours alternating scarlet and off-white all the way round, so the canopy
		-- reads as a real parachute from every angle instead of one smooth blob.
		-- Each gore bellies out between its two seams (FLUTE) and the hem lifts
		-- between the rigging points (SCALLOP), so the silhouette is a soft scalloped
		-- curve and the seam tape sits down in the creases where it belongs.
		--
		-- Colour is carried per GORE, not per panel: every panel inside a gore is the
		-- same colour, so the only lines that show are the ones that mean something -
		-- the twelve gores, the navy hem band and the navy vent. That is what stops a
		-- many-panel canopy reading as "planks bolted together"; a row seam running
		-- through one colour is an invisible seam.
		--
		-- Every piece of it - cloth, vent cap, gore seams, hems, shroud lines - is
		-- placed by the one profile below. That matters: the old canopy asked twice
		-- and the two answers disagreed, leaving the cap and the whole cord ring
		-- floating 0.6 studs off the back of the cloth. That was the "dislocated
		-- dome".
		--
		-- The cloth is SmoothPlastic rather than Fabric, because Fabric carries a
		-- woven grain that at distance looks like the surface is dirty or speckled.
		-- SEGS is high (48, so each facet turns only seven and a half degrees) so the
		-- silhouette and the shading stay close to a curve instead of reading as a
		-- polygon.
		local R = CHUTE_EDGE
		local SEGS = 48                                 -- cloth panels round the rim
		local GORES = 12                                -- gores, and so shroud lines
		local SCALLOP = 0.30                            -- how far the hem lifts between lines
		local FLUTE = 0.09                              -- how far a gore bellies between seams
		local FLARE = 0.20                              -- how far the skirt bells out
		-- Three rows: a navy hem band, then two rows carrying the scarlet/off-white
		-- gores all the way up to the vent. Colour is chosen per GORE, so the stripes
		-- run unbroken from hem to apex and the row seam across them is invisible.
		local bands = { { 1.00, 0.88 }, { 0.88, 0.50 }, { 0.50, 0.12 } }
		-- Army flies a deeper, matte dome; the others keep the classic profile.
		local DOME = CHUTE_DOME * ((design == "army") and 1.18 or 1.0)
		local clothMat = (design == "army") and Enum.Material.Fabric or Enum.Material.SmoothPlastic
		-- Colour by design: army is one flat colour, "stripe" is white with a red
		-- stripe every third gore, and "classic" alternates the gores all the way
		-- round the canopy.
		local function goreColour(bi, gore)
			if design == "army" then return CHUTE.canopy end
			if bi == 1 then return CHUTE.rim end
			if design == "stripe" then
				return (gore % 3 == 2) and CHUTE.panel or CHUTE.canopy
			end
			return (gore % 2 == 0) and CHUTE.canopy or CHUTE.panel
		end
		local function domeY(f) return CHUTE_RIM + DOME * (1 - f * f) end
		-- f runs 1 at the hem and 0 at the vent. The radius is round through the
		-- middle and bells out over the last stretch, the way a skirt flares.
		local function domeR(f)
			local bell = math.max(0, (f - 0.84) / 0.16)
			return R * f + FLARE * bell * bell
		end
		-- How far across its own gore an azimuth sits, 0..1, with 0 on a seam line.
		local function goreFrac(a)
			local g = a / (math.pi * 2 / GORES)
			return g - math.floor(g)
		end
		-- A point on the cloth, in the canopy's own frame. The gore bellies out at
		-- its centre and tucks back to the bare dome radius on the seams; lifting
		-- hangs the hem low at the rigging points and lifts it between them.
		local function cloth(f, a, lifting)
			local gf = goreFrac(a)
			local dy = lifting and (SCALLOP * math.sin(math.pi * gf)) or 0
			local r = domeR(f) * (1 + FLUTE * math.sin(math.pi * gf))
			return Vector3.new(math.cos(a) * r, domeY(f) + dy, math.sin(a) * r + BACK)
		end

		-- The cloth. Each panel is a hair wider than the arc it covers so neighbours
		-- overlap instead of leaving slits, and neighbouring panels are nudged a few
		-- hundredths of a stud either side of the surface so that overlap cannot
		-- z-fight.
		for bi, band in ipairs(bands) do
			local f1, f2 = band[1], band[2]
			local chord = 2 * domeR(f1) * (1 + FLUTE) * math.sin(math.pi / SEGS) * 1.06
			for i = 0, SEGS - 1 do
				-- Panel centres are offset half a panel so the panel EDGES land on the
				-- gore lines - which is where a real canopy's seams are sewn and where
				-- the shroud lines pull, so the cloth's creases, the seam tape and the
				-- cords all end up in the same place instead of half a panel apart.
				local a = (i + 0.5) * (math.pi * 2 / SEGS)
				local gore = math.floor(i / (SEGS / GORES))
				local colour = goreColour(bi, gore)
				local pa = cloth(f1, a, bi == 1)
				local pb = cloth(f2, a, false)
				local slope = pa - pb
				local tangent = Vector3.new(-math.sin(a), 0, math.cos(a))
				local slant = slope.Unit
				local face = slant:Cross(tangent).Unit
				local nudge = ((i % 2 == 0) and 0.03) or -0.03
				local cf = CFrame.fromMatrix((pa + pb) * 0.5 + face * nudge, tangent, face, slant)
				local box = makeBox(Vector3.new(chord, 0.1, slope.Magnitude), canopy * cf, colour, 0.06, clothMat)
				add(box, 0.06)
			end
		end

		-- the vent: a navy cap over the hole at the top, so the apex reads as a vent
		-- rather than a point, with the gore stripes running right up to it. Sized
		-- past the crest of the top row, because a fluted gore stands proud of the
		-- bare dome radius and a cap cut to that radius would leave a ring of daylight.
		local capF = bands[#bands][2]
		local capR = domeR(capF) * 1.3
		local capColour = (design == "army") and CHUTE.canopy or CHUTE.rim
		local cap = makeBox(Vector3.new(0.12, capR * 2, capR * 2),
			canopy * CFrame.new(0, domeY(capF) + 0.04, BACK) * CFrame.Angles(0, 0, math.rad(90)),
			capColour, 0.06, clothMat)
		cap.Shape = Enum.PartType.Cylinder
		add(cap, 0.06)

		-- Rigging, done the way a real chute is rigged: pale seam tape down every
		-- gore line, a shroud line off every seam, the lines gathering at one point
		-- under the canopy, and four risers carrying that point down your back to the
		-- harness. The tape rides a little proud of the cloth so it reads as a seam
		-- instead of vanishing into the panels, and its chain uses the same f stops
		-- as the cloth rows, so every segment of it lies on the cloth.
		local stops = { bands[1][1] }
		for _, band in ipairs(bands) do stops[#stops + 1] = band[2] end
		-- Looking straight down a seam line, the cloth you actually SEE is the crest
		-- of the two panels meeting there, not the bare dome radius underneath them,
		-- so the tape hangs on that radius - otherwise the fluted gores swallow it.
		local perGore = SEGS / GORES
		local SEAM_CREST = 1 + FLUTE * math.sin(math.pi / (2 * perGore))
		local function seamPoint(f, a)
			local r = domeR(f) * SEAM_CREST
			return Vector3.new(math.cos(a) * r, domeY(f), math.sin(a) * r + BACK)
		end
		local harness = base * CFrame.new(CHUTE_HARNESS)
		local gather = canopy * Vector3.new(0, CHUTE_RIM - 2.1, BACK)
		for g = 0, GORES - 1 do
			-- The seam runs down the gore line, and its hem END is the scallop's LOW
			-- point - the place a real canopy's lines are sewn, because it is the
			-- point the suspension pulls down.
			local a = g * (math.pi * 2 / GORES)
			local proud = Vector3.new(math.cos(a) * 0.05, 0, math.sin(a) * 0.05)
			local hem = seamPoint(bands[1][1], a)

			local prev = nil
			for _, f in ipairs(stops) do
				local p = seamPoint(f, a) + proud
				if prev then add(makeBeam(canopy * prev, canopy * p, 0.09, CHUTE.rib, 0.04), 0.04) end
				prev = p
			end

			add(makeBeam(canopy * hem, gather, 0.065, CHUTE.cord, 0.15), 0.15)
		end

		-- the risers: gathering point down to the pack, spread a little at the harness
		for l = 0, 3 do
			local a = l * (math.pi / 2)
			add(makeBeam(gather, harness.p + Vector3.new(math.cos(a) * 0.3, 0, math.sin(a) * 0.3),
				0.08, CHUTE.cord, 0.2), 0.2)
		end
	else
		buildWingCanopy()
	end

	-- a lantern hanging under the canopy, lit only while deployed. The orb
	-- itself is invisible; only its PointLight shows.
	local glow = makeBall(Vector3.new(0.9, 0.9, 0.9), canopy * CFrame.new(0, CHUTE_GLOW, BACK), CHUTE.glow, 1)
	glow.Name = "ChuteLight"
	glow.Material = Enum.Material.Neon
	glow.Transparency = 1
	local light = Instance.new("PointLight")
	light.Color = CHUTE.glow
	light.Brightness = 4
	light.Range = 26
	light.Shadows = false
	light.Enabled = false
	light.Parent = glow
	chute.light = light
	chute.hue = 0
	add(glow, 1)

	-- The harness: an actual pack instead of a plain brick. It is built in the
	-- torso's own frame (gearBase), because it is welded to the torso and has to
	-- sit where the body actually is - unlike the canopy above, which is built
	-- upright so its lean is always the one we designed.
	local wearGear = function(part) return add(part, 0, true, true) end
	local function gear(size, cf, color, material)
		return wearGear(makeBox(size, gearBase * cf, color, 0, material))
	end
	local function gearCyl(size, cf, color, material)
		local p = Instance.new("Part")
		p.Shape = Enum.PartType.Cylinder
		p.Size = size
		p.CFrame = gearBase * cf
		p.Color = color
		p.Material = material or Enum.Material.Fabric
		p.Anchored = false
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.Massless = true
		p.TopSurface = Enum.SurfaceType.Smooth
		p.BottomSurface = Enum.SurfaceType.Smooth
		p.Transparency = 0
		return wearGear(p)
	end

	-- pack body, a lid on top of it, and the compression straps down its back
	-- The lid sits a hair proud of the pack on every face. Flush faces fight
	-- each other for depth and shimmer, which is what a lid sharing the pack's
	-- top and back planes looked like.
	gear(Vector3.new(1.42, 1.4, 0.6), CFrame.new(0, 0.22, 0.76), CHUTE.pack)
	gear(Vector3.new(1.5, 0.3, 0.66), CFrame.new(0, 0.8, 0.72), CHUTE.pack2)
	gear(Vector3.new(0.13, 1.34, 0.06), CFrame.new(0.42, 0.22, 1.06), CHUTE.strap)
	gear(Vector3.new(0.13, 1.34, 0.06), CFrame.new(-0.42, 0.22, 1.06), CHUTE.strap)

	-- shoulder straps over the collar, then down the chest
	gear(Vector3.new(0.17, 0.11, 1.2), CFrame.new(0.44, 0.99, 0.04), CHUTE.strap)
	gear(Vector3.new(0.17, 0.11, 1.2), CFrame.new(-0.44, 0.99, 0.04), CHUTE.strap)
	gear(Vector3.new(0.17, 0.72, 0.11), CFrame.new(0.44, 0.62, -0.52), CHUTE.strap)
	gear(Vector3.new(0.17, 0.72, 0.11), CFrame.new(-0.44, 0.62, -0.52), CHUTE.strap)
	gear(Vector3.new(0.76, 0.12, 0.09), CFrame.new(0, 0.55, -0.57), CHUTE.strap)
	gear(Vector3.new(0.15, 0.16, 0.12), CFrame.new(0, 0.55, -0.6), CHUTE.rip, Enum.Material.Neon)

	-- the canopy rolled up on the lid. It disappears once the chute opens, so
	-- the canopy really does come out of the pack.
	local roll = gearCyl(Vector3.new(1.18, 0.4, 0.4), CFrame.new(0, 1.12, 0.78), CHUTE.canopy, Enum.Material.Fabric)
	roll.Name = "CanopyRoll"
	chute.roll = roll

	-- ripcord: a D-ring on a tab, hanging off the right side of the pack
	local ring = gearCyl(Vector3.new(0.13, 0.4, 0.4), CFrame.new(0.8, 0.7, 0.9), CHUTE.rip, Enum.Material.SmoothPlastic)
	ring.Name = "Ripcord"
	gear(Vector3.new(0.3, 0.1, 0.3), CFrame.new(0.66, 0.7, 0.92), CHUTE.rip, Enum.Material.Neon)

	chute.model = model
	chute.root = root
	return model
end

-- The canopy "pops" open: at e = 0 every part is shrunk down onto the harness
-- (the backpack); at e = 1 it sits at its built spot. So it grows while it
-- slides back over your head.
--
-- Each canopy part rides a Weld whose C0 is its pose, and the root carries a
-- Weld onto your torso. That second weld is the whole trick: once it exists the
-- engine solves the canopy as part of your body, in the same physics step that
-- moves you, so there is nothing to chase and nothing that can fall behind.
-- This function therefore only writes while the pop is actually changing; the
-- moment e settles the work stops and the canopy simply rides along.
local function driveChute(e)
	local root = chute.root
	if not root then return end
	local changing = chute.lastE ~= e
	chute.lastE = e
	if not changing then return end
	local f = CHUTE_SHRINK + (1 - CHUTE_SHRINK) * e
	-- Slide out of the pack while opening, then settle behind the head.
	local slide = CHUTE_HARNESS * (1 - e)
	local rootCf = root.CFrame
	for _, item in ipairs(chute.parts) do
		local part = item.part
		local rel = item.rel
		if rel and part.Parent then
			local pose = CFrame.new(slide) * CFrame.new(rel.Position * e) * (rel - rel.Position)
			if item.weld then
				item.weld.C0 = pose
			else
				part.CFrame = rootCf * pose
			end
			local size = item.size * f
			if (part.Size - size).Magnitude > 1e-4 then part.Size = size end
		end
	end
end

-- The two body parts the rig cares about. The ROOT part is the level reference
-- the engine actually moves you by - and the part a crouch or prone never turns -
-- while the TORSO is what drops and shifts when you crouch or lie flat, so the
-- canopy rides its centre. Either can be replaced by the game, so both are
-- resolved fresh (and cheaply) instead of being trusted from attach time.
local function bodyParts(character)
	character = character or player.Character
	if not character then return nil, nil end
	local hrp = character:FindFirstChild("HumanoidRootPart")
	local torso = character:FindFirstChild("UpperTorso") or character:FindFirstChild("Torso")
	return hrp, torso or hrp
end

-- rigWelds is defined below attachParachute; stepChute needs it to re-hang the
-- rig if the carrier it is welded to ever goes away.
local rigWelds

-- Run the open animation. Collapsed (e = 0) parks the canopy on the backpack;
-- deployed (e = 1) rests behind your head. The rig is welded to the body, so
-- there is nothing to reposition each step.
local function stepChute(dt)
	local root = chute.root
	if not root or not root.Parent then return end

	local e = 1
	if chute.d < 1 then
		chute.d = math.min(1, chute.d + dt / CHUTE_DEPLOY)
		e = 1 - (1 - chute.d) ^ 3
	end

	-- Where the rig sits: the canopy is carried, and aimed, by the ROOT part -
	-- never by the torso.
	--
	-- That is the crouch/prone fix. The root part is the level reference the
	-- engine moves you by, and a stance animation does not turn it; it turns the
	-- TORSO (in R6, through the RootJoint), by up to ninety degrees going prone.
	-- A rig welded to the torso is therefore dragged round with it inside every
	-- physics step and yanked back here afterwards - that is the shaking - and
	-- taking the heading off a torso that is pointing at the floor is what made
	-- the canopy spin and snap round. Hung off the root part, neither can happen,
	-- while the canopy still rides the TORSO's centre so it follows you down when
	-- you crouch or lie flat.
	local hrp, torso = bodyParts()
	if hrp and torso then
		-- Heading from the root part's flat look (always level), eased the
		-- shortest way round, so it can never flip 180 degrees in a single frame.
		local look = hrp.CFrame.LookVector
		local flat = Vector3.new(look.X, 0, look.Z)
		if flat.Magnitude > 0.15 and hrp.CFrame.UpVector.Y > 0.7 then
			local wantYaw = math.atan2(-flat.X, -flat.Z)
			local turn = (wantYaw - chuteYaw + math.pi) % (math.pi * 2) - math.pi
			chuteYaw = chuteYaw + turn * math.min(1, dt * 14)
		end
		-- Optional first-person trim, OFF by default: it swings the leading edge
		-- of the canopy down over your head, which is good for seeing that you
		-- have a chute and bad for seeing anything else. Eased, so turning it on
		-- or off never snaps the rig.
		local wantLean = CONFIG.parachute.firstPersonLean or 0
		if not inFirstPerson() then wantLean = 0 end
		local lean = chute.lean or 0
		if math.abs(lean - wantLean) > 0.01 then
			lean = lean + (wantLean - lean) * math.min(1, dt * 8)
			if math.abs(lean - wantLean) <= 0.01 then lean = wantLean end
			chute.lean = lean
		end
		local want = CFrame.new(torso.Position)
			* CFrame.Angles(0, chuteYaw, 0)
			* CFrame.Angles(-math.rad(lean), 0, 0)
		-- A stale carrier (a respawn, or a part the game swapped out) would leave
		-- the weld hanging off nothing, so check the weld's own Part0 rather than
		-- just that a weld exists.
		local at = chute.rootWeld
		if not at or not at.Parent or at.Part0 ~= hrp then
			if at and at.Parent then at:Destroy() end
			chute.rootWeld = nil
			chute.lastC0 = nil
			rigWelds(hrp)
			at = chute.rootWeld
		end
		if at then
			-- Writing C0 IS the attachment: Part0 is the root part, so landing the
			-- rig there is all it takes, and the engine carries it from there -
			-- step for step with the body. Only written when it has actually
			-- changed, because rewriting the weld every single frame is exactly
			-- what shook the canopy.
			local cf = hrp.CFrame:Inverse() * want
			local last = chute.lastC0
			local moved = last == nil
			if last then
				local aligned = cf.RightVector:Dot(last.RightVector) + cf.UpVector:Dot(last.UpVector)
				moved = (cf.Position - last.Position).Magnitude > 0.002 or aligned < 1.99998
			end
			if moved then
				at.C0 = cf
				chute.lastC0 = cf
			end
		else
			root.CFrame = want
		end
		chute.torso = torso
		chute.hrp = hrp
	end

	driveChute(e)

	-- The canopy has left the bag: hide the rolled bundle sitting on the lid.
	if chute.roll and chute.roll.Parent then
		chute.roll.Transparency = chuteOpen and 1 or 0
	end
end

-- A short-lived puff of cloth-coloured spheres when the chute snaps open.
local function spawnChutePuff()
	local character = player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	if not hrp then return end
	local at = hrp.CFrame * CFrame.new(0, 10, 0)
	for _ = 1, 4 do
		local p = Instance.new("Part")
		p.Shape = Enum.PartType.Ball
		p.Size = Vector3.new(2, 2, 2)
		p.CFrame = at * CFrame.new((math.random() - 0.5) * 5, (math.random() - 0.5) * 2, (math.random() - 0.5) * 5)
		p.Color = CHUTE.panel
		p.Material = Enum.Material.SmoothPlastic
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.Transparency = 0.35
		p.Parent = workspace
		TweenService:Create(p, TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Size = Vector3.new(8, 8, 8), Transparency = 1 }):Play()
		task.delay(0.55, function() p:Destroy() end)
	end
end

-- The colour a part should be right now: whatever the picker has set for its
-- role, falling back to the colour it was built with.
local function chuteColorFor(item)
	if item.role then
		local c = CONFIG.colors.parachute[item.role]
		if c then return c end
	end
	return item.color or CONFIG.colors.parachute.canopy
end

-- Repaint the live rig after the picker changes a colour. No rebuild: each part
-- remembers the palette slot it came from.
local function recolorChute()
	for _, item in ipairs(chute.parts) do
		if item.part.Parent then
			item.part.Color = chuteColorFor(item)
		end
	end
	if chute.light then chute.light.Color = CONFIG.colors.parachute.glow end
end

-- Snap every part to its visible/hidden state with no animation.
local function chuteVisible(vis)
	for _, item in ipairs(chute.parts) do
		if item.part.Parent then
			item.part.Color = chuteColorFor(item)
			item.part.Transparency = (item.always or vis) and item.t or 1
		end
	end
end

-- Fade the canopy in/out; the worn harness pack ignores this.
local function chuteFade(vis, time)
	cancelChuteTweens()
	for _, item in ipairs(chute.parts) do
		if item.part.Parent and not item.always then
			local target = vis and item.t or 1
			if math.abs(item.part.Transparency - target) > 0.001 then
				item.part.Color = chuteColorFor(item)
				local tw = TweenService:Create(item.part,
					TweenInfo.new(time, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
					{ Transparency = target })
				table.insert(chuteTweens, tw)
				tw:Play()
			end
		end
	end
end

-- (Re)create the welds that carry the canopy on your body: one Weld from the
-- torso onto the rig's root, then one Weld per canopy part onto the root. This
-- is what keeps the chute glued to you - the engine moves the canopy as part of
-- your body, inside the same physics step that moves you, instead of us
-- re-posing an anchored rig from a callback one step behind it.
--
-- Welding is also the form of attachment this place's clean-up tolerates: it
-- sweeps away loose parts that are neither anchored nor rigidly attached to a
-- body part, and this chain (torso -> root -> panel) is exactly that.
--
-- attachParachute calls this after a build; repairChute calls it again if a
-- weld ever goes missing, so a repaired rig is always rigidly attached again.
-- The carrier is the ROOT part (see stepChute), not the torso.
function rigWelds(carrier)
	local root = chute.root
	if not root or not carrier then return end
	local at = chute.rootWeld
	if not at or not at.Parent or at.Part0 ~= carrier then
		if at and at.Parent then at:Destroy() end
		at = Instance.new("Weld")
		at.Name = "ChuteAttach"
		at.Part0 = carrier
		at.Part1 = root
		at.C0 = carrier.CFrame:Inverse() * root.CFrame
		at.Parent = root
		chute.rootWeld = at
		chute.lastC0 = nil
	end
	for _, item in ipairs(chute.parts) do
		if item.rel and (not item.weld or not item.weld.Parent) then
			local w = Instance.new("Weld")
			w.Name = "ChutePanel"
			w.Part0 = root
			w.Part1 = item.part
			w.C0 = item.rel
			w.Parent = item.part
			item.weld = w
		end
	end
end

local function detachParachute()
	cancelChuteTweens()
	if chute.model then chute.model:Destroy() chute.model = nil end
	if chute.rig then chute.rig:Destroy() chute.rig = nil end
	chute.parts = {}
	chute.wear = {}
	chute.root = nil
	chute.rootWeld = nil
	chute.lastC0 = nil
	chute.light = nil
	chute.roll = nil
	chute.align = nil
	chute.socket = nil
	chute.d = 1
	chute.lastE = nil
	chute.fallPeakY = nil
	chuteOpen = false
end

local function attachParachute(character)
	detachParachute()
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	if not hrp then return end
	-- The rig is CARRIED by the root part and rides the TORSO's centre. The root
	-- part is the level reference the engine moves you by and the part a crouch
	-- or prone never turns; the torso is what drops and shifts when you do, so
	-- its centre is where the canopy should hang. Welding to the torso instead
	-- made a stance animation drag the canopy round with it every step (the
	-- shaking) and fed the heading off a torso pointing at the floor (the spin).
	local torso = character:FindFirstChild("UpperTorso")
		or character:FindFirstChild("Torso")
		or hrp
	-- Work out the heading BEFORE building. The canopy rig is built in an
	-- UPRIGHT frame - position plus heading, with no pitch or roll - because
	-- that frame is what driveChute re-poses it into every step. Building it from
	-- torso.CFrame instead baked whatever pitch your torso happened to be at the
	-- instant the chute opened into the canopy as permanent lean: the 20 degree
	-- tilt came out 11 degrees light, and the same 11 degrees went missing from
	-- the first-person lean. The worn gear below still uses the torso's real
	-- frame, because it is welded to the body and must sit where the body is.
	local look = hrp.CFrame.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	if flat.Magnitude > 0.15 then
		chuteYaw = math.atan2(-flat.X, -flat.Z)
	end
	local upright = CFrame.new(torso.Position) * CFrame.Angles(0, chuteYaw, 0)
	local model = buildParachute(upright, torso.CFrame)
	model.Parent = character
	chute.d = 1

	-- Weld the harness pack and ripcord straight to the torso so they ride the
	-- body (and follow torso animation) instead of hanging off the canopy root.
	-- This captures the offset now that both are in the workspace.
	for _, part in ipairs(chute.wear) do
		local w = Instance.new("WeldConstraint")
		w.Part0 = torso
		w.Part1 = part
		w.Parent = part
	end

	-- The canopy follows your POSITION and HEADING, and nothing else: stepChute
	-- writes the rig's attach weld and spins it to the root part's flat look, so
	-- crouching or going prone can never drag the canopy over.
	chute.torso = torso
	chute.hrp = hrp
	chute.root.CFrame = upright
	rigWelds(hrp)

	-- The canopy does not live in your character: it goes in a folder of its own
	-- in the workspace, where character-scoped checks cannot see it. The pack and
	-- ripcord are real gear welded to the torso, so they stay on the body.
	local rigFolder = Instance.new("Folder")
	rigFolder.Name = "ChuteCanopy"
	for _, item in ipairs(chute.parts) do
		if item.rel then item.part.Parent = rigFolder end
	end
	chute.root.Parent = rigFolder
	rigFolder.Parent = workspace
	chute.rig = rigFolder

	-- Pose the whole canopy against the root's new CFrame, then hide it until
	-- it is needed.
	chute.lastE = nil
	driveChute(1)

	chuteVisible(false)
end

-- Is the rig still whole and attached? Everything the canopy needs to follow
-- your body hangs off the root, and the pack is welded to your torso, so a
-- part that has been unparented - or an attach weld whose carrier has gone away
-- - means the parachute is broken.
local function chuteIntact()
	if not chute.model or not chute.root then return false end
	if not chute.root.Parent then return false end
	if not chute.rootWeld or not chute.rootWeld.Parent then return false end
	if not chute.rootWeld.Part0 then return false end
	if not chute.rootWeld.Part0:IsDescendantOf(player.Character or workspace) then return false end
	if chute.rig and not chute.rig.Parent then return false end
	for _, item in ipairs(chute.parts) do
		if not item.part.Parent then return false end
	end
	return true
end

-- Put the rig back together. The sweep above usually only unparents things, so
-- this is normally just a re-parent; if the parts are really gone, build the
-- whole thing again - and if the canopy was out, put it straight back out, so
-- being rescued mid-fall doesn't drop you.
local function repairChute()
	if os.clock() - chuteRepair < 0.5 then return end
	chuteRepair = os.clock()
	local character = player.Character
	if not character then return end

	local repaired = chute.model ~= nil and chute.root ~= nil and chute.rig ~= nil
	if repaired then
		for _, item in ipairs(chute.parts) do
			if not item.part.Parent then
				local home = item.rel and chute.rig or chute.model
				if not pcall(function() item.part.Parent = home end) then
					repaired = false
					break
				end
			end
		end
		if repaired and not chute.root.Parent then
			repaired = pcall(function() chute.root.Parent = chute.rig end)
		end
		if repaired and not chute.rig.Parent then
			pcall(function() chute.rig.Parent = workspace end)
		end
		-- Re-parenting brings each weld along with its part, but a weld that
		-- really went missing would leave a panel floating in mid-air (or the
		-- whole rig anchored to nothing), so put any missing one back - re-hanging
		-- off whatever root part the character has now, in case the old one is
		-- the thing that went away.
		if repaired then
			local carrier = chute.hrp
			if not (carrier and carrier.Parent) then carrier = bodyParts(character) end
			rigWelds(carrier)
		end
	end
	if repaired then return end

	local wasOpen = chuteOpen
	attachParachute(character)
	if wasOpen and chute.root and chute.root.Parent then
		chuteOpen = true
		chute.d = 1
		chute.lastE = nil
		driveChute(1)
		chuteVisible(true)
		if chute.light and CONFIG.parachute.light then chute.light.Enabled = true end
	end
end

local function openChute()
	if chuteOpen then return end
	-- Don't let a bouncy landing flip the chute on and off every frame.
	if os.clock() - (chute.lastClose or 0) < 0.35 then return end
	chuteOpen = true
	-- Start collapsed against the backpack, then pop it open (stepChute grows it).
	chute.d = 0
	stepChute(0)
	chuteFade(true, 0.2)
	sfx("chute")
	if chute.light and CONFIG.parachute.light then chute.light.Enabled = true end
	-- Only puff if we haven't just puffed, so a bouncy landing can't spam parts.
	local now = os.clock()
	if now - (chute.lastPuff or 0) > 0.75 then
		chute.lastPuff = now
		spawnChutePuff()
	end
end

local function closeChute()
	if not chuteOpen then return end
	chuteOpen = false
	chute.lastClose = os.clock()
	-- Snap it back to full size, ready to pop again next time.
	chute.d = 1
	stepChute(0)
	if chute.light then chute.light.Enabled = false end
	chuteFade(false, 0.15)
end

local chuteRay = RaycastParams.new()
if Enum.RaycastFilterType.Exclude then
	chuteRay.FilterType = Enum.RaycastFilterType.Exclude
end
-- When set, the ray ignores non-colliding decoration, which matters a lot in a
-- place with hundreds of thousands of parts.
pcall(function() chuteRay.RespectCanCollide = true end)

-- The ground probe is the only expensive thing the chute does, so it's
-- throttled and cached instead of fired every single frame.
local chuteProbe = { timer = 1, dist = nil, char = nil }

local function stepParachute(dt)
	if not enabled or not CONFIG.parachute.enabled then
		closeChute()
		return
	end

	-- Whatever this place does to stray parts, the chute stays fastened to us.
	-- The sweep can strike while the chute is stowed, so this check has to run
	-- every frame, not only while the canopy is out.
	if not chuteIntact() then repairChute() end

	local character = player.Character
	local hum = character and character:FindFirstChildOfClass("Humanoid")
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	if not hum or not hrp or hum.Health <= 0 then
		closeChute()
		return
	end

	-- on the ground: the chute is done
	if hum.FloorMaterial ~= Enum.Material.Air then
		chute.fallPeakY = nil
		closeChute()
		return
	end

	-- Remember the highest point of this fall so we can tell a real drop (off a
	-- roof, out of a sticky jump) from a little hop.
	local posY = hrp.Position.Y
	chute.fallPeakY = math.max(chute.fallPeakY or posY, posY)

	local v = hrp.AssemblyLinearVelocity
	if v.Y >= 0 then
		-- rising (say, a sticky jump): don't drag the chute along
		closeChute()
		return
	end

	local cfg = CONFIG.parachute
	local fallDrop = chute.fallPeakY - posY

	-- Only probe the ground when it could actually change our mind, and at most
	-- ~12 times a second instead of every frame.
	chuteProbe.timer = chuteProbe.timer + dt
	local needProbe = chuteOpen or (v.Y <= -cfg.minFallSpeed)
	if chuteProbe.char ~= character then
		-- new character: drop the cached distance and probe right away
		chuteProbe.char = character
		chuteProbe.dist = nil
		chuteProbe.timer = 1
		chuteRay.FilterDescendantsInstances = { character }
	end
	if needProbe then
		if chuteProbe.timer >= 0.08 then
			chuteProbe.timer = 0
			local cast = cfg.probeRange
			local hit = workspace:Raycast(hrp.Position, Vector3.new(0, -cast, 0), chuteRay)
			chuteProbe.dist = hit and (hrp.Position.Y - hit.Position.Y) or math.huge
		end
	else
		chuteProbe.dist = nil
	end

	if not chuteOpen then
		if v.Y <= -cfg.minFallSpeed and fallDrop >= cfg.minFallHeight and chuteProbe.dist then
			local openDist = math.clamp(math.max(-v.Y, 0) * cfg.deployTime, cfg.deployHeight, cfg.maxDeployDist)
			-- Nothing under us for the whole probe (over the void): open anyway
			-- rather than keep falling with a perfectly good chute on our back.
			local blindDrop = chuteProbe.dist == math.huge and fallDrop >= cfg.maxDeployDist + 80
			if chuteProbe.dist <= openDist or blindDrop then
				openChute()
			end
		end
		if not chuteOpen then return end
	end

	-- Keep the lantern in sync with the chute (and pulse it gently).
	if chute.light then
		local want = chuteOpen and cfg.light == true
		if chute.light.Enabled ~= want then chute.light.Enabled = want end
		if want then
			chute.hue = (chute.hue or 0) + dt
			chute.light.Brightness = 3.6 + math.sin(chute.hue * 6) * 1.3
		end
	end

	-- Ease the descent down to a gentle, non-lethal speed and never let it build
	-- back up (gravity would otherwise out-run the chute).
	local target = -cfg.safeSpeed
	local ny = v.Y + (target - v.Y) * math.min(dt * 12, 1)
	if ny < target then ny = target end

	-- Reuse our tracked horizontal velocity so air-strafe is preserved.
	if smState and smState.hv.Magnitude > 0.01 then
		hrp.AssemblyLinearVelocity = Vector3.new(smState.hv.X, ny, smState.hv.Z)
	else
		hrp.AssemblyLinearVelocity = Vector3.new(v.X, ny, v.Z)
	end
end

-- colour picker (RightShift) -------------------------------------------------
--
-- The picker lives ON the launcher's own screen - the same little panel that
-- shows your speed and charge in first person - so changes are made right where
-- you are already looking. RightShift opens it and frees the mouse so the
-- controls can be clicked; pressing it again closes it and hands the mouse back.
--
-- Navigation on a surface this small is built on two ideas. The top row picks
-- the canopy SHAPE (round / stripe / army / wing) and the grid below it is the
-- palette: click a slot and its colour steps to the next in
-- CONFIG.colors.palette, repainting the live launcher and canopy in place. The
-- patch under the cursor lights up as you move, so a click is never a guess.
--
-- Clicks are found by hand (pickRegion): the engine's own SurfaceGui ray is
-- stopped by pieces of our own character hanging right in front of the camera in
-- first person, so it never reaches the panel on its own.

local colorMenu = nil
local savedMouseBehavior = nil
local clickRegions = {}   -- every clickable patch: { u, v, w, h, onPick, hi }
local hoverRegion = nil   -- the patch under the cursor, for the hover outline
local designButtons = {}  -- slug -> { btn, stroke }, for the selected highlight

local function paletteStep(current)
	local pal = CONFIG.colors.palette
	local idx = 0
	for i, v in ipairs(pal) do
		if v == current then idx = i break end
	end
	idx = idx % #pal + 1
	return pal[idx], idx
end

local function repaint()
	applyLauncherColors()
	recolorChute()
end

-- Swap the canopy shape. The design only changes geometry, so the rig is rebuilt
-- from scratch; if the chute was flying it is popped straight back open.
local function setChuteDesign(slug)
	if CONFIG.parachute.design == slug then return end
	CONFIG.parachute.design = slug
	saveSettings()
	local ch = player.Character
	if not ch then return end
	local wasOpen = chuteOpen
	attachParachute(ch)
	if wasOpen then
		chuteOpen = true
		chute.d = 1
		chute.lastE = nil
		driveChute(1)
		chuteVisible(true)
		if chute.light and CONFIG.parachute.light then chute.light.Enabled = true end
	else
		chuteOpen = false
		chuteVisible(false)
	end
end

local function addRegion(u, v, w, h, onPick)
	local r = { u = u, v = v, w = w, h = h, onPick = onPick }
	clickRegions[#clickRegions + 1] = r
	return r
end

-- Which patch of the screen is under a point? The launcher is welded solid and
-- every part of it is unqueryable, so ray at just the screen panel and read where
-- the hit lands in the panel's own space - that maps straight onto the 0..1
-- canvas the controls are laid out on. The point is in SCREEN space (the same
-- space the mouse reports), so ScreenPointToRay - not ViewportPointToRay - is
-- the one that takes the top-bar inset into account.
local function pickRegion(vx, vy)
	if not (CONFIG.colors.uiOpen and launcherScreen and launcherScreen.part) then return nil end
	local cam = workspace.CurrentCamera
	if not cam then return nil end
	local part = launcherScreen.part
	local ray = cam:ScreenPointToRay(vx, vy)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { part }
	local hit = workspace:Raycast(ray.Origin, ray.Direction * 30, params)
	if not hit then return nil end
	local lp = part.CFrame:PointToObjectSpace(hit.Position)
	local s = part.Size
	local u = (lp.X + s.X * 0.5) / s.X
	local v = (s.Y * 0.5 - lp.Y) / s.Y
	for _, r in ipairs(clickRegions) do
		if u >= r.u and u <= r.u + r.w and v >= r.v and v <= r.v + r.h then
			return r
		end
	end
	return nil
end

-- Apply a click at a screen point. Returns true when it landed on a control.
local function applyClickAt(vx, vy)
	local r = pickRegion(vx, vy)
	if not r then return false end
	r.onPick()
	return true
end

-- Light the patch under the cursor, so a click is never a guess.
local function updateHover(vx, vy)
	local r = pickRegion(vx, vy)
	if r ~= hoverRegion then
		if hoverRegion and hoverRegion.hi then hoverRegion.hi(false) end
		hoverRegion = r
		if hoverRegion and hoverRegion.hi then hoverRegion.hi(true) end
	end
end

local function clearHover()
	if hoverRegion and hoverRegion.hi then hoverRegion.hi(false) end
	hoverRegion = nil
end

-- One palette slot. A label, not a button: clicks are handled by pickRegion.
local function colorSwatch(parent, slot, pos, size)
	local btn = Instance.new("TextLabel")
	btn.Name = slot.group .. "_" .. slot.key
	btn.Position = pos
	btn.Size = size
	btn.BackgroundColor3 = CONFIG.colors[slot.group][slot.key]
	btn.BorderSizePixel = 0
	btn.Text = slot.label
	useMono(btn)
	btn.TextScaled = true
	btn.TextColor3 = Color3.fromRGB(255, 255, 255)
	btn.TextStrokeTransparency = 0.35
	btn.ZIndex = 9
	btn.Parent = parent
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, 3)
	c.Parent = btn
	local s = Instance.new("UIStroke")
	s.Color = Color3.fromRGB(255, 255, 255)
	s.Transparency = 0.55
	s.Parent = btn
	local cap = Instance.new("UITextSizeConstraint")
	cap.MaxTextSize = 20
	cap.MinTextSize = 4
	cap.Parent = btn

	local r = addRegion(pos.X.Scale, pos.Y.Scale, size.X.Scale, size.Y.Scale, function()
		local nextColor = paletteStep(CONFIG.colors[slot.group][slot.key])
		CONFIG.colors[slot.group][slot.key] = nextColor
		btn.BackgroundColor3 = nextColor
		repaint()
		saveSettings()
	end)
	r.hi = function(on)
		s.Transparency = on and 0 or 0.55
		s.Thickness = on and 2 or 1
	end
	return btn
end

local DESIGN_LABEL = { classic = "ROUND", stripe = "STRIPE", army = "ARMY", wing = "WING" }

local function highlightDesign()
	local cur = CONFIG.parachute.design
	for slug, entry in pairs(designButtons) do
		local on = (slug == cur)
		entry.stroke.Color = on and Color3.fromRGB(255, 160, 60) or Color3.fromRGB(90, 92, 100)
		entry.stroke.Thickness = on and 2 or 1
		entry.btn.BackgroundColor3 = on and Color3.fromRGB(58, 40, 18) or Color3.fromRGB(22, 24, 30)
	end
end

-- One canopy-shape button. Also picked by hand, for the same reason as the
-- palette slots.
local function designButton(parent, slug, pos, size)
	local btn = Instance.new("TextLabel")
	btn.Name = "Design_" .. slug
	btn.Position = pos
	btn.Size = size
	btn.BackgroundColor3 = Color3.fromRGB(22, 24, 30)
	btn.BorderSizePixel = 0
	btn.Text = DESIGN_LABEL[slug] or string.upper(slug)
	useMono(btn)
	btn.TextScaled = true
	btn.TextColor3 = Color3.fromRGB(235, 235, 240)
	btn.ZIndex = 9
	btn.Parent = parent
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, 3)
	c.Parent = btn
	local s = Instance.new("UIStroke")
	s.Color = Color3.fromRGB(90, 92, 100)
	s.Transparency = 0.2
	s.Parent = btn
	local cap = Instance.new("UITextSizeConstraint")
	cap.MaxTextSize = 18
	cap.MinTextSize = 5
	cap.Parent = btn

	designButtons[slug] = { btn = btn, stroke = s }
	local r = addRegion(pos.X.Scale, pos.Y.Scale, size.X.Scale, size.Y.Scale, function()
		setChuteDesign(slug)
		highlightDesign()
		saveSettings()
	end)
	r.hi = function(on)
		s.Transparency = on and 0 or 0.35
		btn.TextColor3 = on and Color3.new(1, 1, 1) or Color3.fromRGB(235, 235, 240)
	end
	return btn
end

local function buildColorPanel()
	if colorMenu and colorMenu.Parent then return end
	clickRegions = {}
	designButtons = {}
	hoverRegion = nil
	local gui = launcherScreen and launcherScreen.gui
	if not gui or not gui.Parent then return end

	colorMenu = Instance.new("Frame")
	colorMenu.Name = "ColorMenu"
	colorMenu.Size = UDim2.new(1, 0, 1, 0)
	colorMenu.BackgroundColor3 = Color3.fromRGB(10, 12, 16)
	colorMenu.BackgroundTransparency = 0.02
	colorMenu.BorderSizePixel = 0
	colorMenu.ZIndex = 8
	colorMenu.Visible = false
	colorMenu.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = colorMenu
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(226, 118, 28)
	stroke.Thickness = 1.5
	stroke.Transparency = 0.3
	stroke.Parent = colorMenu

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.BackgroundTransparency = 1
	title.Size = UDim2.new(1, 0, 0.13, 0)
	title.Position = UDim2.new(0, 0, 0, 0)
	useMono(title)
	title.TextScaled = true
	title.TextXAlignment = Enum.TextXAlignment.Center
	title.TextColor3 = Color3.fromRGB(255, 170, 70)
	title.Text = "CUSTOMISE"
	title.ZIndex = 9
	title.Parent = colorMenu
	local tcap = Instance.new("UITextSizeConstraint")
	tcap.MaxTextSize = 24
	tcap.MinTextSize = 6
	tcap.Parent = title

	local gap = 0.015

	-- Shape row: one button per canopy design.
	local designs = CONFIG.parachute.designs or { "classic" }
	local dn = #designs
	local dw = (1 - gap * (dn + 1)) / dn
	for i, slug in ipairs(designs) do
		local x = gap + (i - 1) * (dw + gap)
		designButton(colorMenu, slug,
			UDim2.new(x, 0, 0.14, 0),
			UDim2.new(dw, 0, 0.17, 0))
	end
	highlightDesign()

	-- Short labels so they survive being scaled onto a small screen.
	local slots = {
		{ label = "LA METAL",  group = "launcher",  key = "metal" },
		{ label = "LA DARK",   group = "launcher",  key = "dark" },
		{ label = "LA WOOD",   group = "launcher",  key = "wood" },
		{ label = "LA ACCENT", group = "launcher",  key = "accent" },
		{ label = "CANOPY",    group = "parachute", key = "canopy" },
		{ label = "STRIPES",   group = "parachute", key = "panel" },
		{ label = "HEM",       group = "parachute", key = "rim" },
		{ label = "SEAM",      group = "parachute", key = "rib" },
		{ label = "LINES",     group = "parachute", key = "cord" },
		{ label = "PACK",      group = "parachute", key = "pack" },
		{ label = "STRAPS",    group = "parachute", key = "strap" },
		{ label = "RIPCORD",   group = "parachute", key = "rip" },
	}

	-- 3 columns x 4 rows filling everything below the shape row.
	local cols, rows = 3, 4
	local top = 0.33
	local cw = (1 - gap * (cols + 1)) / cols
	local rh = (1 - top - gap * (rows + 1)) / rows
	for i, slot in ipairs(slots) do
		local ci = (i - 1) % cols
		local ri = math.floor((i - 1) / cols)
		colorSwatch(colorMenu, slot,
			UDim2.new(gap + ci * (cw + gap), 0, top + gap + ri * (rh + gap), 0),
			UDim2.new(cw, 0, rh, 0))
	end
end

local function toggleColorPanel()
	buildColorPanel()
	if not colorMenu then return end
	CONFIG.colors.uiOpen = not CONFIG.colors.uiOpen
	colorMenu.Visible = CONFIG.colors.uiOpen
	if CONFIG.colors.uiOpen then
		stickyCharging = false
		-- Remember how the mouse was and free it so the swatches can be clicked.
		local ok, behaviour = pcall(function() return UserInputService.MouseBehavior end)
		savedMouseBehavior = ok and behaviour or nil
		pcall(function() UserInputService.MouseBehavior = Enum.MouseBehavior.Default end)
		pcall(function() UserInputService.MouseIconEnabled = true end)
	else
		clearHover()
		local restore = savedMouseBehavior
		savedMouseBehavior = nil
		if restore == Enum.MouseBehavior.LockCenter or restore == Enum.MouseBehavior.LockCurrentPosition then
			pcall(function() UserInputService.MouseBehavior = restore end)
		else
			pcall(function() UserInputService.MouseBehavior = Enum.MouseBehavior.Default end)
		end
	end
end

-- unload --------------------------------------------------------------------

local function unload()
	smTeardown()
	clearStickies()
	clearEffects()
	detachParachute()
	pcall(function() RunService:UnbindFromRenderStep("StickyLauncherAim") end)
	pcall(function() RunService:UnbindFromRenderStep("StickyColorMouse") end)
	releaseAimGrip()
	if colorMenu then colorMenu:Destroy() colorMenu = nil end
	if CONFIG.colors.uiOpen then
		CONFIG.colors.uiOpen = false
		if inFirstPerson() then
			pcall(function() UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter end)
		end
	end
	if chargeGui then chargeGui:Destroy() chargeGui = nil end
	if speedGui then speedGui:Destroy() speedGui = nil end
	if stickyTool and stickyTool.Parent then stickyTool:Destroy() end
	stickyTool = nil
	launcherRoot = nil
	disconnectList(globalConns)
	if genv.__StickyJumper then
		genv.__StickyJumper.alive = false
	end
end

-- wiring --------------------------------------------------------------------

giveStickyTool()

chargeGui, chargeBack, chargeFill, chargeLabel = buildChargeBar()
speedGui, speedPanel, speedValue = buildSpeedo()

-- Clear any stray movement pieces a previous (buggy) run left on the character.
smCleanStrays(player.Character)
attachParachute(player.Character)

-- The launcher is turned to the camera right after the camera itself moves, so
-- it is aimed with this frame's view rather than the previous frame's.
RunService:BindToRenderStep("StickyLauncherAim", Enum.RenderPriority.Camera.Value + 1, stepLauncherAim)

-- While the colour picker is open the cursor has to be free to click the
-- swatches, but the camera controller re-locks the mouse every frame. Writing
-- the release from a late render step - after the controller has had its turn -
-- is what actually makes it stick.
RunService:BindToRenderStep("StickyColorMouse", Enum.RenderPriority.Last.Value, function()
	if CONFIG.colors.uiOpen then
		if UserInputService.MouseBehavior ~= Enum.MouseBehavior.Default then
			pcall(function() UserInputService.MouseBehavior = Enum.MouseBehavior.Default end)
		end
		if not UserInputService.MouseIconEnabled then
			pcall(function() UserInputService.MouseIconEnabled = true end)
		end
		-- Light whatever control the cursor is over.
		local m = player:GetMouse()
		updateHover(m.X, m.Y)
	elseif hoverRegion then
		clearHover()
	end
end)

local toolWatch = 0

table.insert(globalConns, UserInputService.InputBegan:Connect(function(input, gameProcessed)
	-- RMB detonates everything you have stuck. Handled before the gameProcessed
	-- guard so it works even if the game uses RMB to aim.
	if input.UserInputType == Enum.UserInputType.MouseButton2 and enabled and stickyToolEquipped() then
		-- The colour picker owns the mouse while it is open; clicks there are UI.
		if CONFIG.colors.uiOpen then return end
		-- Only while aiming: first person or shiftlock. Third person ignores it.
		if detonateArmed() then detonateStickies() end
		return
	end

	-- Clicks land on the screen panel. The picker frees the cursor, and the
	-- control under it is found with our own ray at the panel - the engine's
	-- SurfaceGui ray is blocked by bits of our own character that sit right in
	-- front of the camera, so it never fires in first person.
	if CONFIG.colors.uiOpen and input.UserInputType == Enum.UserInputType.MouseButton1 then
		local m = player:GetMouse()
		applyClickAt(m.X, m.Y)
		return
	end

	-- RightShift toggles the colour picker. Handled before the gameProcessed
	-- guard because this place binds RightShift itself, so it always arrives
	-- flagged as processed.
	if input.KeyCode == Enum.KeyCode.RightShift then
		toggleColorPanel()
		return
	end

	if gameProcessed then return end

	if input.KeyCode == CONFIG.strafeKey then
		SOURCE.autoStrafe = not SOURCE.autoStrafe
		print("[StickyJumper] auto air-strafe " .. (SOURCE.autoStrafe and "ON" or "OFF"))
		return
	end

	if input.KeyCode == CONFIG.toggleKey then
		enabled = not enabled
		if not enabled then stickyCharging = false end
		print("[StickyJumper] " .. (enabled and "ENABLED" or "DISABLED"))
	end
end))

table.insert(globalConns, RunService.Heartbeat:Connect(function(dt)
	stepStickies()
	updateChargeBar()
	updateSpeedo(dt)
	updateLauncherScreen(dt)

	-- The game wipes non-native tools off the Backpack on respawn; put ours
	-- back if it ever goes missing.
	toolWatch = toolWatch + dt
	if toolWatch >= 2 then
		toolWatch = 0
		if not (stickyTool and stickyTool.Parent) then giveStickyTool() end
		smCleanStrays(player.Character)
	end
end))

table.insert(globalConns, RunService.Stepped:Connect(function(_, dt)
	stepSource(dt)
	stepParachute(dt)
end))

-- The rig's pose - the heading it is trimmed to, plus the opening animation -
-- is written in the RENDER step, so the heading we read is the one about to be
-- drawn and the canopy never turns a frame late.
--
-- ATTACHING the canopy is not done here. The rig is welded to your torso, so the
-- engine carries it inside the same physics step that moves your body. That is
-- the real fix for "the chute drifts away from me at speed": a hand-posed
-- anchored rig can only ever be as fresh as its last write, which is always one
-- physics step behind where you actually are - and that lag grew with speed.
table.insert(globalConns, RunService.RenderStepped:Connect(function(dt)
	stepChute(dt)
end))

table.insert(globalConns, player.CharacterAdded:Connect(function(character)
	smState.hv = Vector3.new()
	smState.buildFailed = false
	smState.warn = nil
	smState.blastHold = 0
	smState.softCeil = 0
	smTeardown()
	smCleanStrays(character)
	detachParachute()
	task.delay(0.5, function()
		if player.Character == character then attachParachute(character) end
	end)
	task.delay(1, giveStickyTool)
end))

genv.__StickyJumper = {
	version = VERSION,
	alive = true,
	mainConn = globalConns[1],
	destroy = function()
		unload()
		genv.__StickyJumper = nil
	end,
	_debug = {
		CONFIG = CONFIG,
		stickies = stickies,
		startStickyCharge = startStickyCharge,
		releaseSticky = releaseSticky,
		fireSticky = fireSticky,
		detonateStickies = detonateStickies,
		clearStickies = clearStickies,
		giveStickyTool = giveStickyTool,
		explode = explode,
		launchPlayer = launchPlayer,
		buildLauncher = buildLauncher,
		launcher = function() return launcherRoot end,
		screen = function() return launcherScreen end,
		applyLauncherColors = applyLauncherColors,
		recolorChute = recolorChute,
		toggleColorPanel = toggleColorPanel,
		pickRegion = pickRegion,
		applyClickAt = applyClickAt,
		clickRegionCount = function() return #clickRegions end,
		setChuteDesign = setChuteDesign,
		saveSettings = saveSettings,
		loadSettings = loadSettings,
		resetSettings = resetSettings,
		settingsLoaded = function() return settingsLoaded end,
		colorPanel = function() return colorMenu end,
		colorMenu = function() return colorMenu end,
		chargeBar = function() return chargeBack end,
		inFirstPerson = inFirstPerson,
		detonateArmed = detonateArmed,
		aimingCamera = aimingCamera,
		shiftLocked = shiftLocked,
		stepLauncherAim = stepLauncherAim,
		updateSpeedo = updateSpeedo,
		updateChargeBar = updateChargeBar,
		updateLauncherScreen = updateLauncherScreen,
		SOURCE = SOURCE,
		smState = smState,
		stepSource = stepSource,
		smWishDir = smWishDir,
		smAirAccelerate = smAirAccelerate,
		smAccelerate = smAccelerate,
		smGroundFriction = smGroundFriction,
		smLimitTurn = smLimitTurn,
		stepParachute = stepParachute,
		attachParachute = attachParachute,
		detachParachute = detachParachute,
		stepChute = stepChute,
		driveChute = driveChute,
		chuteOpen = function() return chuteOpen end,
		chute = function() return chute.model end,
		chuteProbe = chuteProbe,
		chuteLight = function() return chute.light end,
		chuteState = chute,
		stats = stats,
		sfx = sfx,
		speedo = function() return speedPanel end,
	},
}

print("[StickyJumper] " .. VERSION .. " loaded. Pick 'Sticky Jumper' in your hotbar: LMB fire (hold to charge), RMB detonate. TF2 air-strafe + auto-bhop (hold Space). Toggle: P  |  auto-strafe: J")
