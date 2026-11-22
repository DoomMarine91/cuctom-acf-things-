-- ACF Missiles E2 - Native ACF Bridge v38 CONTROLLED ACF EXHAUST + PHYSICAL XYZ SCALING + WIRE/LASER TURN SMOOTHING + LASER LOS
-- This bridge delegates guidance, seeker acquisition, missile flight, fuses,
-- turn rate, drag, thrust, gravity and flight timing to ACF-Missiles itself.
-- Powered missile definitions use the BGM-71E flight-stat baseline.
-- BOMB/GBU classes marked nothrust retain their own ACF identity and gravity
-- behavior; they still accept native Wire/Laser guidance and their own fins.
-- The optional E2-controlled launch hold wraps each missile's own guidance
-- result boundary only: native GetGuidance() still runs and its result passes
-- through unchanged as soon as that missile's E2 Lambda timer releases it.

if SERVER then
    AddCSLuaFile("entities/gmod_wire_expression2/core/custom/cl_acf_missiles_clean.lua")
end

E2Lib.RegisterExtension("acfmissiles_clean", true, "Creates native ACF missiles from Expression 2.")

local MISSILE_CLASS = "acf_missile"
local MAX_SPEED_MPH = 10000
local MIN_VISUAL_SCALE = 0.01
local MAX_VISUAL_SCALE = 10
local MIN_SMOKE_SCALE = 0
local MAX_SMOKE_SCALE = 10
local MODEL_SCALE_DELTA = 0.000001
local chipMissiles = setmetatable({}, { __mode = "k" })
local rackMissiles = setmetatable({}, { __mode = "k" })

-- ACF missiles receive ACF damage through ENT:ACF_OnDamage(Entity, Energy,
-- FrAera, Angle, Inflictor), including blast damage routed through ACF. Each
-- bridge-created missile wraps that method and ignores damage only when BOTH
-- the victim and the ACF damage source are bridge-created protected munitions.
local FRIENDLY_NULL_HIT = { Damage = 0, Overkill = 0, Loss = 0, Kill = false }

-- Declare this before helpers that call it; Lua local functions are only
-- visible to code parsed after their declaration.
local function validMissile(ent)
    return IsValid(ent) and ent:GetClass() == MISSILE_CLASS
end

local function isProtectedFriendlyMunition(ent)
    return validMissile(ent) and ent.ACFM_CleanFriendlyProtection == true
end

local function installFriendlyDamageProtection(missile)
    if not validMissile(missile) or missile.ACFM_CleanFriendlyDamageWrapped then return end

    local original = missile.ACF_OnDamage
    if not isfunction(original) then return end

    missile.ACFM_CleanOriginalOnDamage = original
    missile.ACF_OnDamage = function(ent, entity, energy, frArea, angle, inflictor, ...)
        if ent.ACFM_CleanFriendlyProtection == true then
            if isProtectedFriendlyMunition(inflictor) or isProtectedFriendlyMunition(entity) then
                return table.Copy(FRIENDLY_NULL_HIT)
            end
        end

        return ent.ACFM_CleanOriginalOnDamage(ent, entity, energy, frArea, angle, inflictor, ...)
    end

    missile.ACFM_CleanFriendlyDamageWrapped = true
end

local function report(chip, message)
    if IsValid(chip) then
        chip.ACFM_CleanStatus = tostring(message)
    end
end

local function missileDefinitions()
    local entities = list and list.Get and list.Get("ACFEnts")
    return entities and entities.Guns or {}
end

local function isMissileDefinition(definition)
    if not istable(definition) or not isstring(definition.gunclass) then return false end

    local classes = list and list.Get and list.Get("ACFClasses")
    local gunClasses = classes and classes.GunClass
    local class = gunClasses and gunClasses[definition.gunclass]

    return istable(class) and class.type == "missile"
end

local function getGunClass(definition)
    if not istable(definition) or not isstring(definition.gunclass) then return nil end

    local classes = list and list.Get and list.Get("ACFClasses")
    local gunClasses = classes and classes.GunClass
    return gunClasses and gunClasses[definition.gunclass] or nil
end

local function isGravityOnlyDefinition(definition)
    local class = getGunClass(definition)
    return istable(class) and class.nothrust == true
end

local function getMissileIDs()
    local found = {}

    for id, definition in pairs(missileDefinitions()) do
        if isstring(id) and isMissileDefinition(definition) then
            found[#found + 1] = id
        end
    end

    table.sort(found)
    return found
end

local function getMissileID(index)
    index = math.floor(tonumber(index) or 0)
    local ids = getMissileIDs()

    if index < 1 or index > #ids then
        return nil, index, #ids
    end

    return ids[index], index, #ids
end

local function getGun(id)
    if not isstring(id) or id == "" then return nil end

    local gun = missileDefinitions()[id]
    if not isMissileDefinition(gun) then return nil end

    -- Add both native guidance choices to this registered definition. ACF's
    -- configurable parser validates against the selected gun's guidance list.
    gun.guidance = istable(gun.guidance) and gun.guidance or {}
    if not table.HasValue(gun.guidance, "Wire") then gun.guidance[#gun.guidance + 1] = "Wire" end
    if not table.HasValue(gun.guidance, "Laser") then gun.guidance[#gun.guidance + 1] = "Laser" end

    return gun
end

local BGM_BASELINE_ID = "BGM-71E ASM"
local BGM_GUIDANCE_CHOICES = { "Wire", "Laser" }

local function getGuidanceChoices(gun)
    -- Wire and Laser are exposed for every registered missile-class munition,
    -- including gravity-only BOMB and GBU classes.
    return BGM_GUIDANCE_CHOICES
end

local function resolveGuidanceSelection(gun, requested)
    requested = string.Trim(tostring(requested or ""))
    if requested == "" then return "Wire" end

    -- Keep ACF's configurable NAME:COMMAND=VALUE syntax, but expose only the
    -- two guidance packages requested for this common flight profile.
    local name = string.match(requested, "^([^:]+)")
    if not name or (name ~= "Wire" and name ~= "Laser") then
        return nil, "Guidance '" .. requested .. "' is not supported. Allowed: Wire, Laser"
    end

    return requested
end

local function defaultFuse(gun)
    local fuses = istable(gun) and gun.fuses or nil
    if not istable(fuses) or #fuses == 0 then return "Contact" end

    for _, name in ipairs(fuses) do
        if name == "Contact" then return name end
    end

    return fuses[1]
end

local function makeBulletData(id, position, direction, owner, requestedGuidance, requestedFillerMass)
    local selectedGun = getGun(id)
    if not selectedGun then
        return nil, "Unknown ACF missile definition: " .. tostring(id)
    end

    local baselineGun = getGun(BGM_BASELINE_ID)
    if not baselineGun or not istable(baselineGun.round) then
        return nil, "BGM-71E baseline definition is unavailable"
    end

    if not isfunction(ACFM_CompactBulletData) then
        return nil, "ACF-Missiles ACFM_CompactBulletData is unavailable (check addon load order)"
    end

    local guidance, guidanceError = resolveGuidanceSelection(selectedGun, requestedGuidance)
    if not guidance then return nil, guidanceError end

    -- Keep the selected weapon's projectile dimensions and explosive type.
    -- The selected gun ID is retained for all munitions during SetBulletData;
    -- powered missiles are switched to the BGM stat identity after creation,
    -- while nothrust BOMB/GBU classes keep their gravity-only identity.
    local round = selectedGun.round or {}
    local maxLength = tonumber(round.maxlength) or tonumber(selectedGun.length) or 1
    local propLength = tonumber(round.proplength or round.propLength) or maxLength * 0.25
    local projectileLength = tonumber(round.projlength or round.projLength) or math.max(maxLength - propLength, 0.01)
    local roundType = round.type or round.Type or "HE"

    if not (ACF and ACF.RoundTypes and ACF.RoundTypes[roundType]) then
        roundType = "HE"
    end
    if not (ACF and ACF.RoundTypes and ACF.RoundTypes[roundType]) then
        return nil, "No valid ACF round type for selected definition: " .. tostring(id)
    end

    local fillerMass = math.Clamp(tonumber(requestedFillerMass) or 0, 0, 100000)
    local fillerVolume = tonumber(round.fillervol or round.fillerVolume) or projectileLength * 0.35
    local fuse = defaultFuse(selectedGun)

    local crateData = {
        Id = id,
        Type = roundType,
        PropLength = propLength,
        ProjLength = projectileLength,
        Data6 = 0,
        Data7 = guidance,
        Data8 = fuse,
    }

    if fillerMass > 0 then
        -- ACFM_CompactBulletData converts FillerMass into the correct Data5
        -- volume using the selected ACF round type's native filler density.
        crateData.FillerMass = fillerMass
    else
        crateData.Data5 = math.max(fillerVolume, 0.01)
    end

    local ok, compact = pcall(ACFM_CompactBulletData, crateData)
    if not ok or not istable(compact) then
        return nil, "ACF missile bullet-data compaction failed: " .. tostring(compact)
    end

    compact.Id = id
    compact.Data7 = guidance
    compact.Data8 = fuse
    compact.Pos = position
    compact.Flight = direction:GetNormalized()
    compact.Owner = owner
    compact.IsShortForm = true

    if not compact.Type or compact.PropLength == nil or compact.ProjLength == nil then
        return nil, "ACF missile bullet data is incomplete (Type/PropLength/ProjLength)"
    end
    if fillerMass > 0 and (not isnumber(compact.Data5) or compact.Data5 <= 0) then
        return nil, "ACF could not convert the requested filler mass into a valid round volume"
    end

    return compact
end

local cachedBGMPropMass
local function getBGMPropellantMass()
    if isnumber(cachedBGMPropMass) then return cachedBGMPropMass end
    if not isfunction(ACFM_CompactBulletData) or not isfunction(ACFM_ExpandBulletData) then
        return nil, "ACF-Missiles compact/expand bullet-data functions are unavailable"
    end

    local gun = getGun(BGM_BASELINE_ID)
    if not gun or not istable(gun.round) then return nil, "BGM-71E baseline gun is unavailable" end

    local round = gun.round
    local maxLength = tonumber(round.maxlength) or 30
    local propLength = tonumber(round.proplength or round.propLength) or maxLength * 0.25
    local projectileLength = tonumber(round.projlength or round.projLength) or math.max(maxLength - propLength, 0.01)
    local compactOK, compact = pcall(ACFM_CompactBulletData, {
        Id = BGM_BASELINE_ID,
        Type = "HE",
        PropLength = propLength,
        ProjLength = projectileLength,
        Data5 = 0.01,
        Data6 = 0,
        Data7 = "Wire",
        Data8 = "Contact",
    })
    if not compactOK or not istable(compact) then
        return nil, "Could not create BGM-71E reference bullet data: " .. tostring(compact)
    end

    local expandOK, expanded = pcall(ACFM_ExpandBulletData, compact)
    if not expandOK or not istable(expanded) or not isnumber(expanded.PropMass) then
        return nil, "Could not calculate BGM-71E reference propellant mass: " .. tostring(expanded)
    end

    cachedBGMPropMass = expanded.PropMass
    return cachedBGMPropMass
end

local function clampSpeedMPH(value)
    return math.Clamp(tonumber(value) or 0, 0, MAX_SPEED_MPH)
end

-- GravityScale is a multiplier on normal sv_gravity for powered rounds and
-- on the selected ACF native gravity for gravity-only BOMB/GBU rounds.
-- This intentionally gives powered BGM-baseline missiles gravity even though
-- the stock BGM ConfigureFlight() normally sets Gravity=0.
local function clampGravityScale(value)
    return math.Clamp(tonumber(value) or 1, 0, 10)
end

local function getWorldGravity()
    local gravity = GetConVar("sv_gravity")
    return gravity and gravity:GetFloat() or 600
end

local function clampSmokeScale(value)
    return math.Clamp(tonumber(value) or 1, MIN_SMOKE_SCALE, MAX_SMOKE_SCALE)
end

local function clampSmokeColor(value)
    if not isvector(value) then return Vector(255, 255, 255) end
    return Vector(
        math.Clamp(value.x, 0, 255),
        math.Clamp(value.y, 0, 255),
        math.Clamp(value.z, 0, 255)
    )
end

local function clampSmokeLength(value)
    return math.Clamp(tonumber(value) or 1, 0.1, 5)
end

local function clampSmokeDensity(value)
    return math.Clamp(tonumber(value) or 1, 0.1, 5)
end

local function clampSmokeOpacity(value)
    return math.Clamp(tonumber(value) or 145, 0, 255)
end

local function clampFlameScale(value)
    return math.Clamp(tonumber(value) or 1, 0, 5)
end

local function applySmokeSettings(missile)
    if not validMissile(missile) then return end

    local scale = clampSmokeScale(missile.ACFM_CleanSmokeScale)
    local color = clampSmokeColor(missile.ACFM_CleanSmokeColor or Vector(255, 255, 255))
    local length = clampSmokeLength(missile.ACFM_CleanSmokeLength)
    local density = clampSmokeDensity(missile.ACFM_CleanSmokeDensity)
    local opacity = clampSmokeOpacity(missile.ACFM_CleanSmokeOpacity)
    local flame = clampFlameScale(missile.ACFM_CleanFlameScale)

    missile.ACFM_CleanSmokeScale = scale
    missile.ACFM_CleanSmokeColor = color
    missile.ACFM_CleanSmokeLength = length
    missile.ACFM_CleanSmokeDensity = density
    missile.ACFM_CleanSmokeOpacity = opacity
    missile.ACFM_CleanFlameScale = flame

    if missile.SetNWFloat then
        missile:SetNWFloat("ACFM_CleanSmokeScale", scale)
        missile:SetNWFloat("ACFM_CleanSmokeLength", length)
        missile:SetNWFloat("ACFM_CleanSmokeDensity", density)
        missile:SetNWFloat("ACFM_CleanSmokeOpacity", opacity)
        missile:SetNWFloat("ACFM_CleanFlameScale", flame)
    end
    if missile.SetNWVector then missile:SetNWVector("ACFM_CleanSmokeColor", color) end
    if missile.ACFM_CleanLaunched and missile.SetNWBool then
        missile:SetNWBool("ACFM_CleanCustomSmoke", not missile.ACFM_CleanGravityOnly and (scale > 0 or flame > 0))
    end
end

-- HomingTurnScale is now a steering-response time constant in seconds.
-- 0 leaves ACF steering untouched; larger values make the target bearing
-- rotate more gradually without imposing a turn-angle or turn-radius limit.
local function clampHomingTurnScale(value)
    return math.Clamp(tonumber(value) or 0.65, 0, 2)
end

local function applyGravityScale(missile)
    if not validMissile(missile) then return end

    local base = missile.ACFM_CleanBaseGravity
    if not isnumber(base) then
        if missile.ACFM_CleanGravityOnly then
            base = tonumber(missile.Gravity) or getWorldGravity()
        else
            base = getWorldGravity()
        end
        missile.ACFM_CleanBaseGravity = base
    end

    missile.Gravity = base * clampGravityScale(missile.ACFM_CleanGravityScale)
end

local function applyHomingTurnScale(missile)
    if not validMissile(missile) then return end

    -- Do not alter ACF's Agility. This value smooths the desired bearing
    -- before ACF's native flight solver applies its normal fin/turn physics.
    missile.ACFM_CleanHomingTurnScale = clampHomingTurnScale(missile.ACFM_CleanHomingTurnScale)
end

local function getCurrentFlightDirection(missile)
    local direction = missile.CurDir
    if not isvector(direction) or direction:LengthSqr() < 0.0001 then
        direction = missile:GetForward()
    end

    if not isvector(direction) or direction:LengthSqr() < 0.0001 then
        return Vector(1, 0, 0)
    end

    return direction:GetNormalized()
end

-- Rotate the current bearing directly in vector space along the shortest
-- spherical arc. This avoids an Euler Angle conversion during large turns.
-- Near an exact 180-degree reversal, the cross product becomes numerically
-- unstable; choose a deterministic perpendicular axis instead of normalizing
-- a tiny/noisy vector. The native ACF flight solver still applies its own
-- turn-rate, fin and seeker behavior after this bearing is returned.
local function smoothFlightDirection(current, target, deltaTime, timeConstant)
    current = current:GetNormalized()
    target = target:GetNormalized()

    local dot = math.Clamp(current:Dot(target), -1, 1)
    local angle = math.acos(dot)
    if angle < 0.0000174533 then return target end -- 0.001 degrees

    local alpha = 1 - math.exp(-deltaTime / timeConstant)
    local turnAngle = angle * math.Clamp(alpha, 0, 1)
    if turnAngle < 0.00000174533 then return current end -- 0.0001 degrees

    local axis = current:Cross(target)
    if axis:LengthSqr() < 0.000001 then
        if dot > 0 then return target end

        -- Exactly (or almost) opposite directions have no unique turn plane.
        -- Choose a stable perpendicular axis; do not derive it from floating
        -- point noise in the near-zero cross product.
        local reference = math.abs(current.z) < 0.9 and Vector(0, 0, 1) or Vector(0, 1, 0)
        axis = current:Cross(reference)
    end

    if axis:LengthSqr() < 0.000001 then return target end
    axis:Normalize()

    -- Rodrigues' rotation formula: rotate the unit vector around the unit
    -- axis without converting through pitch/yaw/roll.
    local cosine = math.cos(turnAngle)
    local sine = math.sin(turnAngle)
    local result = current * cosine
        + axis:Cross(current) * sine
        + axis * (axis:Dot(current) * (1 - cosine))

    if result:LengthSqr() < 0.000001 then return target end
    return result:GetNormalized()
end

-- The rack assigns a separate target to each station. A single E2 chip
-- Output.Position cannot represent several simultaneous targets, so keep the
-- selected target on each missile and feed its current world-space mass center
-- through that missile's native ACF Wire/Laser guidance object. The guidance
-- object and BulletData.Data7 selection remain ACF-native; this only supplies
-- the station-specific target point, as the v21 working bridge did.
local function getGuidanceTargetPosition(target)
    if not IsValid(target) then return nil end

    local phys = target:GetPhysicsObject()
    if IsValid(phys) then
        return target:LocalToWorld(phys:GetMassCenter())
    end

    return target:WorldSpaceCenter()
end

local function installStationTargetGuidance(missile)
    if not validMissile(missile) then return false end

    local guidance = missile.Guidance
    if not istable(guidance) or not isfunction(guidance.GetGuidance) then return false end
    if missile.ACFM_CleanTargetWrappedGuidance == guidance then return true end

    local originalGetGuidance = guidance.GetGuidance
    guidance.GetGuidance = function(self, ent, ...)
        local nativeResult = originalGetGuidance(self, ent, ...)
        if ent ~= missile or (self.Name ~= "Wire" and self.Name ~= "Laser") then
            return nativeResult
        end

        local target = ent.ACFM_CleanGuidanceTarget
        local targetPosition = getGuidanceTargetPosition(target)

        -- No explicit per-missile override? Preserve the complete native ACF
        -- Wire/Laser result, including the live E2 Position output and native
        -- seeker metadata. Never replace a valid native result with an empty one.
        if not targetPosition then return nativeResult end

        -- Preserve ACF Wire's native physical wire-length limit.
        if self.Name == "Wire" then
            local launcher = self.InputSource
            if IsValid(launcher) then
                local wireLength = tonumber(self.WireLength) or 800000
                local missileDistance = ent:GetPos():DistToSqr(launcher:GetPos())
                if missileDistance > wireLength * wireLength
                    or missileDistance > targetPosition:DistToSqr(launcher:GetPos()) then
                    self.WireSnapped = true
                    return {}
                end
            end
            self.WireSnapped = false
        end

        -- Preserve ACF Laser's native forward cone and brush-only LOS behavior,
        -- but evaluate them against this station's own target rather than the
        -- chip's one shared Position output.
        local result = { TargetPos = targetPosition }
        if self.Name == "Laser" then
            local viewCone = tonumber(self.ViewCone) or 150
            if viewCone <= 0 then viewCone = 150 end
            local offset = targetPosition - ent:GetPos()
            if offset:LengthSqr() < 0.0001 then return {} end
            local dot = ent:GetForward():Dot(offset:GetNormalized())
            if dot < math.cos(math.rad(viewCone)) then return {} end

            local trace = util.TraceLine({
                start = ent:GetPos(),
                endpos = targetPosition,
                mask = MASK_SOLID_BRUSHONLY,
                filter = { ent }
            })
            local hitDistance = trace.StartPos:Distance(trace.HitPos)
            if trace.Hit and hitDistance < 80 then return {} end

            result.ViewCone = viewCone
            result.ViewConeRad = math.rad(viewCone)
        end

        return result
    end

    missile.ACFM_CleanOriginalTargetGetGuidance = originalGetGuidance
    missile.ACFM_CleanTargetWrappedGuidance = guidance
    return true
end

-- Wrap only the selected native Wire/Laser guidance instance. ACF still reads
-- its native flight fields; the per-station target wrapper supplies the correct
-- target point before this wrapper smooths the requested bearing.
local function installGuidanceSmoothing(missile)
    if not validMissile(missile) then return false end

    local guidance = missile.Guidance
    if not istable(guidance) or not isfunction(guidance.GetGuidance) then return false end
    if missile.ACFM_CleanWrappedSmoothingGuidance == guidance then return true end

    local originalGetGuidance = guidance.GetGuidance
    guidance.GetGuidance = function(self, ent, ...)
        local result = originalGetGuidance(self, ent, ...)
        if not validMissile(ent) or not ent.ACFM_CleanLaunched then return result end

        local mode = self.Name
        if mode ~= "Wire" and mode ~= "Laser" then return result end

        local now = CurTime()
        local function resetSmoothingToCurrent()
            ent.ACFM_CleanSmoothDirection = getCurrentFlightDirection(ent)
            ent.ACFM_CleanLastGuidanceTime = now
        end

        -- The launch-clearance hold must not consume smoothing time or advance
        -- the hidden desired direction while ACF is deliberately flying straight.
        if ent.ACFM_CleanGuidanceHold then
            ent.ACFM_CleanLastGuidanceTime = now
            return result
        end

        local targetPosition = istable(result) and result.TargetPos or nil
        if not isvector(targetPosition) then
            resetSmoothingToCurrent()
            return result
        end

        local missilePosition = ent:GetPos()
        local offset = targetPosition - missilePosition
        local distance = offset:Length()
        if distance < 0.01 then
            resetSmoothingToCurrent()
            return result
        end

        if mode == "Laser" then
            local trace = util.TraceLine({
                start = missilePosition,
                endpos = targetPosition,
                mask = MASK_SOLID_BRUSHONLY,
                filter = { ent }
            })

            -- Laser points commonly lie on the ground/brush surface. Allow a
            -- small endpoint tolerance for the surface itself; any earlier
            -- wall/brush blocks the lock and causes unguided flight.
            if trace.Hit and trace.HitPos:DistToSqr(targetPosition) > (8 * 8) then
                resetSmoothingToCurrent()
                return {}
            end
        end

        local timeConstant = clampHomingTurnScale(ent.ACFM_CleanHomingTurnScale)
        local targetDirection = offset / distance
        if timeConstant <= 0 then
            -- Native mode: track the actual missile heading so re-enabling
            -- smoothing later starts from where the missile really points.
            ent.ACFM_CleanSmoothDirection = getCurrentFlightDirection(ent)
            ent.ACFM_CleanLastGuidanceTime = now
            return result
        end

        local previousTime = ent.ACFM_CleanLastGuidanceTime or now
        local deltaTime = now - previousTime
        if deltaTime <= 0 then deltaTime = tonumber(ent.ThinkDelay) or (1 / 66) end
        deltaTime = math.Clamp(deltaTime, 0, 0.1)

        local currentDirection = ent.ACFM_CleanSmoothDirection or getCurrentFlightDirection(ent)
        if not isvector(currentDirection) or currentDirection:LengthSqr() < 0.0001 then
            currentDirection = getCurrentFlightDirection(ent)
        else
            currentDirection = currentDirection:GetNormalized()
        end

        local smoothedDirection = smoothFlightDirection(currentDirection, targetDirection, deltaTime, timeConstant)
        ent.ACFM_CleanSmoothDirection = smoothedDirection
        ent.ACFM_CleanLastGuidanceTime = now

        -- Never mutate the native guidance result table. Preserve its ViewCone
        -- and any other metadata while changing only the target bearing.
        local smoothedResult = {}
        for key, value in pairs(result) do
            smoothedResult[key] = value
        end
        smoothedResult.TargetPos = missilePosition + smoothedDirection * distance
        return smoothedResult
    end

    missile.ACFM_CleanOriginalSmoothingGetGuidance = originalGetGuidance
    missile.ACFM_CleanWrappedSmoothingGuidance = guidance
    return true
end

-- ConfigureFlight() runs again inside native ACF Launch(). Wrap it before
-- launch so gravity and turn tuning are active for ACF's synchronous first Think.
local function installFlightTuning(missile)
    if not validMissile(missile) then return end

    if not missile.ACFM_CleanOriginalConfigureFlight and isfunction(missile.ConfigureFlight) then
        missile.ACFM_CleanOriginalConfigureFlight = missile.ConfigureFlight
        missile.ConfigureFlight = function(ent, ...)
            local result = ent.ACFM_CleanOriginalConfigureFlight(ent, ...)

            -- Capture fresh native values each time ACF configures the selected round.
            if ent.ACFM_CleanGravityOnly then
                ent.ACFM_CleanBaseGravity = tonumber(ent.Gravity) or getWorldGravity()
            else
                -- Powered BGM baseline normally reports Gravity=0. Use the
                -- server's normal gravity as its tunable baseline instead.
                ent.ACFM_CleanBaseGravity = getWorldGravity()
            end
            applyGravityScale(ent)
            applyHomingTurnScale(ent)

            return result
        end
    end

    -- Also apply to the current pre-launch configuration for status/debugging;
    -- Launch() will call the wrapped ConfigureFlight() again before flight.
    applyGravityScale(missile)
    applyHomingTurnScale(missile)
end

local function clampVisualScale(value)
    if not isvector(value) then
        local uniform = math.Clamp(tonumber(value) or 1, MIN_VISUAL_SCALE, MAX_VISUAL_SCALE)
        return Vector(uniform, uniform, uniform)
    end

    return Vector(
        math.Clamp(value.x, MIN_VISUAL_SCALE, MAX_VISUAL_SCALE),
        math.Clamp(value.y, MIN_VISUAL_SCALE, MAX_VISUAL_SCALE),
        math.Clamp(value.z, MIN_VISUAL_SCALE, MAX_VISUAL_SCALE)
    )
end

local function applyVisualScale(missile)
    if not validMissile(missile) then return end

    local scale = clampVisualScale(missile.ACFM_CleanModelScale or Vector(1, 1, 1))
    missile.ACFM_CleanModelScale = scale

    -- Client render matrix mirrors the exact XYZ scale used by the server mesh.
    if missile.SetNWVector then missile:SetNWVector("ACFM_CleanModelScale", scale) end
    if missile.SetNWBool then
        local active = math.abs(scale.x - 1) > 0.0001
            or math.abs(scale.y - 1) > 0.0001
            or math.abs(scale.z - 1) > 0.0001
        missile:SetNWBool("ACFM_CleanModelScaleActive", active)
    end
end

-- Rebuild the missile's existing physics shape once, after ACF has finished
-- creating/configuring its entity and before the bridge parents it to a rack.
-- ACF health/armor and BulletData are intentionally not recalculated here.
local function applyPhysicsScaleOnce(missile, scale)
    if not validMissile(missile) then return false, "invalid missile" end
    if missile.ACFM_CleanPhysicsScaleApplied then return true, "already applied" end

    scale = clampVisualScale(scale)
    if math.abs(scale.x - 1) < 0.0001 and math.abs(scale.y - 1) < 0.0001 and math.abs(scale.z - 1) < 0.0001 then
        missile.ACFM_CleanPhysicsScaleApplied = true
        missile.ACFM_CleanPhysicsScale = Vector(1, 1, 1)
        return true, "normal scale"
    end

    local oldPhys = missile:GetPhysicsObject()
    if not IsValid(oldPhys) then return false, "missile has no valid physics object" end

    local ok, sourceConvexes = pcall(oldPhys.GetMeshConvexes, oldPhys)
    if not ok or not istable(sourceConvexes) or #sourceConvexes == 0 then
        return false, "physics mesh convexes unavailable (sphere/unsupported collision mesh)"
    end

    local convexes = {}
    for convexIndex, sourceConvex in ipairs(sourceConvexes) do
        if not istable(sourceConvex) then return false, "invalid convex mesh " .. convexIndex end
        local scaledConvex = {}
        for _, vertex in ipairs(sourceConvex) do
            local position = isvector(vertex) and vertex or (istable(vertex) and vertex.pos or nil)
            if not isvector(position) then
                return false, "physics mesh contains a vertex without a valid position"
            end
            scaledConvex[#scaledConvex + 1] = Vector(position.x * scale.x, position.y * scale.y, position.z * scale.z)
        end
        if #scaledConvex < 4 then return false, "convex mesh has fewer than four vertices" end
        convexes[#convexes + 1] = scaledConvex
    end

    -- Snapshot all relevant physics state before PhysicsInitMultiConvex removes
    -- the original PhysObj. ACF flight drag fields and warhead data are untouched.
    local saved = {
        mass = oldPhys:GetMass(),
        gravity = oldPhys:IsGravityEnabled(),
        drag = oldPhys:IsDragEnabled(),
        motion = oldPhys:IsMotionEnabled(),
        collisions = oldPhys:IsCollisionEnabled(),
        asleep = oldPhys:IsAsleep(),
        material = oldPhys:GetMaterial(),
        massCenter = oldPhys:GetMassCenter(),
        velocity = oldPhys:GetVelocity(),
        angleVelocity = oldPhys:GetAngleVelocity(),
        buoyancy = nil,
    }
    -- Buoyancy access is not available on every supported GMod branch.
    if isfunction(oldPhys.GetBuoyancyRatio) then
        local buoyancyOK, buoyancy = pcall(oldPhys.GetBuoyancyRatio, oldPhys)
        if buoyancyOK then saved.buoyancy = buoyancy end
    end
    local mins, maxs = missile:GetCollisionBounds()
    local scaledMassCenter = Vector(saved.massCenter.x * scale.x, saved.massCenter.y * scale.y, saved.massCenter.z * scale.z)

    local rebuilt, rebuildResult = pcall(missile.PhysicsInitMultiConvex, missile, convexes, saved.material, scaledMassCenter)
    if not rebuilt or rebuildResult ~= true then
        return false, "PhysicsInitMultiConvex failed: " .. tostring(rebuildResult)
    end

    missile:SetSolid(SOLID_VPHYSICS)
    missile:SetMoveType(MOVETYPE_VPHYSICS)
    missile:EnableCustomCollisions(true)
    missile:SetCollisionBounds(
        Vector(mins.x * scale.x, mins.y * scale.y, mins.z * scale.z),
        Vector(maxs.x * scale.x, maxs.y * scale.y, maxs.z * scale.z)
    )

    local newPhys = missile:GetPhysicsObject()
    if not IsValid(newPhys) then return false, "rebuilt physics object is invalid" end

    if isnumber(saved.mass) and saved.mass > 0 then newPhys:SetMass(saved.mass) end
    if isstring(saved.material) and saved.material ~= "" then newPhys:SetMaterial(saved.material) end
    if isnumber(saved.buoyancy) and isfunction(newPhys.SetBuoyancyRatio) then
        pcall(newPhys.SetBuoyancyRatio, newPhys, saved.buoyancy)
    end
    newPhys:EnableGravity(saved.gravity)
    newPhys:EnableDrag(saved.drag)
    -- Leave the default enabled state alone; only restore an explicitly
    -- disabled collision state (EnableCollisions has known engine caveats).
    if not saved.collisions then newPhys:EnableCollisions(false) end
    newPhys:EnableMotion(saved.motion)
    newPhys:SetVelocityInstantaneous(saved.velocity)
    newPhys:SetAngleVelocityInstantaneous(saved.angleVelocity)

    if saved.asleep or not saved.motion then
        newPhys:Sleep()
    else
        newPhys:Wake()
    end

    missile.ACFM_CleanPhysicsScaleApplied = true
    missile.ACFM_CleanPhysicsScale = Vector(scale.x, scale.y, scale.z)
    return true, "physical XYZ scale applied"
end

-- ACF's guidance solver scales turn authority by (speed / MinimumSpeed)^3,
-- capped at 1. A user speed cap below the weapon's native MinimumSpeed therefore
-- silently weakens steering. Keep the requested cap when safe, but never clamp
-- below the gun definition's minimum full-fin-effectiveness speed.
local function effectiveSpeedCapMPH(missile)
    -- A velocity clamp would destroy the ballistic trajectory of gravity-only
    -- bombs/GBUs. Their native gravity and drag remain completely untouched.
    if missile.ACFM_CleanGravityOnly then return 0 end

    local requested = clampSpeedMPH(missile.ACFM_CleanMaxSpeedMPH)
    if requested <= 0 then return 0 end

    local minimumSpeed = tonumber(missile.MinimumSpeed) or 0 -- Source units/second
    local minimumMPH = minimumSpeed / 17.6
    return math.max(requested, minimumMPH)
end

local function installMaxSpeedCap(missile)
    if not validMissile(missile) or missile.ACFM_CleanOriginalCalcFlight or not isfunction(missile.CalcFlight) then return end

    missile.ACFM_CleanOriginalCalcFlight = missile.CalcFlight
    missile.CalcFlight = function(ent, ...)
        local result = ent.ACFM_CleanOriginalCalcFlight(ent, ...)

        -- ACF stops its native exhaust when Motor reaches zero. Mirror that
        -- state for the client-side controlled copy so it is never restarted.
        if ent.ACFM_CleanExhaustActive and (tonumber(ent.Motor) or 0) <= 0 then
            ent.ACFM_CleanExhaustActive = false
            if ent.SetNWBool then ent:SetNWBool("ACFM_CleanExhaustActive", false) end
        end

        local capMPH = effectiveSpeedCapMPH(ent)

        -- ACF stores velocity as displacement per Think tick in LastVel.
        -- 1 MPH = 17.6 Source units/second; multiply by ThinkDelay once.
        if capMPH > 0 and ent.LastVel and ent.ThinkDelay and ent.ThinkDelay > 0
            and not ent.MissileDetonated then
            local capPerTick = math.min(capMPH, MAX_SPEED_MPH) * 17.6 * ent.ThinkDelay
            local current = ent.LastVel:Length()
            if current > capPerTick and current > 0 then
                ent.LastVel = ent.LastVel * (capPerTick / current)
            end
        end

        return result
    end
end

local function applyMaxSpeedCap(missile)
    if not validMissile(missile) then return end
    installMaxSpeedCap(missile)

    local capMPH = effectiveSpeedCapMPH(missile)
    if capMPH > 0 and missile.LastVel and missile.ThinkDelay and missile.ThinkDelay > 0 then
        local capPerTick = math.min(capMPH, MAX_SPEED_MPH) * 17.6 * missile.ThinkDelay
        local current = missile.LastVel:Length()
        if current > capPerTick and current > 0 then
            missile.LastVel = missile.LastVel * (capPerTick / current)
        end
    end
end

local function track(chip, missile)
    local owned = chipMissiles[chip]
    if not owned then
        owned = {}
        chipMissiles[chip] = owned
    end

    owned[missile] = true
    missile.ACFM_CleanChip = chip

    missile:CallOnRemove("ACFM_CleanSlate_Untrack", function(ent)
        local ownerChip = ent.ACFM_CleanChip
        local ownerSet = ownerChip and chipMissiles[ownerChip]
        if ownerSet then
            ownerSet[ent] = nil
            if not next(ownerSet) then chipMissiles[ownerChip] = nil end
        end

        local rack = ent.ACFM_CleanRack
        local rackSet = IsValid(rack) and rackMissiles[rack]
        if rackSet then
            rackSet[ent] = nil
            if not next(rackSet) then rackMissiles[rack] = nil end
        end

        ent.ACFM_CleanChip = nil
        ent.ACFM_CleanRack = nil
    end)
end

local function spawnMissile(chip, player, id, pos, ang, requestedGuidance, requestedFillerMass)
    if not IsValid(chip) then return NULL, "Invalid E2 chip entity" end
    if not isvector(pos) or not isangle(ang) then return NULL, "Invalid missile position or angle" end
    if not util.IsInWorld(pos) then return NULL, "Rack position is outside the map bounds" end

    local owner = IsValid(player) and player or game.GetWorld()
    local bulletData, dataError = makeBulletData(id, pos, ang:Forward(), owner, requestedGuidance, requestedFillerMass)
    if not bulletData then return NULL, dataError end

    local missile = ents.Create(MISSILE_CLASS)
    if not IsValid(missile) then return NULL, "ACF missile entity could not be created" end

    missile.Owner = owner
    missile.DoNotDuplicate = true

    -- CRITICAL: ACF native Wire/Laser guidance reads the launcher's Wire Outputs.
    -- Keep the E2 chip as Launcher for the entire loaded and flight lifecycle.
    -- The rack hologram is only the physical parent; it is NOT the ACF launcher.
    missile.Launcher = chip

    local setOK, setError = pcall(missile.SetBulletData, missile, bulletData)
    if not setOK then
        if IsValid(missile) then missile:Remove() end
        return NULL, "ACF SetBulletData failed: " .. tostring(setError)
    end

    -- ACF's BOMB and GBU gun classes are explicitly marked nothrust. Keep
    -- their selected BulletData.Id so native ConfigureFlight() preserves
    -- Gravity = sv_gravity and Motor = 0. They retain their own fin/drag stats,
    -- model, dimensions and mass, while native Wire/Laser guidance remains on.
    -- Powered missile classes instead use the BGM-71E baseline for flight.
    local selectedGun = getGun(id)
    local gravityOnly = isGravityOnlyDefinition(selectedGun)
    missile.ACFM_CleanGravityOnly = gravityOnly
    missile.ACFM_CleanSelectedGunID = id

    if not gravityOnly then
        local bgmPropMass, propMassError = getBGMPropellantMass()
        if not isnumber(bgmPropMass) then
            missile:Remove()
            return NULL, propMassError or "BGM-71E propellant reference is unavailable"
        end

        missile.BulletData.Id = BGM_BASELINE_ID
        missile.BulletData.PropMass = bgmPropMass
        missile.RoundWeight = 5
    end

    if not missile.Guidance then
        missile:Remove()
        return NULL, "ACF did not create native guidance '" .. tostring(bulletData.Data7) .. "' from BulletData.Data7"
    end

    local guidanceName = string.match(tostring(bulletData.Data7), "^([^:]+)")
    if (guidanceName == "Wire" or guidanceName == "Laser") and missile.Guidance.InputSource ~= chip then
        missile:Remove()
        return NULL, "Native " .. guidanceName .. " guidance could not bind to this E2 chip. The chip must declare @outputs Target:entity (or Position:vector)."
    end

    missile:SetPos(pos)
    missile:SetAngles(ang)

    local spawnOK, spawnError = pcall(function()
        missile:Spawn()
        if not IsValid(missile) then
            error("ACF removed the missile during Spawn (no physics object)")
        end
        missile:Activate()
    end)

    if not spawnOK or not IsValid(missile) then
        if IsValid(missile) then missile:Remove() end
        return NULL, "Native ACF missile initialization failed: " .. tostring(spawnError or "entity removed during spawn")
    end

    missile:SetPos(pos)
    missile:SetAngles(ang)

    -- The entity's base Initialize creates its physics object after SetBulletData.
    -- Re-apply the BGM gun mass now that the physics object exists.
    missile.RoundWeight = 5
    local baselinePhys = missile:GetPhysicsObject()
    if IsValid(baselinePhys) then
        baselinePhys:SetMass(5)
        if isfunction(missile.ACF_Activate) then missile:ACF_Activate(true) end
    end

    missile.ACFM_CleanLaunched = false
    missile.ACFM_CleanExhaustActive = false
    missile:SetNWBool("ACFM_CleanExhaustActive", false)
    missile.ACFM_CleanChip = chip
    missile.ACFM_CleanRack = nil
    missile.ACFM_CleanGravityScale = 1
    missile.ACFM_CleanHomingTurnScale = 0.65
    missile.ACFM_CleanSmokeScale = 1
    missile.ACFM_CleanSmokeColor = Vector(255, 255, 255)
    missile.ACFM_CleanSmokeLength = 1
    missile.ACFM_CleanSmokeDensity = 1
    missile.ACFM_CleanSmokeOpacity = 145
    missile.ACFM_CleanFlameScale = 1
    applySmokeSettings(missile)
    missile.ACFM_CleanFriendlyProtection = true
    installFriendlyDamageProtection(missile)
    missile:SetCollisionGroup(5)

    -- Install both wrappers before Launch(): ACF Launch() immediately calls
    -- Think(), so the first homing calculation must use the selected settings.
    installFlightTuning(missile)
    installMaxSpeedCap(missile)

    local phys = missile:GetPhysicsObject()
    if IsValid(phys) then phys:EnableMotion(false) end

    track(chip, missile)
    return missile
end

local function setNativeGuidance(missile, requested)
    if not validMissile(missile) or missile.ACFM_CleanLaunched then
        return false, "Missile is invalid or has already launched"
    end

    local gun = missile.BulletData and getGun(missile.BulletData.Id)
    local selection, selectionError = resolveGuidanceSelection(gun, requested)
    if not selection then return false, selectionError end

    local configured, guidance = pcall(ACFM_CreateConfigurable, selection, ACF.Guidance, missile.BulletData, "guidance")
    if not configured or not guidance then
        return false, "ACF rejected guidance configuration '" .. selection .. "' for " .. tostring(missile.BulletData.Id)
    end

    missile.BulletData.Data7 = selection
    missile:SetGuidance(guidance)
    return true, selection
end

-- Temporarily suppress only the TargetPos returned to ACF's flight solver.
-- The missile's own native guidance object still runs GetGuidance() every tick,
-- so seeker acquisition, Wire input reads, countermeasures and native state
-- continue normally during the E2-controlled launch-clearance window.
local function installGuidanceHoldHook(missile)
    if not validMissile(missile) then return false end

    local guidance = missile.Guidance
    if not istable(guidance) or not isfunction(guidance.GetGuidance) then
        return false
    end

    if missile.ACFM_CleanWrappedGuidance ~= guidance then
        local originalGetGuidance = guidance.GetGuidance
        guidance.GetGuidance = function(self, ent, ...)
            local result = originalGetGuidance(self, ent, ...)

            if validMissile(ent) and ent.ACFM_CleanGuidanceHold then
                if not istable(result) then return {} end

                -- Return a shallow copy so we never mutate ACF's own result
                -- table. Only the steering target is withheld; all other
                -- native guidance metadata is preserved.
                local heldResult = {}
                for key, value in pairs(result) do
                    heldResult[key] = value
                end
                heldResult.TargetPos = nil
                return heldResult
            end

            return result
        end
        missile.ACFM_CleanWrappedGuidance = guidance
    end

    return true
end

local function setGuidanceHold(missile, enabled)
    if not validMissile(missile) or not missile.ACFM_CleanLaunched then return false end

    if enabled and not installGuidanceHoldHook(missile) then return false end
    missile.ACFM_CleanGuidanceHold = enabled and true or false
    return true
end

local function launchMissile(missile, direction, holdGuidance)
    if not validMissile(missile) or missile.ACFM_CleanLaunched then return 0 end
    if not isvector(direction) or direction:LengthSqr() < 0.0001 then return 0 end

    local rack = missile:GetParent()
    local launcher = missile.Launcher
    if not IsValid(launcher) then
        report(missile.ACFM_CleanChip, "LAUNCH FAILED: original E2 launcher is invalid")
        return 0
    end

    local worldPos, worldAng = missile:GetPos(), missile:GetAngles()
    local launchDirection = direction:GetNormalized()
    local nativeLauncher = missile.ACFM_CleanChip
    if not IsValid(nativeLauncher) then
        report(nativeLauncher, "LAUNCH FAILED: native ACF guidance launcher (E2 chip) is invalid")
        return 0
    end

    -- Seed the smoothed bearing from the actual launch direction. Install the
    -- wrapper before ACF Launch(), whose synchronous first Think() can already
    -- request guidance. Native Laser cone/LOS checks run before smoothing.
    missile.ACFM_CleanSmoothDirection = launchDirection
    missile.ACFM_CleanLastGuidanceTime = CurTime()
    if not installStationTargetGuidance(missile) then
        report(missile.ACFM_CleanChip, "LAUNCH FAILED: native per-station Wire/Laser target wrapper could not be installed")
        return 0
    end
    if not installGuidanceSmoothing(missile) then
        report(missile.ACFM_CleanChip, "LAUNCH FAILED: native Wire/Laser steering wrapper could not be installed")
        return 0
    end

    -- ACF Launch() calls Think() synchronously. Install and enable the hold
    -- BEFORE calling it, otherwise its first CalcFlight() could steer at once.
    if holdGuidance then
        if not installGuidanceHoldHook(missile) then
            report(missile.ACFM_CleanChip, "LAUNCH FAILED: native guidance hold could not be installed")
            return 0
        end
        missile.ACFM_CleanGuidanceHold = true
    else
        missile.ACFM_CleanGuidanceHold = false
    end

    missile:SetParent(nil)
    missile:SetPos(worldPos)
    missile:SetAngles(launchDirection:Angle())

    -- ACF Wire/Laser guidance reads missile.Launcher.Outputs inside its native
    -- Configure() call. Reassert the original E2 chip immediately before
    -- Launch(), after rack unparenting, so no parent/rack entity can become
    -- the native guidance input source. ACF Launch() calls Guidance:Configure.
    missile.Launcher = nativeLauncher
    missile.BulletData.Pos = worldPos
    missile.BulletData.Flight = launchDirection

    -- Do not replace missile.Launcher with the rack hologram here. ACF's own
    -- Launch() reconfigures the native guidance from Launcher.Outputs.
    missile.ACFM_CleanLaunched = true

    local rackSet = IsValid(rack) and rackMissiles[rack]
    if rackSet then
        rackSet[missile] = nil
        if not next(rackSet) then rackMissiles[rack] = nil end
    end
    missile.ACFM_CleanRack = nil

    local phys = missile:GetPhysicsObject()
    if IsValid(phys) then phys:EnableMotion(false) end

    local launchOK, launchError = pcall(missile.Launch, missile)
    if not launchOK then
        missile.ACFM_CleanLaunched = false
        missile.ACFM_CleanGuidanceHold = false

        if IsValid(rack) then
            local localPos = rack:WorldToLocal(worldPos)
            local localAng = rack:WorldToLocalAngles(worldAng)
            missile:SetParent(rack)
            missile:SetParentPhysNum(0)
            missile:SetLocalPos(localPos)
            missile:SetLocalAngles(localAng)
            missile.ACFM_CleanRack = rack

            local set = rackMissiles[rack] or {}
            rackMissiles[rack] = set
            set[missile] = true
        end

        report(missile.ACFM_CleanChip, "Native ACF Launch failed: " .. tostring(launchError))
        return 0
    end

    -- Confirm ACF's own launch-time Configure() rebound the selected native
    -- guidance instance to the chip's live Wire outputs. Do not replace the
    -- guidance object or bypass its native Wire/Laser implementation.
    local guidance = missile.Guidance
    if guidance and (guidance.Name == "Wire" or guidance.Name == "Laser") then
        if guidance.InputSource ~= nativeLauncher then
            guidance:Configure(missile)
        end
        if guidance.InputSource ~= nativeLauncher then
            report(nativeLauncher, "WARNING: native " .. guidance.Name .. " guidance did not bind to the E2 chip after ACF Launch")
        end
    end

    -- Re-assert optional user settings after ACF's native Launch() has
    -- configured its flight fields. The one-time physical mesh scale is not
    -- rebuilt at launch; visual scale remains synchronized through its NW vars.
    installFlightTuning(missile)
    applyGravityScale(missile)
    applyHomingTurnScale(missile)
    applyMaxSpeedCap(missile)
    applyVisualScale(missile)
    applySmokeSettings(missile)
    if missile.SetNWBool then
        missile:SetNWBool("ACFM_CleanCustomSmoke", not missile.ACFM_CleanGravityOnly and (missile.ACFM_CleanSmokeScale > 0 or missile.ACFM_CleanFlameScale > 0))

        -- The bridge manages only powered ACF-Missiles rounds. Gravity-only
        -- bombs/GBUs keep their native no-exhaust behavior.
        local exhaustActive = not missile.ACFM_CleanGravityOnly and (tonumber(missile.Motor) or 0) > 0
        missile.ACFM_CleanExhaustActive = exhaustActive
        missile:SetNWBool("ACFM_CleanExhaustActive", exhaustActive)
    end

    report(missile.ACFM_CleanChip, "Native ACF launch successful | Guidance: " .. tostring(missile.Guidance and missile.Guidance.Name or "unknown"))
    return 1
end

hook.Add("EntityRemoved", "ACFM_CleanSlate_RackCleanup", function(ent)
    local loaded = rackMissiles[ent]
    if not loaded then return end

    rackMissiles[ent] = nil
    for missile in pairs(loaded) do
        if validMissile(missile) and not missile.ACFM_CleanLaunched then
            missile:Remove()
        end
    end
end)

hook.Add("EntityRemoved", "ACFM_CleanSlate_ChipCleanup", function(ent)
    local owned = chipMissiles[ent]
    if not owned then return end

    chipMissiles[ent] = nil
    for missile in pairs(owned) do
        if validMissile(missile) and not missile.ACFM_CleanLaunched then
            missile:Remove()
        end
    end
end)

e2function void acfCleanMissileTarget(entity missile, entity target)
    if not validMissile(missile) then return end

    local owned = chipMissiles[self.entity]
    if not owned or not owned[missile] then return end

    local newTarget = IsValid(target) and target or nil
    if missile.ACFM_CleanGuidanceTarget ~= newTarget then
        missile.ACFM_CleanGuidanceTarget = newTarget
        missile.ACFM_CleanSmoothDirection = nil
        missile.ACFM_CleanLastGuidanceTime = nil
    end
end

local function createMissileForE2(self, index, pos, ang, requestedGuidance, requestedFillerMass)
    local id, resolvedIndex, total = getMissileID(index)
    if not id then
        report(self.entity, "Invalid MissileIndex " .. tostring(resolvedIndex) .. " (valid range: 1-" .. tostring(total) .. ")")
        return NULL
    end

    local missile, err = spawnMissile(self.entity, self.player, id, pos, ang, requestedGuidance, requestedFillerMass)
    if not IsValid(missile) then
        report(self.entity, err)
        return NULL
    end

    report(self.entity, "Created BGM-flight munition " .. id .. " | Model: " .. tostring(missile:GetModel()) .. " | Guidance: " .. tostring(missile.BulletData.Data7) .. " (#" .. missile:EntIndex() .. ")")
    return missile
end

e2function entity acfCleanMissileCreate(number index, vector pos, angle ang)
    return createMissileForE2(self, index, pos, ang, "")
end

e2function entity acfCleanMissileCreateGuided(number index, vector pos, angle ang, string guidance)
    return createMissileForE2(self, index, pos, ang, guidance, 0)
end

e2function entity acfCleanMissileCreateGuidedFiller(number index, vector pos, angle ang, string guidance, number fillerMass)
    return createMissileForE2(self, index, pos, ang, guidance, fillerMass)
end

e2function string acfCleanMissileGuidanceList(number index)
    local id, resolvedIndex, total = getMissileID(index)
    if not id then
        return "Invalid MissileIndex " .. tostring(resolvedIndex) .. " (valid range: 1-" .. tostring(total) .. ")"
    end

    return "Wire | Laser"
end

e2function string acfCleanMissileStatus()
    return IsValid(self.entity) and (self.entity.ACFM_CleanStatus or "Ready") or "Invalid chip"
end

e2function string acfCleanMissileList()
    local ids = getMissileIDs()
    if #ids == 0 then return "NO MISSILE DEFINITIONS FOUND - check ACF-Missiles load order" end

    local numbered = {}
    for index, id in ipairs(ids) do
        numbered[index] = tostring(index) .. ": " .. id
    end

    return table.concat(numbered, " | ")
end

e2function number acfCleanMissileDefault()
    return #getMissileIDs() > 0 and 1 or 0
end

e2function void acfCleanMissileRemove(entity missile)
    if not validMissile(missile) or missile.ACFM_CleanChip ~= self.entity or missile.ACFM_CleanLaunched then return end
    missile:Remove()
end

e2function void acfCleanMissileParent(entity missile, entity rack)
    if not validMissile(missile) or missile.ACFM_CleanLaunched or not IsValid(rack) then return end

    local worldPos, worldAng = missile:GetPos(), missile:GetAngles()
    local localPos = rack:WorldToLocal(worldPos)
    local localAng = rack:WorldToLocalAngles(worldAng)

    missile:SetParent(rack)
    missile:SetParentPhysNum(0)
    missile:SetLocalPos(localPos)
    missile:SetLocalAngles(localAng)

    -- Keep missile.Launcher pointing at the E2 chip. Native Wire and Laser
    -- guidance require the chip's live Outputs table, not this rack hologram.
    missile.ACFM_CleanRack = rack

    local set = rackMissiles[rack] or {}
    rackMissiles[rack] = set
    set[missile] = true

    local phys = missile:GetPhysicsObject()
    if IsValid(phys) then phys:EnableMotion(false) end
end

e2function void acfCleanMissileFriendlyProtection(entity missile, number enabled)
    if not validMissile(missile) or missile.ACFM_CleanChip ~= self.entity then return end

    missile.ACFM_CleanFriendlyProtection = enabled ~= 0
    installFriendlyDamageProtection(missile)
end

e2function void acfCleanMissileGravityScale(entity missile, number scale)
    if not validMissile(missile) or missile.ACFM_CleanChip ~= self.entity then return end

    missile.ACFM_CleanGravityScale = clampGravityScale(scale)
    installFlightTuning(missile)
    applyGravityScale(missile)
end

e2function void acfCleanMissileHomingTurnScale(entity missile, number scale)
    if not validMissile(missile) or missile.ACFM_CleanChip ~= self.entity then return end

    missile.ACFM_CleanHomingTurnScale = clampHomingTurnScale(scale)
    installFlightTuning(missile)
    applyHomingTurnScale(missile)
end

e2function void acfCleanMissileSmokeScale(entity missile, number scale)
    if not validMissile(missile) or missile.ACFM_CleanChip ~= self.entity then return end

    missile.ACFM_CleanSmokeScale = clampSmokeScale(scale)
    applySmokeSettings(missile)
    if missile.ACFM_CleanLaunched and missile.SetNWBool then
        missile:SetNWBool("ACFM_CleanCustomSmoke", not missile.ACFM_CleanGravityOnly and (missile.ACFM_CleanSmokeScale > 0 or missile.ACFM_CleanFlameScale > 0))
    end
end

e2function void acfCleanMissileSmokeColor(entity missile, vector color)
    if not validMissile(missile) or missile.ACFM_CleanChip ~= self.entity then return end

    missile.ACFM_CleanSmokeColor = clampSmokeColor(color)
    applySmokeSettings(missile)
end

e2function void acfCleanMissileSmokeLength(entity missile, number length)
    if not validMissile(missile) or missile.ACFM_CleanChip ~= self.entity then return end
    missile.ACFM_CleanSmokeLength = clampSmokeLength(length)
    applySmokeSettings(missile)
end

e2function void acfCleanMissileSmokeDensity(entity missile, number density)
    if not validMissile(missile) or missile.ACFM_CleanChip ~= self.entity then return end
    missile.ACFM_CleanSmokeDensity = clampSmokeDensity(density)
    applySmokeSettings(missile)
end

e2function void acfCleanMissileSmokeOpacity(entity missile, number opacity)
    if not validMissile(missile) or missile.ACFM_CleanChip ~= self.entity then return end
    missile.ACFM_CleanSmokeOpacity = clampSmokeOpacity(opacity)
    applySmokeSettings(missile)
end

e2function void acfCleanMissileFlameScale(entity missile, number scale)
    if not validMissile(missile) or missile.ACFM_CleanChip ~= self.entity then return end
    missile.ACFM_CleanFlameScale = clampFlameScale(scale)
    applySmokeSettings(missile)
end

e2function void acfCleanMissileMaxSpeedMPH(entity missile, number speed)
    if not validMissile(missile) or missile.ACFM_CleanChip ~= self.entity then return end

    missile.ACFM_CleanMaxSpeedMPH = clampSpeedMPH(speed)
    applyMaxSpeedCap(missile)
end

e2function void acfCleanMissileModelScale(entity missile, vector scale)
    if not validMissile(missile) or missile.ACFM_CleanChip ~= self.entity then return end

    missile.ACFM_CleanModelScale = clampVisualScale(scale)
    local physicsOK, physicsMessage = applyPhysicsScaleOnce(missile, missile.ACFM_CleanModelScale)
    applyVisualScale(missile)
    if not physicsOK then
        report(self.entity, "WARNING: visual XYZ scale set, physical mesh scale failed: " .. tostring(physicsMessage))
    else
        report(self.entity, "Missile XYZ visual + physical scale set: " .. tostring(missile.ACFM_CleanModelScale))
    end
end

e2function void acfCleanMissileModelScaleUniform(entity missile, number scale)
    if not validMissile(missile) or missile.ACFM_CleanChip ~= self.entity then return end

    missile.ACFM_CleanModelScale = clampVisualScale(scale)
    local physicsOK, physicsMessage = applyPhysicsScaleOnce(missile, missile.ACFM_CleanModelScale)
    applyVisualScale(missile)
    if not physicsOK then
        report(self.entity, "WARNING: visual uniform scale set, physical mesh scale failed: " .. tostring(physicsMessage))
    else
        report(self.entity, "Missile uniform visual + physical scale set: " .. tostring(missile.ACFM_CleanModelScale))
    end
end

e2function number acfCleanMissileLaunch(entity missile, vector direction)
    return launchMissile(missile, direction, false)
end

e2function number acfCleanMissileLaunchHeld(entity missile, vector direction, number hold)
    if not validMissile(missile) or missile.ACFM_CleanChip ~= self.entity then return 0 end
    return launchMissile(missile, direction, hold ~= 0)
end

e2function number acfCleanMissileGuidanceHold(entity missile, number hold)
    if not validMissile(missile) or missile.ACFM_CleanChip ~= self.entity then return 0 end

    local success = setGuidanceHold(missile, hold ~= 0)
    if not success then
        report(self.entity, "Guidance hold failed: native ACF guidance object is unavailable")
        return 0
    end

    if hold ~= 0 then
        report(self.entity, "Native ACF guidance held for launch clearance")
    else
        report(self.entity, "Native ACF guidance released")
    end

    return 1
end

e2function number acfCleanMissileLaunched(entity missile)
    return validMissile(missile) and missile.ACFM_CleanLaunched and not missile.MissileDetonated and 1 or 0
end

e2function void acfCleanMissileFuse(entity missile, string fuseName)
    if not validMissile(missile) or missile.ACFM_CleanLaunched then return end

    fuseName = string.Trim(tostring(fuseName or ""))
    if fuseName == "" then return end

    local configured, fuse = pcall(ACFM_CreateConfigurable, fuseName, ACF.Fuse, missile.BulletData, "fuses")
    if not configured or not fuse then
        report(self.entity, "ACF rejected fuse '" .. fuseName .. "' for " .. tostring(missile.BulletData.Id))
        return
    end

    missile:SetFuse(fuse)
    report(self.entity, "Native ACF fuse set: " .. fuseName)
end

-- Backward-compatible numeric selector. This changes only the native ACF
-- guidance instance and BulletData.Data7; it never wraps its steering methods.
e2function void acfCleanMissileGuidance(entity missile, number laser, number radar, number infrared, number antimissile, number wire, number dumb)
    if not validMissile(missile) or missile.ACFM_CleanLaunched then return end

    local requested, count = nil, 0
    local flags = {
        { laser, "Laser" },
        { radar, "Radar" },
        { infrared, "Infrared" },
        { antimissile, "Antimissile" },
        { wire, "Wire" },
        { dumb, "Dumb" },
    }

    for _, entry in ipairs(flags) do
        if entry[1] ~= 0 then
            count = count + 1
            requested = entry[2]
        end
    end

    if count ~= 1 then requested = "" end

    local ok, result = setNativeGuidance(missile, requested)
    if not ok then report(self.entity, result) end
end
