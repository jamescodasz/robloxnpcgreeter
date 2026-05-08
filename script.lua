--[[
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

	Each NPC also runs its own sense loop in a separate thread so the
	proximity checks are staggered and don't all fire at the same time.
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

-- all tuning values are kept here so they're easy to find and adjust
local NPC_TAG            = "GreeterNPC"   -- tag applied to every NPC model
local NPC_COUNT          = 5              -- how many NPCs to spawn per player
local NPC_BASE_SPEED     = 12             -- base walk speed before per-NPC variance
local GREET_RADIUS       = 20             -- how close a player needs to be to trigger a greeting
local WANDER_RADIUS      = 40             -- max distance an NPC will wander from its origin
local SEPARATION_RADIUS  = 18             -- NPCs try to stay at least this far apart when picking wander targets
local SENSE_TICK         = 0.15           -- seconds between each proximity check per NPC
local GREET_COOLDOWN     = 15             -- seconds before an NPC can greet again after finishing
local WALK_AWAY_DIST     = 25             -- how far the NPC walks after finishing a greeting
local WALK_AWAY_DURATION = 5              -- how long the NPC spends walking away (in seconds)
local IDLE_MIN           = 3              -- minimum seconds an NPC stands idle before wandering
local IDLE_MAX           = 9              -- maximum seconds an NPC stands idle before wandering
local SCATTER_RADIUS     = 55             -- radius around the world origin where NPCs initially spawn

-- tracks which players are currently being greeted so no two NPCs try at once
local activeGreetings = {}

-- load the rig template once at startup rather than searching for it repeatedly
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

	-- shuffle so the same friends don't always appear first
	for i = #ids, 2, -1 do
		local j = math.random(1, i)
		ids[i], ids[j] = ids[j], ids[i]
	end

	return ids
end

-- distributes friends across the NPC slots by cycling through the list
-- if there are fewer friends than NPCs, it wraps around and reuses entries
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
-- scales are normalized so all NPCs stay the same size regardless of the friend's body settings
local function applyFriendAppearance(model, friendEntry)
	task.spawn(function()
		task.wait(0.8)
		local hum = model:FindFirstChildOfClass("Humanoid")
		if not hum then return end

		local ok, desc = pcall(function()
			return Players:GetHumanoidDescriptionFromUserIdAsync(friendEntry.id)
		end)
		if not ok or not desc then return end

		-- force a uniform scale so avatars with unusual body proportions still fit
		desc.BodyTypeScale   = 0
		desc.HeadScale       = 1
		desc.HeightScale     = 1
		desc.WidthScale      = 1
		desc.ProportionScale = 0
		desc.DepthScale      = 1

		pcall(function() hum:ApplyDescription(desc) end)
	end)
end

-- clones the rig template, strips the default Animate script (we handle animations manually),
-- sets up the Humanoid and Animator, then places it in the world
local function buildRig(position, npcId, friendEntry)
	local model = rigTemplate:Clone()
	model.Name  = "NPC_" .. npcId

	local hum      = model:FindFirstChildOfClass("Humanoid")
	local rootPart = model:FindFirstChild("HumanoidRootPart")
	assert(hum and rootPart, "[GreeterAI] RigTemplate is missing Humanoid or HumanoidRootPart.")

	-- remove the default Animate script so we can control animations ourselves
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
	hum.WalkSpeed               = NPC_BASE_SPEED + (math.random() * 4 - 2) -- slight variance so NPCs don't all feel identical
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
-- the wave is intentionally not loaded here because it needs a fresh track each
-- time it plays to avoid issues with reusing a stopped track
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

-- stops every track in the given table with a short fade so transitions aren't jarring
local function stopAllTracks(tracks)
	for _, track in pairs(tracks) do
		if track and track.IsPlaying then
			track:Stop(0.1)
		end
	end
end

-- plays a track only if it isn't already playing, using an optional fade-in time
local function playTrack(track, fadeTime)
	if track and not track.IsPlaying then
		track:Play(fadeTime or 0.15)
	end
end


-- collects the HumanoidRootPart of every other NPC in the world
-- used when picking a wander destination so NPCs avoid clustering together
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

-- picks a wander point within WANDER_RADIUS of the origin point
-- tries 12 candidate points and scores each by how far it is from other NPCs
-- this keeps NPCs spread out without needing any complex flocking logic
local function pickWanderPoint(origin, selfRoot)
	local otherRoots = getOtherNpcRoots(selfRoot)
	local bestPoint, bestScore = nil, -math.huge

	for _ = 1, 12 do
		local angle     = math.random() * math.pi * 2
		local dist      = math.random(8, WANDER_RADIUS)
		local candidate = origin + Vector3.new(math.cos(angle) * dist, 0, math.sin(angle) * dist)

		-- find the closest other NPC to this candidate point
		local closestDist = math.huge
		for _, root in ipairs(otherRoots) do
			local flat = Vector3.new(candidate.X - root.Position.X, 0, candidate.Z - root.Position.Z)
			if flat.Magnitude < closestDist then
				closestDist = flat.Magnitude
			end
		end

		-- bonus score if this point is far enough away to keep separation
		local score = closestDist + (closestDist >= SEPARATION_RADIUS and 60 or 0)
		if score > bestScore then
			bestScore = score
			bestPoint = candidate
		end
	end

	return bestPoint or origin
end

-- runs pathfinding between two positions and returns the waypoints if successful
-- returns nil if the path fails so callers can fall back gracefully
local function computePath(fromPos, toPos)
	local path = PathfindingService:CreatePath({
		AgentRadius  = 2.1,
		AgentHeight  = 5,
		AgentCanJump = true,
		WaypointSpacing = 3,
	})

	local ok = pcall(function() path:ComputeAsync(fromPos, toPos) end)
	if not ok or path.Status ~= Enum.PathStatus.Success then return nil end

	return path:GetWaypoints()
end


-- NpcClass handles everything about a single NPC: its model, state, animations,
-- pathfinding, greeting behaviour, and respawning after death
local NpcClass = {}
NpcClass.__index = NpcClass

function NpcClass.new(spawnPos, id, friendEntry)
	local self = setmetatable({}, NpcClass)

	self.id          = id
	self.origin      = spawnPos      -- used when picking wander points and for respawning
	self.friendEntry = friendEntry   -- the friend whose avatar this NPC wears (can be nil)
	self.state       = "Idle"

	-- stagger idle timers by NPC id so they don't all start wandering simultaneously
	self.idleTimer    = math.random(IDLE_MIN, IDLE_MAX) + id * 0.6
	self.naturalSpeed = NPC_BASE_SPEED + (math.random() * 4 - 2)

	-- pathfinding state
	self.wanderTarget = nil
	self.waypoints    = {}
	self.wpIdx        = 1

	-- greeting state
	self.lastGreet   = -GREET_COOLDOWN  -- start ready to greet immediately
	self.greetLocked = false             -- true while a greeting sequence is running
	self.greetPlayer = nil               -- which player is currently being greeted

	self.model, self.hum, self.animator, self.root = buildRig(spawnPos, id, friendEntry)
	self.hum.WalkSpeed = self.naturalSpeed
	self.tracks = loadBaseAnimations(self.animator)

	-- small delay before playing idle so the rig has settled into the world
	task.delay(0.3 + id * 0.1, function()
		if self.hum and self.hum.Health > 0 then
			playTrack(self.tracks.idle)
		end
	end)

	self._deathConn = self.hum.Died:Connect(function() self:onDeath() end)
	self:startSenseLoop()

	print(string.format("[NPC %d] Ready — friend: %s", id, friendEntry and friendEntry.name or "none"))
	return self
end

-- runs in its own thread so each NPC checks for players independently
-- the small random jitter on the tick prevents all NPCs from firing on the same frame
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

-- checks every player's distance and claims the first one close enough to greet
-- the activeGreetings table and greetLocked flag together ensure exclusivity —
-- only one NPC greets any given player at a time, and this NPC won't try again
-- until its cooldown has expired
function NpcClass:sense()
	if self.greetLocked then return end
	if os.clock() - self.lastGreet < GREET_COOLDOWN then return end
	if not self.root or not self.root.Parent then return end

	local myPos = self.root.Position

	for _, player in ipairs(Players:GetPlayers()) do
		if activeGreetings[player] then continue end

		local character = player.Character
		if not character then continue end

		local playerRoot = character:FindFirstChild("HumanoidRootPart")
		local playerHum  = character:FindFirstChildOfClass("Humanoid")
		if not playerRoot or not playerHum or playerHum.Health <= 0 then continue end

		if (playerRoot.Position - myPos).Magnitude <= GREET_RADIUS then
			-- claim this player before spawning the sequence so no race condition occurs
			activeGreetings[player] = true
			self.greetLocked        = true
			self.greetPlayer        = player
			task.spawn(function() self:runGreetSequence(player) end)
			break
		end
	end
end

-- the full greeting sequence: stop, face the player, wave, chat, walk away, then resume
-- this runs in its own thread (spawned in sense) so it doesn't block anything else
function NpcClass:runGreetSequence(player)
	self.lastGreet = os.clock()
	self.state     = "Greet"

	-- stop the NPC in place so it doesn't keep wandering during the greeting
	self.hum.WalkSpeed = 0
	self.hum:MoveTo(self.root.Position)
	stopAllTracks(self.tracks)
	playTrack(self.tracks.idle, 0.1)

	-- rotate to face the player (only on the Y axis so the NPC doesn't tilt)
	local playerRoot = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	if playerRoot and self.root and self.root.Parent then
		local myPos = self.root.Position
		self.root.CFrame = CFrame.lookAt(
			myPos,
			Vector3.new(playerRoot.Position.X, myPos.Y, playerRoot.Position.Z)
		)
	end

	task.wait(0.2)

	-- load and play the wave animation fresh each time to avoid stale track issues
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

	-- wait for the wave to finish, but don't wait forever in case the track gets cut short
	local elapsed = 0
	while elapsed < 4 do
		task.wait(0.1)
		elapsed = elapsed + 0.1
		if waveTrack == nil or not waveTrack.IsPlaying then break end
	end

	-- release the player so other NPCs can greet them again
	activeGreetings[player] = nil
	self.greetPlayer        = nil

	-- walk away in a random direction before resuming idle/wander behaviour
	self.state         = "WalkAway"
	self.hum.WalkSpeed = self.naturalSpeed

	local angle   = math.random() * math.pi * 2
	local walkDest = self.root.Position + Vector3.new(
		math.cos(angle) * WALK_AWAY_DIST,
		0,
		math.sin(angle) * WALK_AWAY_DIST
	)

	stopAllTracks(self.tracks)
	playTrack(self.tracks.walk, 0.2)
	self.hum:MoveTo(walkDest)

	task.wait(WALK_AWAY_DURATION)

	-- only resume if the NPC still exists (it might have died during the walk)
	if self.model and self.model.Parent then
		self.state     = "Idle"
		self.idleTimer = math.random(IDLE_MIN, IDLE_MAX)
		self.hum.WalkSpeed = self.naturalSpeed
		self.hum:MoveTo(self.root.Position)
	end

	self.greetLocked = false
end


-- advances the NPC toward the next waypoint in its current path
-- waypoints are stepped through one at a time using MoveTo, with a distance
-- threshold to decide when to move on to the next one
function NpcClass:followPath()
	if #self.waypoints == 0 then return end

	local wp = self.waypoints[self.wpIdx]
	if not wp then
		self.waypoints = {}
		return
	end

	-- compare positions on the XZ plane only to avoid Y-axis throwing off the distance check
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

-- called every Heartbeat; handles animation switching and the idle/wander state machine
-- greetLocked early-out prevents any state changes w
