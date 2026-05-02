
--[[
	NPC Greeter System — ServerScriptService

]]

-- services
local PathfindingService = game:GetService("PathfindingService")
local Players            = game:GetService("Players")
local RunService         = game:GetService("RunService")
local CollectionService  = game:GetService("CollectionService")
local ServerStorage      = game:GetService("ServerStorage")
local Chat               = game:GetService("Chat")

-- roblox default Animations
local ANIM_IDLE = "rbxassetid://180435571"
local ANIM_WALK = "rbxassetid://180426354"
local ANIM_WAVE = "rbxassetid://507770239"

-- easy modular tuning
local NPC_TAG            = "GreeterNPC"
local NPC_COUNT          = 5
local NPC_BASE_SPEED     = 12
local GREET_RADIUS       = 20
local WANDER_RADIUS      = 40
local SEPARATION_RADIUS  = 18
local SENSE_TICK         = 0.15
local GREET_COOLDOWN     = 15
local WALK_AWAY_DIST     = 25
local WALK_AWAY_DURATION = 5
local IDLE_MIN           = 3
local IDLE_MAX           = 9
local SCATTER_RADIUS     = 55

local activeGreetings = {}   -- [player] = true while an NPC is greeting them

-- rig template
local rigTemplate = (function()
	local folder = ServerStorage:FindFirstChild("NPCAssets")
	assert(folder, "[GreeterAI] ServerStorage is missing the 'NPCAssets' folder.")
	local t = folder:FindFirstChild("RigTemplate")
	assert(t, "[GreeterAI] 'NPCAssets' is missing a model named 'RigTemplate'.")
	print("[GreeterAI] RigTemplate found ✓")
	return t
end)()

-- fetch players friends
local function fetchFriendIds(player)
	local ids = {}
	local ok, pages = pcall(function() return Players:GetFriendsAsync(player.UserId) end)
	if not ok or not pages then return ids end
	while true do
		for _, e in ipairs(pages:GetCurrentPage()) do
			ids[#ids + 1] = { id = e.Id, name = e.Username }
		end
		if pages.IsFinished then break end
		if not pcall(function() pages:AdvanceToNextPageAsync() end) then break end
	end
	for i = #ids, 2, -1 do          -- shuffle
		local j = math.random(1, i)
		ids[i], ids[j] = ids[j], ids[i]
	end
	return ids
end

local function assignFriends(list, count)
	if #list == 0 then return {} end
	local out = {}
	for i = 1, count do out[i] = list[((i-1) % #list) + 1] end
	return out
end

-- apply the friends avatar to the NPC
local function applyFriendAppearance(model, friendEntry)
	task.spawn(function()
		task.wait(0.8)
		local hum = model:FindFirstChildOfClass("Humanoid")
		if not hum then return end
		local ok, desc = pcall(function()
			return Players:GetHumanoidDescriptionFromUserIdAsync(friendEntry.id)
		end)
		if not ok or not desc then return end
		desc.BodyTypeScale = 0; desc.HeadScale = 1
		desc.HeightScale   = 1; desc.WidthScale = 1
		desc.ProportionScale = 0; desc.DepthScale = 1
		pcall(function() hum:ApplyDescription(desc) end)
	end)
end

-- rig builder
local function buildRig(position, npcId, friendEntry)
	local model = rigTemplate:Clone()
	model.Name  = "NPC_" .. npcId

	local hum  = model:FindFirstChildOfClass("Humanoid")
	local root = model:FindFirstChild("HumanoidRootPart")
	assert(hum  and root, "[GreeterAI] RigTemplate is missing Humanoid or HumanoidRootPart.")

	local animScript = model:FindFirstChild("Animate")
	if animScript then animScript:Destroy() end

	local animator = hum:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = hum
	end

	hum.MaxHealth             = 100
	hum.Health                = 100
	hum.WalkSpeed             = NPC_BASE_SPEED + (math.random() * 4 - 2)
	hum.AutomaticScalingEnabled = false
	hum.DisplayDistanceType   = Enum.HumanoidDisplayDistanceType.None
	hum.NameDisplayDistance   = 0
	hum.HealthDisplayDistance = 0

	model:PivotTo(CFrame.new(position + Vector3.new(0, 3.5, 0)))
	model.Parent = workspace
	CollectionService:AddTag(model, NPC_TAG)

	if friendEntry then applyFriendAppearance(model, friendEntry) end

	return model, hum, animator, root
end

-- animation
-- waves are loaded fresh to avoid stale reference
local function loadBaseAnims(animator)
	local function load(id, looped)
		local anim = Instance.new("Animation")
		anim.AnimationId = id
		local ok, track = pcall(function() return animator:LoadAnimation(anim) end)
		if ok and track then track.Looped = looped; return track end
	end
	return {
		idle = load(ANIM_IDLE, true),
		walk = load(ANIM_WALK, true),
	}
end

local function stopAllTracks(tracks)
	for _, t in pairs(tracks) do
		if t and t.IsPlaying then t:Stop(0.1) end
	end
end

local function playTrack(track, fade)
	if track and not track.IsPlaying then track:Play(fade or 0.15) end
end

-- wander helpers
local function getAllNPCRoots(selfRoot)
	local roots = {}
	for _, m in ipairs(CollectionService:GetTagged(NPC_TAG)) do
		local r = m:FindFirstChild("HumanoidRootPart")
		if r and r ~= selfRoot then roots[#roots + 1] = r end
	end
	return roots
end

local function pickWanderPoint(origin, selfRoot)
	local others = getAllNPCRoots(selfRoot)
	local best, bestScore = nil, -math.huge
	for _ = 1, 12 do
		local a  = math.random() * math.pi * 2
		local r  = math.random(8, WANDER_RADIUS)
		local pt = origin + Vector3.new(math.cos(a)*r, 0, math.sin(a)*r)
		local minD = math.huge
		for _, o in ipairs(others) do
			local d = Vector3.new(pt.X-o.Position.X, 0, pt.Z-o.Position.Z).Magnitude
			if d < minD then minD = d end
		end
		local score = minD + (minD >= SEPARATION_RADIUS and 60 or 0)
		if score > bestScore then bestScore = score; best = pt end
	end
	return best or origin
end

local function computePath(from, to)
	local path = PathfindingService:CreatePath({
		AgentRadius = 2.1, AgentHeight = 5,
		AgentCanJump = true, WaypointSpacing = 3,
	})
	local ok = pcall(function() path:ComputeAsync(from, to) end)
	if not ok or path.Status ~= Enum.PathStatus.Success then return nil end
	return path:GetWaypoints()
end

-- npc class
local NpcClass = {}
NpcClass.__index = NpcClass

function NpcClass.new(spawnPos, id, friendEntry)
	local self         = setmetatable({}, NpcClass)
	self.id            = id
	self.origin        = spawnPos
	self.friendEntry   = friendEntry
	self.state         = "Idle"
	self.idleTimer     = math.random(IDLE_MIN, IDLE_MAX) + id * 0.6
	self.naturalSpeed  = NPC_BASE_SPEED + (math.random() * 4 - 2)
	self.wanderTarget  = nil
	self.waypoints     = {}
	self.wpIdx         = 1
	self.lastPath      = 0
	self.lastGreet     = -GREET_COOLDOWN
	self.greetLocked   = false

	self.model, self.hum, self.animator, self.root = buildRig(spawnPos, id, friendEntry)
	self.hum.WalkSpeed = self.naturalSpeed
	self.tracks = loadBaseAnims(self.animator)

	task.delay(0.3 + id * 0.1, function()
		if self.hum and self.hum.Health > 0 then playTrack(self.tracks.idle) end
	end)

	self._deathConn = self.hum.Died:Connect(function() self:onDeath() end)
	self:startSenseLoop()

	print(string.format("[NPC %d] Ready — friend: %s", id, friendEntry and friendEntry.name or "none"))
	return self
end

function NpcClass:startSenseLoop()
	self._senseLoop = task.spawn(function()
		local tick = SENSE_TICK + math.random() * 0.05
		while self.model and self.model.Parent do
			if self.hum and self.hum.Health > 0 then
				pcall(function() self:sense() end)
			end
			task.wait(tick)
		end
	end)
end

-- triger greet within radius
function NpcClass:sense()
	if self.greetLocked then return end
	if os.clock() - self.lastGreet < GREET_COOLDOWN then return end
	if not self.root or not self.root.Parent then return end

	local myPos = self.root.Position
	for _, plr in ipairs(Players:GetPlayers()) do
		if activeGreetings[plr] then continue end
		local ch = plr.Character
		if not ch then continue end
		local pr = ch:FindFirstChild("HumanoidRootPart")
		local ph = ch:FindFirstChildOfClass("Humanoid")
		if not pr or not ph or ph.Health <= 0 then continue end

		if (pr.Position - myPos).Magnitude <= GREET_RADIUS then
			activeGreetings[plr] = true
			self.greetLocked     = true
			self.greetPlayer     = plr
			task.spawn(function() self:runGreetSequence(plr) end)
			break
		end
	end
end

-- greet player
function NpcClass:runGreetSequence(plr)
	self.lastGreet = os.clock()
	self.state     = "Greet"

    -- npc to stop walking
	self.hum.WalkSpeed = 0
	self.hum:MoveTo(self.root.Position)
	stopAllTracks(self.tracks)
	playTrack(self.tracks.idle, 0.1)

	-- face player
	local pr = plr.Character and plr.Character:FindFirstChild("HumanoidRootPart")
	if pr and self.root and self.root.Parent then
		local rp = self.root.Position
		self.root.CFrame = CFrame.lookAt(rp, Vector3.new(pr.Position.X, rp.Y, pr.Position.Z))
	end


	task.wait(0.2)


	local waveAnim       = Instance.new("Animation")
	waveAnim.AnimationId = ANIM_WAVE
	local waveTrack      = nil
	local ok, result     = pcall(function()
		return self.animator:LoadAnimation(waveAnim)
	end)
	if ok and result then
		waveTrack         = result
		waveTrack.Looped  = false
		stopAllTracks(self.tracks)
		waveTrack:Play(0.05)
	end
	
	
	task.wait(0.3)
	local head = self.model and self.model:FindFirstChild("Head")
	if head then
		local greeting = "Hello, my friend!"
		if self.friendEntry then
			greeting = "Hey! I'm " .. self.friendEntry.name .. "!"
		end
		Chat:Chat(head, greeting, Enum.ChatColor.White)
	end

	local waited = 0
	while waited < 4 do
		task.wait(0.1)
		waited = waited + 0.1
		if waveTrack == nil or not waveTrack.IsPlaying then break end
	end


	activeGreetings[plr] = nil
	self.greetPlayer     = nil


	self.state = "WalkAway"
	self.hum.WalkSpeed = self.naturalSpeed

	local angle = math.random() * math.pi * 2
	local dest  = self.root.Position
		+ Vector3.new(math.cos(angle) * WALK_AWAY_DIST, 0, math.sin(angle) * WALK_AWAY_DIST)

	stopAllTracks(self.tracks)
	playTrack(self.tracks.walk, 0.2)
	self.hum:MoveTo(dest)

	task.wait(WALK_AWAY_DURATION)


	if self.model and self.model.Parent then
		self.state     = "Idle"
		self.idleTimer = math.random(IDLE_MIN, IDLE_MAX)
		self.hum.WalkSpeed = self.naturalSpeed
		self.hum:MoveTo(self.root.Position)
	end

	self.greetLocked = false
end

-- path following
function NpcClass:followPath()
	if #self.waypoints == 0 then return end
	local wp = self.waypoints[self.wpIdx]
	if not wp then self.waypoints = {}; return end

	local myFlat = Vector3.new(self.root.Position.X, 0, self.root.Position.Z)
	local wpFlat = Vector3.new(wp.Position.X, 0, wp.Position.Z)
	if (wpFlat - myFlat).Magnitude < 3 then
		self.wpIdx = self.wpIdx + 1
		wp = self.waypoints[self.wpIdx]
		if not wp then self.waypoints = {}; return end
	end
	if wp.Action == Enum.PathWaypointAction.Jump then self.hum.Jump = true end
	self.hum:MoveTo(wp.Position)
end

-- heartbeat update
function NpcClass:update(dt, now)
	if not self.model or not self.model.Parent then return end
	if not self.hum   or self.hum.Health <= 0   then return end
	if not self.root  or not self.root.Parent    then return end

	if self.greetLocked then return end

	local speed = Vector3.new(
		self.root.AssemblyLinearVelocity.X, 0,
		self.root.AssemblyLinearVelocity.Z).Magnitude
	if speed > 1.2 then
		if self.tracks.walk and not self.tracks.walk.IsPlaying then
			stopAllTracks(self.tracks)
			playTrack(self.tracks.walk, 0.2)
		end
	else
		if self.tracks.idle and not self.tracks.idle.IsPlaying then
			stopAllTracks(self.tracks)
			playTrack(self.tracks.idle, 0.3)
		end
	end

-- idle
	if self.state == "Idle" then
		self.idleTimer = self.idleTimer - dt
		if self.idleTimer <= 0 then
			local pt       = pickWanderPoint(self.origin, self.root)
			self.waypoints = computePath(self.root.Position, pt) or {}
			self.wanderTarget = pt
			self.wpIdx     = 2
			self.state     = "Wander"
		end

	-- wander
	elseif self.state == "Wander" then
		if #self.waypoints > 0 then
			self:followPath()
			if self.wanderTarget then
				local flat = Vector3.new(
					self.wanderTarget.X, self.root.Position.Y, self.wanderTarget.Z)
				if (flat - self.root.Position).Magnitude < 4 then
					self.waypoints    = {}
					self.wanderTarget = nil
					self.state        = "Idle"
					self.idleTimer    = math.random(IDLE_MIN, IDLE_MAX)
					self.hum:MoveTo(self.root.Position)
				end
			end
		else
			self.state     = "Idle"
			self.idleTimer = math.random(IDLE_MIN, IDLE_MAX)
		end

	end
end

-- if the npc dies
function NpcClass:onDeath()
	if self.greetPlayer then
		activeGreetings[self.greetPlayer] = nil
		self.greetPlayer = nil
	end
	self.greetLocked = false
	if self._deathConn then self._deathConn:Disconnect(); self._deathConn = nil end

	task.delay(5, function()
		if self.model and self.model.Parent then self.model:Destroy() end
		self.model = nil; self.hum = nil; self.animator = nil; self.root = nil
		self.waypoints = {}; self.wpIdx = 1; self.tracks = {}

		self.model, self.hum, self.animator, self.root =
			buildRig(self.origin, self.id, self.friendEntry)
		self.hum.WalkSpeed = self.naturalSpeed
		self.tracks = loadBaseAnims(self.animator)
		CollectionService:AddTag(self.model, NPC_TAG)

		self._deathConn = self.hum.Died:Connect(function() self:onDeath() end)
		self:startSenseLoop()

		task.delay(0.3, function()
			if self.tracks.idle and self.hum and self.hum.Health > 0 then
				playTrack(self.tracks.idle)
			end
		end)

		self.state     = "Idle"
		self.idleTimer = math.random(IDLE_MIN, IDLE_MAX)
		print(string.format("[NPC %d] Respawned", self.id))
	end)
end


local function spawnAllNPCs(assignments)
	local npcs = {}
	local step = (math.pi * 2) / NPC_COUNT
	for i = 1, NPC_COUNT do
		local angle = step * i + (math.random() - 0.5) * 0.6
		local dist  = SCATTER_RADIUS * (0.55 + math.random() * 0.45)
		local pos   = Vector3.new(math.cos(angle)*dist, 0.5, math.sin(angle)*dist)
		npcs[i]     = NpcClass.new(pos, i, assignments[i])
		task.wait(0.2)
	end
	return npcs
end

local function startHeartbeat(npcs)
	RunService.Heartbeat:Connect(function(dt)
		local now = os.clock()
		dt = math.min(dt, 0.1)
		for _, npc in ipairs(npcs) do
			if npc.model and npc.model.Parent and npc.hum and npc.root then
				pcall(npc.update, npc, dt, now)
			end
		end
	end)
end


local function onPlayerJoined(player)
	print(string.format("[GreeterAI v6] %s joined — fetching friends...", player.Name))
	local list       = fetchFriendIds(player)
	local assignment = assignFriends(list, NPC_COUNT)
	local npcs       = spawnAllNPCs(assignment)
	startHeartbeat(npcs)
	print(string.format("[GreeterAI v6] %d NPCs active!", NPC_COUNT))
end

Players.PlayerAdded:Connect(onPlayerJoined)
for _, plr in ipairs(Players:GetPlayers()) do
	task.spawn(onPlayerJoined, plr)
end
