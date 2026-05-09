--[[
* I connected my Discord with Github but to credit jamesdoesluau (my discord) and my roblox username jameshasbands
	NPC Greeter System — ServerScriptService

	When a player joins, the server pulls their friends list and uses those
	friends' avatars to skin the NPCs. Each NPC wanders around, and when a
	player gets close enough, it stops, waves, says something, then walks off
	before going back to normal.

	Each NPC runs through a simple set of states:
	  Idle      - standing around, waiting before picking somewhere to walk
	  Wander    - walking toward a chosen point using pathfinding
	  Greet     - locked into the greeting sequence with a nearby player
	  WalkAway  - briefly walking off after greeting before going idle again

	The activeGreetings table makes sure only one NPC greets a player at a
	time. Once an NPC claims a player, no other NPC will try to greet them
	until that sequence fully finishes.

	Each NPC runs its own sense loop in a separate thread so proximity checks
	are staggered and don't all fire on the same frame.
]]

local PathfindingService = game:GetService("PathfindingService")
local Players            = game:GetService("Players")
local RunService         = game:GetService("RunService")
local CollectionService  = game:GetService("CollectionService")
local ServerStorage      = game:GetService("ServerStorage")
local Chat               = game:GetService("Chat")

-- default Roblox animation asset IDs
local ANIM_IDLE = "rbxassetid://180435571"
local ANIM_WALK = "rbxassetid://180426354"
local ANIM_WAVE = "rbxassetid://507770239"

-- all tuning values kept here so they're easy to find and adjust
local NPC_TAG            = "GreeterNPC"
local NPC_COUNT          = 5
local NPC_BASE_SPEED     = 12
local NPC_SPEED_VARIANCE = 5      -- each NPC's speed is offset by up to this amount so they don't all move at the same pace
local GREET_RADIUS       = 20
local WANDER_RADIUS_MIN  = 20     -- minimum wander radius per NPC (randomised on spawn)
local WANDER_RADIUS_MAX  = 50     -- maximum wander radius per NPC
local SEPARATION_RADIUS  = 18
local SENSE_TICK_MIN     = 0.1    -- sense loop fires somewhere between these two values, chosen per NPC
local SENSE_TICK_MAX     = 0.22
local GREET_COOLDOWN     = 15
local WALK_AWAY_DIST     = 25
local WALK_AWAY_DURATION = 5
local IDLE_MIN           = 2
local IDLE_MAX           = 7
local SCATTER_RADIUS     = 55

-- tracks which players are currently being greeted so no two NPCs try at once
local activeGreetings = {}

-- load the rig template once at startup rather than searching for it every spawn
local rigTemplate = (function()
	local folder = ServerStorage:FindFirstChild("NPCAssets")
	assert(folder, "[GreeterAI] ServerStorage is missing the 'NPCAssets' folder.")
	local t = folder:FindFirstChild("RigTemplate")
	assert(t, "[GreeterAI] 'NPCAssets' is missing a model named 'RigTemplate'.")
	print("[GreeterAI] RigTemplate found.")
	return t
end)()


-- fetches a player's friends list and returns it shuffled so NPC assignments
-- feel random each time rather than always showing the same friends first
local function fetchFriendIds(player)
	local ids = {}
	local ok, pages = pcall(function()
		return Players:GetFriendsAsync(player.UserId)
	end)
	if not ok or not pages then return ids end

	while true do
		for _, entry in ipairs(pages:GetCurrentPage()) do
			ids[#ids + 1] = { id = entry.Id, name = entry.Username }
		end
		if pages.IsFinished then break end
		if not pcall(function() pages:AdvanceToNextPageAsync() end) then break end
	end

	-- shuffle so the same friends don't always get the first NPC slots
	for i = #ids, 2, -1 do
		local j = math.random(1, i)
		ids[i], ids[j] = ids[j], ids[i]
	end

	return ids
end

-- distributes friends across NPC slots by cycling through the list
-- if there are fewer friends than NPCs it wraps around and reuses entries
local function assignFriends(friendList, count)
	if #friendList == 0 then return {} end
	local assignments = {}
	for i = 1, count do
		assignments[i] = friendList[((i - 1) % #friendList) + 1]
	end
	return assignments
end

-- applies a friend's avatar to an NPC after a short delay
-- the delay gives the rig time to fully load into the world first
-- scales are normalised so all NPCs stay the same size regardless of the friend's body settings
local function applyFriendAppearance(model, friendEntry)
	task.spawn(function()
		task.wait(0.8)
		local hum = model:FindFirstChildOfClass("Humanoid")
		if not hum then return end

		local ok, desc = pcall(function()
			return Players:GetHumanoidDescriptionFromUserIdAsync(friendEntry.id)
		end)
		if not ok or not desc then return end

		-- force uniform scale so avatars with unusual proportions don't look oversized or tiny
		desc.BodyTypeScale   = 0
		desc.HeadScale       = 1
		desc.HeightScale     = 1
		desc.WidthScale      = 1
		desc.ProportionScale = 0
		desc.DepthScale      = 1

		pcall(function() hum:ApplyDescription(desc) end)
	end)
end

-- clones the rig template, removes the default Animate script (we control animations manually),
-- sets up the Humanoid and Animator, then places the model in the world
local function buildRig(position, npcId, friendEntry)
	local model = rigTemplate:Clone()
	model.Name  = "NPC_" .. npcId

	local hum      = model:FindFirstChildOfClass("Humanoid")
	local rootPart = model:FindFirstChild("HumanoidRootPart")
	assert(hum and rootPart, "[GreeterAI] RigTemplate is missing Humanoid or HumanoidRootPart.")

	-- remove the default Animate script so it doesn't fight with our animation code
	local animScript = model:FindFirstChild("Animate")
	if animScript then animScript:Destroy() end

	-- make sure there's an Animator to load tracks through
	local animator = hum:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = hum
	end

	hum.MaxHealth               = 100
	hum.Health                  = 100
	hum.AutomaticScalingEnabled = false
	hum.DisplayDistanceType     = Enum.HumanoidDisplayDistanceType.None
	hum.NameDisplayDistance     = 0
	hum.HealthDisplayDistance   = 0

	model:PivotTo(CFrame.new(position + Vector3.new(0, 3.5, 0)))
	model.Parent = workspace
	CollectionService:AddTag(model, NPC_TAG)

	if friendEntry then
		applyFriendAppearance(model, friendEntry)
	end

	return model, hum, animator, rootPart
end


-- loads the idle and walk animations onto the given Animator and returns them
-- the wave is not loaded here because it needs a fresh track each time it plays
-- to avoid issues with reusing a track that has already stopped
local function loadBaseAnimations(animator)
	local function loadTrack(animId, looped)
		local anim = Instance.new("Animation")
		anim.AnimationId = animId
		local ok, track = pcall(function() return animator:LoadAnimation(anim) end)
		if ok and track then
			track.Looped = looped
			return track
		end
	end

	return {
		idle = loadTrack(ANIM_IDLE, true),
		walk = loadTrack(ANIM_WALK, true),
	}
end

-- stops every track in the table with a short fade so transitions aren't jarring
local function stopAllTracks(tracks)
	for _, track in pairs(tracks) do
		if track and track.IsPlaying then
			track:Stop(0.1)
		end
	end
end

-- plays a track only if it isn't already running
local function playTrack(track, fadeTime)
	if track and not track.IsPlaying then
		track:Play(fadeTime or 0.15)
	end
end


-- returns the HumanoidRootPart of every other NPC currently in the world
-- used when scoring wander candidates so NPCs avoid bunching up
local function getOtherNpcRoots(selfRoot)
	local roots = {}
	for _, model in ipairs(CollectionService:GetTagged(NPC_TAG)) do
		local root = model:FindFirstChild("HumanoidRootPart")
		if root and root ~= selfRoot then
			roots[#roots + 1] = root
		end
	end
	return roots
end

-- picks a wander destination within the NPC's personal wander radius
-- tries 12 candidates and scores each by how far it sits from other NPCs
-- the bonus score for exceeding SEPARATION_RADIUS keeps the group spread out
-- without any complex flocking math
local function pickWanderPoint(origin, selfRoot, wanderRadius)
	local otherRoots = getOtherNpcRoots(selfRoot)
	local bestPoint, bestScore = nil, -math.huge

	for _ = 1, 12 do
		local angle     = math.random() * math.pi * 2
		local dist      = math.random(8, wanderRadius)
		local candidate = origin + Vector3.new(math.cos(angle) * dist, 0, math.sin(angle) * dist)

		-- find how close the nearest other NPC is to this candidate
		local closestDist = math.huge
		for _, root in ipairs(otherRoots) do
			local flat = Vector3.new(candidate.X - root.Position.X, 0, candidate.Z - root.Position.Z)
			if flat.Magnitude < closestDist then
				closestDist = flat.Magnitude
			end
		end

		local score = closestDist + (closestDist >= SEPARATION_RADIUS and 60 or 0)
		if score > bestScore then
			bestScore = score
			bestPoint = candidate
		end
	end

	return bestPoint or origin
end

-- computes a pathfinding path between two positions and returns the waypoints
-- returns nil on failure so callers can fall back to idle cleanly
local function computePath(fromPos, toPos)
	local path = PathfindingService:CreatePath({
		AgentRadius     = 2.1,
		AgentHeight     = 5,
		AgentCanJump    = true,
		WaypointSpacing = 3,
	})

	local ok = pcall(function() path:ComputeAsync(fromPos, toPos) end)
	if not ok or path.Status ~= Enum.PathStatus.Success then return nil end

	return path:GetWaypoints()
end


-- NpcClass manages everything about one NPC: its model, state, animations,
-- pathfinding, greeting behaviour, and respawning on death
local NpcClass = {}
NpcClass.__index = NpcClass

function NpcClass.new(spawnPos, id, friendEntry)
	local self = setmetatable({}, NpcClass)

	self.id          = id
	self.origin      = spawnPos
	self.friendEntry = friendEntry

	-- each NPC gets its own randomised wander radius so they naturally cover different amounts of ground
	self.wanderRadius = math.random(WANDER_RADIUS_MIN, WANDER_RADIUS_MAX)

	-- speed variance is wide enough that NPCs visibly move at different paces
	self.naturalSpeed = NPC_BASE_SPEED + (math.random() * NPC_SPEED_VARIANCE * 2 - NPC_SPEED_VARIANCE)

	-- each NPC polls for players at a slightly different rate so detections don't cluster
	self.senseTick = SENSE_TICK_MIN + math.random() * (SENSE_TICK_MAX - SENSE_TICK_MIN)

	-- pathfinding state
	self.state        = "Idle"
	self.wanderTarget = nil
	self.waypoints    = {}
	self.wpIdx        = 1

	-- idle timer is fully random with no id offset so NPCs don't drift into sync over time
	self.idleTimer = math.random() * (IDLE_MAX - IDLE_MIN) + IDLE_MIN

	-- greeting state
	self.lastGreet   = -GREET_COOLDOWN
	self.greetLocked = false
	self.greetPlayer = nil

	self.model, self.hum, self.animator, self.root = buildRig(spawnPos, id, friendEntry)
	self.hum.WalkSpeed = self.naturalSpeed
	self.tracks = loadBaseAnimations(self.animator)

	-- kick off movement immediately rather than waiting for the idle timer to expire
	-- a short wait lets the rig settle into the world before we start moving it
	task.delay(0.15 + math.random() * 0.2, function()
		if not (self.hum and self.hum.Health > 0 and self.model and self.model.Parent) then return end

		local target   = pickWanderPoint(self.origin, self.root, self.wanderRadius)
		local waypoints = computePath(self.root.Position, target)

		if waypoints and #waypoints > 1 then
			self.waypoints    = waypoints
			self.wanderTarget = target
			self.wpIdx        = 2
			self.state        = "Wander"
			stopAllTracks(self.tracks)
			playTrack(self.tracks.walk, 0.2)
		else
			-- if the first path attempt fails just start idle and let the normal loop take over
			playTrack(self.tracks.idle)
		end
	end)

	self._deathConn = self.hum.Died:Connect(function() self:onDeath() end)
	self:startSenseLoop()

	print(string.format("[NPC %d] Ready — friend: %s | speed: %.1f | wanderR: %d",
		id,
		friendEntry and friendEntry.name or "none",
		self.naturalSpeed,
		self.wanderRadius
		))

	return self
end

-- runs in its own thread so each NPC checks for players on its own schedule
function NpcClass:startSenseLoop()
	self._senseLoop = task.spawn(function()
		while self.model and self.model.Parent do
			if self.hum and self.hum.Health > 0 then
				pcall(function() self:sense() end)
			end
			task.wait(self.senseTick)
		end
	end)
end

-- checks every player's distance and claims the first one close enough to greet
-- activeGreetings and greetLocked together ensure only one NPC greets any player at a time
function NpcClass:sense()
	if self.greetLocked then return end
	if os.clock() - self.lastGreet < GREET_COOLDOWN then return end
	if not self.root or not self.root.Parent then return end

	local myPos = self.root.Position

	for _, player in ipairs(Players:GetPlayers()) do
		if activeGreetings[player] then continue end

		local character  = player.Character
		if not character then continue end

		local playerRoot = character:FindFirstChild("HumanoidRootPart")
		local playerHum  = character:FindFirstChildOfClass("Humanoid")
		if not playerRoot or not playerHum or playerHum.Health <= 0 then continue end

		if (playerRoot.Position - myPos).Magnitude <= GREET_RADIUS then
			-- claim the player before spawning the thread to prevent a race condition
			activeGreetings[player] = true
			self.greetLocked        = true
			self.greetPlayer        = player
			task.spawn(function() self:runGreetSequence(player) end)
			break
		end
	end
end

-- the full greeting sequence: stop, face the player, wave, chat, walk away, resume
-- runs in its own thread so it doesn't block the sense loop or Heartbeat
function NpcClass:runGreetSequence(player)
	self.lastGreet = os.clock()
	self.state     = "Greet"

	-- freeze the NPC in place for the duration of the greeting
	self.hum.WalkSpeed = 0
	self.hum:MoveTo(self.root.Position)
	stopAllTracks(self.tracks)
	playTrack(self.tracks.idle, 0.1)

	-- rotate to face the player on the Y axis only so the NPC doesn't tilt
	local playerRoot = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	if playerRoot and self.root and self.root.Parent then
		local myPos = self.root.Position
		self.root.CFrame = CFrame.lookAt(
			myPos,
			Vector3.new(playerRoot.Position.X, myPos.Y, playerRoot.Position.Z)
		)
	end

	task.wait(0.2)

	-- load a fresh wave track each time to avoid stale-track playback issues
	local waveAnim = Instance.new("Animation")
	waveAnim.AnimationId = ANIM_WAVE

	local waveTrack
	local ok, result = pcall(function()
		return self.animator:LoadAnimation(waveAnim)
	end)
	if ok and result then
		waveTrack        = result
		waveTrack.Looped = false
		stopAllTracks(self.tracks)
		waveTrack:Play(0.05)
	end

	task.wait(0.3)

	-- say something via the in-world chat bubble above the NPC's head
	local head = self.model and self.model:FindFirstChild("Head")
	if head then
		local message = "Hello, my friend!"
		if self.friendEntry then
			message = "Hey! I'm " .. self.friendEntry.name .. "!"
		end
		Chat:Chat(head, message, Enum.ChatColor.White)
	end

	-- wait for the wave to finish but bail early if it somehow stops or never played
	local elapsed = 0
	while elapsed < 4 do
		task.wait(0.1)
		elapsed = elapsed + 0.1
		if waveTrack == nil or not waveTrack.IsPlaying then break end
	end

	-- release the player so other NPCs can greet them again
	activeGreetings[player] = nil
	self.greetPlayer        = nil

	-- walk away in a random direction before going back to normal behaviour
	self.state         = "WalkAway"
	self.hum.WalkSpeed = self.naturalSpeed

	local angle    = math.random() * math.pi * 2
	local walkDest = self.root.Position + Vector3.new(
		math.cos(angle) * WALK_AWAY_DIST,
		0,
		math.sin(angle) * WALK_AWAY_DIST
	)

	stopAllTracks(self.tracks)
	playTrack(self.tracks.walk, 0.2)
	self.hum:MoveTo(walkDest)

	task.wait(WALK_AWAY_DURATION)

	-- only resume if the NPC still exists (it could have died during the walk)
	if self.model and self.model.Parent then
		self.state     = "Idle"
		self.idleTimer = math.random() * (IDLE_MAX - IDLE_MIN) + IDLE_MIN
		self.hum.WalkSpeed = self.naturalSpeed
		self.hum:MoveTo(self.root.Position)
	end

	self.greetLocked = false
end


-- steps toward the next waypoint in the current path
-- uses an XZ-only distance check to avoid Y differences causing waypoints to be skipped too early
function NpcClass:followPath()
	if #self.waypoints == 0 then return end

	local wp = self.waypoints[self.wpIdx]
	if not wp then
		self.waypoints = {}
		return
	end

	local myFlat = Vector3.new(self.root.Position.X, 0, self.root.Position.Z)
	local wpFlat = Vector3.new(wp.Position.X, 0, wp.Position.Z)

	if (wpFlat - myFlat).Magnitude < 3 then
		self.wpIdx = self.wpIdx + 1
		wp = self.waypoints[self.wpIdx]
		if not wp then
			self.waypoints = {}
			return
		end
	end

	if wp.Action == Enum.PathWaypointAction.Jump then
		self.hum.Jump = true
	end

	self.hum:MoveTo(wp.Position)
end

-- called every Heartbeat — switches animations based on actual velocity and runs the state machine
function NpcClass:update(dt)
	if not self.model or not self.model.Parent then return end
	if not self.hum   or self.hum.Health <= 0   then return end
	if not self.root  or not self.root.Parent    then return end
	if self.greetLocked then return end

	-- use actual horizontal velocity rather than state to drive animation
	-- so the visual always matches what the character is physically doing
	local horizontalSpeed = Vector3.new(
		self.root.AssemblyLinearVelocity.X, 0,
		self.root.AssemblyLinearVelocity.Z
	).Magnitude

	if horizontalSpeed > 1.2 then
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

	if self.state == "Idle" then
		self.idleTimer = self.idleTimer - dt
		if self.idleTimer <= 0 then
			local target    = pickWanderPoint(self.origin, self.root, self.wanderRadius)
			local waypoints = computePath(self.root.Position, target)

			if waypoints and #waypoints > 1 then
				self.waypoints    = waypoints
				self.wanderTarget = target
				self.wpIdx        = 2  -- index 1 is always the NPC's current position, so skip it
				self.state        = "Wander"
			else
				-- path failed, reset the timer and try again after a short wait
				self.idleTimer = math.random() * (IDLE_MAX - IDLE_MIN) + IDLE_MIN
			end
		end

	elseif self.state == "Wander" then
		if #self.waypoints > 0 then
			self:followPath()

			if self.wanderTarget then
				local flat = Vector3.new(self.wanderTarget.X, self.root.Position.Y, self.wanderTarget.Z)
				if (flat - self.root.Position).Magnitude < 4 then
					-- arrived at the destination, switch to idle and pick a random wait time
					self.waypoints    = {}
					self.wanderTarget = nil
					self.state        = "Idle"
					self.idleTimer    = math.random() * (IDLE_MAX - IDLE_MIN) + IDLE_MIN
					self.hum:MoveTo(self.root.Position)
				end
			end
		else
			-- waypoints ran out before reaching the target, just go idle
			self.state     = "Idle"
			self.idleTimer = math.random() * (IDLE_MAX - IDLE_MIN) + IDLE_MIN
		end
	end
end

-- handles NPC death: releases any greeting lock it was holding, then rebuilds the NPC after 5 seconds
function NpcClass:onDeath()
	if self.greetPlayer then
		activeGreetings[self.greetPlayer] = nil
		self.greetPlayer = nil
	end
	self.greetLocked = false

	if self._deathConn then
		self._deathConn:Disconnect()
		self._deathConn = nil
	end

	task.delay(5, function()
		if self.model and self.model.Parent then
			self.model:Destroy()
		end

		self.model     = nil
		self.hum       = nil
		self.animator  = nil
		self.root      = nil
		self.waypoints = {}
		self.wpIdx     = 1
		self.tracks    = {}

		self.model, self.hum, self.animator, self.root =
			buildRig(self.origin, self.id, self.friendEntry)

		self.hum.WalkSpeed = self.naturalSpeed
		self.tracks = loadBaseAnimations(self.animator)
		CollectionService:AddTag(self.model, NPC_TAG)

		self._deathConn = self.hum.Died:Connect(function() self:onDeath() end)
		self:startSenseLoop()

		-- start moving immediately on respawn, same as initial spawn
		task.delay(0.15 + math.random() * 0.2, function()
			if not (self.hum and self.hum.Health > 0 and self.model and self.model.Parent) then return end

			local target    = pickWanderPoint(self.origin, self.root, self.wanderRadius)
			local waypoints = computePath(self.root.Position, target)

			if waypoints and #waypoints > 1 then
				self.waypoints    = waypoints
				self.wanderTarget = target
				self.wpIdx        = 2
				self.state        = "Wander"
				stopAllTracks(self.tracks)
				playTrack(self.tracks.walk, 0.2)
			else
				self.state     = "Idle"
				self.idleTimer = math.random() * (IDLE_MAX - IDLE_MIN) + IDLE_MIN
				playTrack(self.tracks.idle)
			end
		end)

		print(string.format("[NPC %d] Respawned.", self.id))
	end)
end


-- spawns all NPCs in a rough circle around the world origin, with some angle and distance
-- randomness so they don't land in a perfect ring. Staggered with a small wait between
-- each one to spread out the load from cloning and avatar loading.
local function spawnAllNPCs(friendAssignments)
	local npcs      = {}
	local angleStep = (math.pi * 2) / NPC_COUNT

	for i = 1, NPC_COUNT do
		local angle = angleStep * i + (math.random() - 0.5) * 0.8
		local dist  = SCATTER_RADIUS * (0.5 + math.random() * 0.5)
		local pos   = Vector3.new(math.cos(angle) * dist, 0.5, math.sin(angle) * dist)
		npcs[i]     = NpcClass.new(pos, i, friendAssignments[i])
		task.wait(0.15)
	end

	return npcs
end

-- connects to Heartbeat and calls update on every NPC each frame
-- dt is capped so a lag spike doesn't cause idle timers to jump by several seconds at once
local function startHeartbeat(npcs)
	RunService.Heartbeat:Connect(function(dt)
		dt = math.min(dt, 0.1)
		for _, npc in ipairs(npcs) do
			if npc.model and npc.model.Parent and npc.hum and npc.root then
				pcall(npc.update, npc, dt)
			end
		end
	end)
end


local function onPlayerJoined(player)
	print(string.format("[GreeterAI] %s joined — fetching friends...", player.Name))
	local friendList  = fetchFriendIds(player)
	local assignments = assignFriends(friendList, NPC_COUNT)
	local npcs        = spawnAllNPCs(assignments)
	startHeartbeat(npcs)
	print(string.format("[GreeterAI] %d NPCs active for %s.", NPC_COUNT, player.Name))
end

Players.PlayerAdded:Connect(onPlayerJoined)

-- handle players who were already in the server before this script ran
for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(onPlayerJoined, player)
end
