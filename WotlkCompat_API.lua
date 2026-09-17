--[[----------------------------------------------------------------------------
    TurboPlates - stock 3.3.5a pure-API shims
    (Backported by Jedborg)

    Plain API gap-fillers that TurboPlates needs and that don't exist on a stock
    3.3.5a client: RunNextFrame, C_Timer, CreateColor/ColorMixin,
    WrapTextInColorCode, PixelUtil, Texture:SetColorTexture, C_CVar,
    EventRegistry, GetCreatureIDFromGUID.

    LOAD ORDER: this file must load FIRST of the three WotlkCompat files,
    because WotlkCompat.lua (the nameplate engine) uses EventRegistry and
    C_Timer, and TurboPlates captures these as file-scope locals. Each symbol is
    only defined if missing, so this is a no-op on a patched client / Ascension.
------------------------------------------------------------------------------]]

local addonName, ns = ...

---------------------------------------------------------------------------
-- RunNextFrame(callback)
---------------------------------------------------------------------------
if type(RunNextFrame) ~= "function" then
    local queue, count = {}, 0
    local driver = CreateFrame("Frame")
    driver:Hide()
    driver:SetScript("OnUpdate", function(self)
        local toRun, n = queue, count
        queue, count = {}, 0
        self:Hide()
        for i = 1, n do
            local cb = toRun[i]
            if cb then
                local ok, err = pcall(cb)
                if not ok and geterrorhandler then geterrorhandler()(err) end
            end
        end
    end)
    function RunNextFrame(callback)
        if type(callback) ~= "function" then return end
        count = count + 1
        queue[count] = callback
        driver:Show()
    end
    _G.RunNextFrame = RunNextFrame
end

---------------------------------------------------------------------------
-- C_Timer (After / NewTimer / NewTicker)
---------------------------------------------------------------------------
if type(C_Timer) ~= "table" or type(C_Timer.After) ~= "function" then
    local timers = {}
    local GetTime = GetTime
    local ticker = CreateFrame("Frame")
    ticker:SetScript("OnUpdate", function()
        if not timers[1] then return end
        local now = GetTime()
        local i = 1
        while timers[i] do
            local t = timers[i]
            if t.cancelled then
                table.remove(timers, i)
            elseif now >= t.expire then
                table.remove(timers, i)
                local ok, err = pcall(t.cb)
                if not ok and geterrorhandler then geterrorhandler()(err) end
            else
                i = i + 1
            end
        end
    end)
    C_Timer = C_Timer or {}
    function C_Timer.After(delay, cb)
        if type(cb) ~= "function" then return end
        timers[#timers + 1] = { expire = GetTime() + (delay or 0), cb = cb }
    end
    function C_Timer.NewTimer(delay, cb)
        local handle = { expire = GetTime() + (delay or 0), cb = cb }
        function handle:Cancel() self.cancelled = true end
        timers[#timers + 1] = handle
        return handle
    end
    function C_Timer.NewTicker(interval, cb, iterations)
        local handle = { cancelled = false }
        local count = 0
        local function step()
            if handle.cancelled then return end
            count = count + 1
            local ok, err = pcall(cb, handle)
            if not ok and geterrorhandler then geterrorhandler()(err) end
            if iterations and count >= iterations then return end
            C_Timer.After(interval, step)
        end
        function handle:Cancel() self.cancelled = true end
        C_Timer.After(interval, step)
        return handle
    end
    _G.C_Timer = C_Timer
end

---------------------------------------------------------------------------
-- CreateFramePool / CreateTexturePool / CreateObjectPool
-- The bundled LibCustomGlow-1.0 calls these at FILE-LOAD scope (it builds its
-- GlowTexPool/GlowFramePool/ButtonGlowPool up front). They are retail globals
-- that don't exist on stock 3.3.5a; ClassicAPI used to supply them. Without it
-- the lib errored at load and registered only a half-built table, which is why
-- PixelGlow_* came back nil. Provide minimal pools so the lib loads and the
-- glow actually works standalone. Must run before LibCustomGlow in the .toc
-- (WotlkCompat_API loads first), which it does.
---------------------------------------------------------------------------
if type(CreateFramePool) ~= "function" then
    local function Pool_Acquire(self)
        local obj = next(self.inactiveObjects)
        local isNew = false
        if obj then
            self.inactiveObjects[obj] = nil
        else
            obj = self.createFunc(self)
            isNew = true
        end
        if not obj then return nil, isNew end
        self.activeObjects[obj] = true
        return obj, isNew
    end
    local function Pool_Release(self, obj)
        if not obj or not self.activeObjects[obj] then return end
        self.activeObjects[obj] = nil
        self.inactiveObjects[obj] = true
        if self.resetterFunc then self.resetterFunc(self, obj) else obj:Hide() end
    end
    local function Pool_ReleaseAll(self)
        while true do
            local obj = next(self.activeObjects)
            if not obj then break end
            self:Release(obj)
        end
    end
    local function NewPool(createFunc, resetterFunc)
        return {
            activeObjects   = {},
            inactiveObjects = {},
            createFunc      = createFunc,
            resetterFunc    = resetterFunc,
            Acquire         = Pool_Acquire,
            Release         = Pool_Release,
            ReleaseAll      = Pool_ReleaseAll,
        }
    end

    function CreateFramePool(frameType, parent, template, resetterFunc)
        return NewPool(function()
            return CreateFrame(frameType or "Frame", nil, parent, template)
        end, resetterFunc)
    end
    function CreateTexturePool(parent, layer, subLayer, resetterFunc, textureName)
        return NewPool(function()
            return parent:CreateTexture(nil, layer, textureName, subLayer)
        end, resetterFunc)
    end
    function CreateObjectPool(createFunc, resetterFunc)
        return NewPool(createFunc, resetterFunc)
    end
    _G.CreateFramePool   = CreateFramePool
    _G.CreateTexturePool = CreateTexturePool
    _G.CreateObjectPool  = CreateObjectPool
end

---------------------------------------------------------------------------
-- CombatLogGetCurrentEventInfo
-- HealerDetection.lua calls this (retail CLEU accessor). On stock 3.3.5a the
-- CLEU args arrive as the event payload instead, so the global is absent and
-- the call threw. HealerDetection passes the handler's varargs straight in, so
-- a pass-through is the right shim here.
---------------------------------------------------------------------------
if type(CombatLogGetCurrentEventInfo) ~= "function" then
    function CombatLogGetCurrentEventInfo(...)
        return ...
    end
    _G.CombatLogGetCurrentEventInfo = CombatLogGetCurrentEventInfo
end

---------------------------------------------------------------------------
-- CreateColor / ColorMixin / WrapTextInColorCode
---------------------------------------------------------------------------
if type(CreateColor) ~= "function" then
    local function hex(self)
        return string.format("ff%02x%02x%02x",
            math.floor((self.r or 0)*255+0.5),
            math.floor((self.g or 0)*255+0.5),
            math.floor((self.b or 0)*255+0.5))
    end
    local M = {}
    function M:GetRGB() return self.r, self.g, self.b end
    function M:GetRGBA() return self.r, self.g, self.b, self.a or 1 end
    function M:GetRGBAAsBytes()
        return math.floor((self.r or 0)*255+0.5), math.floor((self.g or 0)*255+0.5),
               math.floor((self.b or 0)*255+0.5), math.floor((self.a or 1)*255+0.5)
    end
    function M:SetRGBA(r,g,b,a) self.r,self.g,self.b,self.a = r,g,b,a end
    function M:SetRGB(r,g,b) self.r,self.g,self.b,self.a = r,g,b,1 end
    function M:GenerateHexColor() return hex(self) end
    function M:GenerateHexColorMarkup() return "|c"..hex(self) end
    function M:WrapTextInColorCode(text) return "|c"..hex(self)..(text or "").."|r" end
    function M:IsEqualTo(o)
        return o and self.r==o.r and self.g==o.g and self.b==o.b and self.a==o.a
    end
    function CreateColor(r,g,b,a)
        local c = { r=r, g=g, b=b, a=a or 1 }
        for k,v in pairs(M) do c[k]=v end
        return c
    end
    _G.CreateColor = CreateColor
    _G.ColorMixin = M
end

if type(WrapTextInColorCode) ~= "function" then
    function WrapTextInColorCode(text, hexString)
        return "|c"..(hexString or "ffffffff")..(text or "").."|r"
    end
    _G.WrapTextInColorCode = WrapTextInColorCode
end

---------------------------------------------------------------------------
-- PixelUtil (forward to ordinary frame methods; ignore snap hints)
---------------------------------------------------------------------------
if type(PixelUtil) ~= "table" then
    PixelUtil = {}
    function PixelUtil.SetPoint(region, point, relativeTo, relativePoint, x, y)
        region:SetPoint(point, relativeTo, relativePoint, x or 0, y or 0)
    end
    function PixelUtil.SetSize(region, w, h) region:SetSize(w, h) end
    function PixelUtil.SetWidth(region, w) region:SetWidth(w) end
    function PixelUtil.SetHeight(region, h) region:SetHeight(h) end
    function PixelUtil.GetNearestPixelSize(size) return size end
    function PixelUtil.GetPixelToUIUnitFactor() return 1 end
    _G.PixelUtil = PixelUtil
end

-- Ensure Frame:SetSize exists (some cores lack it)
do
    local probe = CreateFrame("Frame")
    if type(probe.SetSize) ~= "function" then
        -- rawset, not `meta.SetSize = fn`: on this client the Frame-type __index
        -- table carries a __newindex guard, so a plain assignment for a NEW key is
        -- silently swallowed -> SetSize would stay nil and crash every :SetSize
        -- call site. rawset bypasses the guard. (The probe check above already
        -- proves SetSize isn't native, so we're not shadowing anything.)
        local meta = getmetatable(probe).__index
        rawset(meta, "SetSize", function(self, w, h)
            if w then self:SetWidth(w) end
            if h then self:SetHeight(h) end
        end)
    end
end

-- Texture:SetColorTexture -> SetTexture(r,g,b,a)
do
    local probeTex = UIParent:CreateTexture()
    if type(probeTex.SetColorTexture) ~= "function" then
        local texMeta = getmetatable(probeTex).__index
        rawset(texMeta, "SetColorTexture", function(self, r, g, b, a)
            self:SetTexture(r, g, b, a or 1)
        end)
    end
end

---------------------------------------------------------------------------
--
---------------------------------------------------------------------------
do
    local probeTex = UIParent:CreateTexture()
    local rawSetAtlas = probeTex.SetAtlas
    local SKULL = "Interface\\TargetingFrame\\UI-TargetingFrame-Skull"
    local ATLAS_FALLBACK = {
        ["questlog-icon-checkmark-yellow-2x"] = "Interface\\Buttons\\UI-CheckBox-Check",
        ["questnormal"]           = "Interface\\GossipFrame\\AvailableQuestIcon",
        ["dungeonskull"]          = SKULL,
        ["warfront-alliancehero"] = SKULL,
        ["warfront-hordehero"]    = SKULL,
        ["islands-azeriteboss"]   = SKULL,
    }

    function ns.SafeSetAtlas(texture, atlas, ...)
        if not texture then return false end
        local fallback = atlas and ATLAS_FALLBACK[atlas]
        if fallback then
            texture:SetTexture(fallback)
            return true
        end
        if type(rawSetAtlas) == "function" then
            local ok = pcall(rawSetAtlas, texture, atlas, ...)
            if ok then return true end
        end
        texture:SetTexture(nil)
        return false
    end
end

---------------------------------------------------------------------------
-- C_CVar (Set / Get / GetBool / GetNumber)
-- Define each method only if it's missing. Gating the whole block on
-- "C_CVar exists" broke on awesome_wotlk (and any core/addon that ships a
-- PARTIAL or retail-style C_CVar, e.g. only GetCVar/SetCVar): the table was
-- present so our shim was skipped entirely, leaving Get/GetNumber/GetBool/Set
-- nil -> "attempt to call field 'GetNumber' (a nil value)" crashed
-- ResolveNameplateAlpha on every camera move. Same partial-native-API trap as
-- C_NamePlate. Each method is self-contained (uses the captured global CVar
-- API directly, not a sibling C_CVar method that might be foreign/native).
---------------------------------------------------------------------------
do
    local _GetCVar, _SetCVar, _GetCVarBool = GetCVar, SetCVar, GetCVarBool
    if type(C_CVar) ~= "table" then C_CVar = {} end
    local function readCVar(name)
        local ok, v = pcall(_GetCVar, name)
        return ok and v or nil
    end
    if type(C_CVar.Set) ~= "function" then
        function C_CVar.Set(name, value)
            if type(value) == "boolean" then value = value and "1" or "0" end
            pcall(_SetCVar, name, value)   -- unknown CVars error; guard
        end
    end
    if type(C_CVar.Get) ~= "function" then
        function C_CVar.Get(name)
            return readCVar(name)
        end
    end
    if type(C_CVar.GetBool) ~= "function" then
        function C_CVar.GetBool(name)
            if _GetCVarBool then
                local ok, v = pcall(_GetCVarBool, name)
                if ok then return v and true or false end
            end
            local v = readCVar(name)
            return v == "1" or v == "true"
        end
    end
    if type(C_CVar.GetNumber) ~= "function" then
        function C_CVar.GetNumber(name)
            local v = readCVar(name)
            return v and tonumber(v) or nil
        end
    end
    _G.C_CVar = C_CVar
end

---------------------------------------------------------------------------
-- EventRegistry (callback bus). The nameplate engine fires
-- "NamePlateManager.UnitAdded"/"...UnitRemoved" through this.
---------------------------------------------------------------------------
if type(EventRegistry) ~= "table" then
    local callbacks = {}
    EventRegistry = {}
    function EventRegistry:RegisterCallback(event, fn, owner)
        callbacks[event] = callbacks[event] or {}
        table.insert(callbacks[event], { fn = fn, owner = owner })
    end
    function EventRegistry:UnregisterCallback(event, owner)
        local list = callbacks[event]
        if not list then return end
        for i = #list, 1, -1 do
            if list[i].owner == owner then table.remove(list, i) end
        end
    end
    function EventRegistry:TriggerEvent(event, ...)
        local list = callbacks[event]
        if not list then return end
        for i = 1, #list do
            local e = list[i]
            local ok, err = pcall(e.fn, e.owner, ...)
            if not ok and geterrorhandler then geterrorhandler()(err) end
        end
    end
    _G.EventRegistry = EventRegistry
end

---------------------------------------------------------------------------
-- Register the retail-only CVars TurboPlates reads/writes directly through the
-- native GetCVar/SetCVar (only nameplateShowPersonal is missing on stock;
-- colorblindMode, nameplateShowFriends, nameplateShowEnemies already exist).
--
-- IMPORTANT: we register the CVar instead of wrapping global GetCVar/SetCVar.
-- Replacing those globals with our own Lua closures taints every secure UI path
-- that reads a CVar - most visibly, pressing Escape to open the game menu then
-- trips "A macro script has been blocked from an action only available to the
-- Blizzard UI." RegisterCVar keeps the native (secure) functions in place.
---------------------------------------------------------------------------
if type(RegisterCVar) == "function" then
    pcall(RegisterCVar, "nameplateShowPersonal", "0")
end

---------------------------------------------------------------------------
-- Region:GetEffectiveScale: on this client only Frames have it, not plain
-- Regions (FontString/Texture). ClassicAPI's PixelUtil calls it on whatever
-- region it's given, so add a fallback that climbs to the nearest frame.
---------------------------------------------------------------------------
do
    local function addFallback(probe)
        if type(probe.GetEffectiveScale) == "function" then return end
        local meta = getmetatable(probe).__index
        rawset(meta, "GetEffectiveScale", function(self)
            local parent = self:GetParent()
            if parent and parent.GetEffectiveScale then
                return parent:GetEffectiveScale()
            end
            return 1
        end)
    end
    addFallback(UIParent:CreateTexture())
    addFallback(UIParent:CreateFontString())
end

---------------------------------------------------------------------------
-- C_Hook.RegisterBucket(frame, event, interval, callback): batches an event
-- over `interval` seconds and invokes callback(events), where events is a
-- list of {arg1, arg2, ...} tables captured per firing. Not a real Blizzard
-- API; TurboPlates expects it from a patched (Ascension-style) client.
---------------------------------------------------------------------------
if type(C_Hook) ~= "table" or type(C_Hook.RegisterBucket) ~= "function" then
    C_Hook = C_Hook or {}
    -- NOTE: callers use a colon (C_Hook:RegisterBucket(frame, ...)), so this
    -- must be a method - the implicit self is C_Hook, frame is the 1st real arg.
    function C_Hook:RegisterBucket(frame, event, interval, callback)
        local pending = {}
        local elapsed = 0
        frame:RegisterEvent(event)
        frame:HookScript("OnEvent", function(self, ev, ...)
            if ev == event then
                pending[#pending + 1] = { ... }
            end
        end)
        frame:HookScript("OnUpdate", function(self, delta)
            elapsed = elapsed + delta
            if elapsed >= interval and #pending > 0 then
                elapsed = 0
                local fired = pending
                pending = {}
                local ok, err = pcall(callback, fired)
                if not ok and geterrorhandler then geterrorhandler()(err) end
            end
        end)
    end
    _G.C_Hook = C_Hook
end

---------------------------------------------------------------------------
-- GetCreatureIDFromGUID (WotLK GUID -> npc id)
---------------------------------------------------------------------------
if type(GetCreatureIDFromGUID) ~= "function" then
    function GetCreatureIDFromGUID(guid)
        if type(guid) ~= "string" then return nil end
        local hex = guid:gsub("^0[xX]", "")
        if #hex < 12 then return nil end
        local id = tonumber(hex:sub(5, 10), 16)
        if id and id > 0 then return id end
        return nil
    end
    _G.GetCreatureIDFromGUID = GetCreatureIDFromGUID
end

---------------------------------------------------------------------------
--
---------------------------------------------------------------------------
function ns.SafeSetSpellTooltip(tooltip, spellId)
    if not tooltip or not spellId then return false end
    spellId = tonumber(spellId)
    if not spellId or not GetSpellInfo(spellId) then return false end

    if type(tooltip.SetSpellByID) == "function" then
        local ok = pcall(tooltip.SetSpellByID, tooltip, spellId)
        if ok then return true end
    end

    if type(tooltip.SetHyperlink) == "function" then
        local ok = pcall(tooltip.SetHyperlink, tooltip, "spell:" .. spellId)
        return ok and true or false
    end
    return false
end
