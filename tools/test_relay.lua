--[[ test_relay.lua - runs two copies of the addon and makes them talk

    lua tools/test_relay.lua          (from the addon root)

The whole risk in this addon is a loop: two characters each forwarding to the
other will bounce one whisper between them until the server disconnects both
for spam. That cannot be tested by calling one client's functions, because the
loop needs two of them -- so each "client" here is the real WhisperRelay.lua
loaded into its own globals, and whatever one of them sends is fed to the
other exactly as the game would.

Everything is driven through the real entry points: the OnEvent script, the
OnUpdate script and the slash handler. Nothing calls an internal helper
directly, because a test that skips the handler cannot catch a handler that
was never wired up.
]]

math.mod = math.mod or math.fmod
math.atan2 = math.atan2 or math.atan
string.gfind = string.gfind or string.gmatch
table.getn = table.getn or function(t) return #t end
unpack = unpack or table.unpack

local clock = { t = 100000, gt = 500 }

--[[ One CustomData directory, shared by every client in a test, because that
     is exactly what makes the two real clients able to see each other: they
     are one installation with one folder. ]]
local files = {}
-- Another PC's CustomData: a window there sees the server, not this folder.
local elsewhere = {}
local function resetFiles()
  for k in pairs(files) do files[k] = nil end
  for k in pairs(elsewhere) do elsewhere[k] = nil end
end
local function diskOf(machine)
  if not machine then return files end
  elsewhere[machine] = elsewhere[machine] or {}
  return elsewhere[machine]
end

--[[ The server, as far as addon messages go: who is logged in, and what the
     Turtle core does with "TW_CHAT_MSG_WHISPER<Name>" on a GUILD message --
     HandleTurtleAddonMessages in Handlers/ChatHandler.cpp, down to its
     tokenizer. A message waits on the wire until the next frame of any
     client, as it would on the network, so nothing is answered inside the
     call that sent it. `turtle = false` is a server without any of this. ]]
local net = { online = {}, wire = {}, refused = {}, turtle = true }
local function resetNet()
  net.online, net.wire, net.refused, net.turtle = {}, {}, {}, true
end

-- Splits at EVERY separator (the C++'s third argument only reserves room),
-- dropping nothing but an empty piece at the very end.
local function tokenize(s, sep)
  local out, start = {}, 1
  while true do
    local i = string.find(s, sep, start, true)
    if not i then
      if start <= string.len(s) then table.insert(out, string.sub(s, start)) end
      return out
    end
    table.insert(out, string.sub(s, start, i - 1))
    start = i + 1
  end
end

local function toClient(name, prefix, text, from)
  local c = net.online[name]
  if type(c) == "table" then c:fire("CHAT_MSG_ADDON", prefix, text, "GUILD", from) end
end

local function serve(m)
  local raw = m.prefix .. "\t" .. m.text
  if not net.turtle or m.chan ~= "GUILD"
     or not string.find(raw, "TW_CHAT_MSG_WHISPER", 1, true) then
    return      -- ordinary guild traffic, and nobody here is in a guild
  end
  local params = tokenize(raw, ">")
  local dest = tokenize(params[1] or "", "<")
  if #params ~= 2 or #dest ~= 2 then
    table.insert(net.refused, raw)
    toClient(m.from, "TW_CHAT_MSG_WHISPER", "SyntaxError:WrongDestination", m.from)
    return
  end
  local to = string.upper(string.sub(dest[2], 1, 1)) .. string.lower(string.sub(dest[2], 2))
  if net.online[to] then
    toClient(to, "TW_CHAT_MSG_WHISPER", params[2], m.from)
  else
    toClient(m.from, "TW_CHAT_MSG_WHISPER", "Error:CantFindPlayer:" .. to, m.from)
  end
end

local function pump()
  for _ = 1, 500 do
    local m = table.remove(net.wire, 1)
    if not m then return end
    serve(m)
  end
  error("addon messages still going round after 500 deliveries")
end

local function tocVersion()
  local fh = io.open("WhisperRelay.toc", "r")
  if not fh then return nil end
  local found
  for line in fh:lines() do
    local v = string.match(line, "^##%s*Version:%s*(%S+)")
    if v then found = v end
  end
  fh:close()
  return found
end

----------------------------------------------------------------------
-- one client
----------------------------------------------------------------------

local function newClient(name, opts)
  local c = { name = name, sent = {}, chat = {}, sounds = 0, clientShown = {},
              byName = {} }
  local env = setmetatable({}, { __index = _G })
  c.env = env

  --[[ Most of this suite was written for whispers between windows, and still
       describes them exactly: they are what a window running an older copy
       gets, and what `/wf quiet off` brings back. So its clients start with
       the quiet channel off, as saved settings would have it. The quiet
       channel has a section of its own at the end, with clients that leave it
       on, as it ships. `opts.db` is the saved variables a /reload keeps, and
       `opts.machine` puts a client on another PC, with a folder of its own. ]]
  opts = opts or {}
  if opts.db then
    env.WhisperRelayDB = opts.db
  elseif not opts.quiet then
    env.WhisperRelayDB = { quiet = false }
  end
  local disk = diskOf(opts.machine)

  env.UnitName = function() return name end
  env.time = function() return clock.t end
  -- Frame time, separate from wall clock: the popup counts down in GetTime.
  env.GetTime = function() return clock.gt end
  env.FlashClientIcon = function() c.flashed = (c.flashed or 0) + 1 end
  env.GetAddOnMetadata = function(addon, field)
    if addon == "WhisperRelay" and field == "Version" then return tocVersion() end
    return nil
  end
  env.PlaySound = function() c.sounds = c.sounds + 1 end
  env.WriteCustomFile = function(name, text, mode)
    if mode == "a" then disk[name] = (disk[name] or "") .. text
    else disk[name] = text end
  end
  env.ReadCustomFile = function(name) return disk[name] end
  env.ERR_CHAT_PLAYER_NOT_FOUND_S = "No player named '%s' is currently playing."
  -- The battleground queue, and this server's dungeon finder.
  c.queues = {}
  env.MAX_BATTLEFIELD_QUEUES = 3
  env.GetBattlefieldStatus = function(i)
    local q = c.queues[i]
    if not q then return "none" end
    return q.status, q.map
  end
  env.LFT_ADDON_PREFIX = "LFT"
  -- Who this character is grouped with. The feature turns on being able to
  -- tell "in this group" from "not in it".
  c.party, c.raid = {}, {}
  --[[ The guild: its name (nil for none), who the roster lists -- empty
       until a test fills it, as the client's is until the server answers --
       and how often the roster was asked for. `opts.guild` is the guild a
       character logs in already belonging to. ]]
  c.guildName, c.roster, c.rosterAsked = opts.guild, {}, 0
  env.IsInGuild = function() return c.guildName ~= nil end
  env.GetNumGuildMembers = function() return table.getn(c.roster) end
  env.GetGuildRosterInfo = function(i) return c.roster[i] end
  env.GuildRoster = function() c.rosterAsked = c.rosterAsked + 1 end
  env.GetNumPartyMembers = function() return table.getn(c.party) end
  env.GetNumRaidMembers = function() return table.getn(c.raid) end
  env.GetRaidRosterInfo = function(i) return c.raid[i] end
  env.UnitName = function(unit)
    if unit == "player" then return name end
    local _, _, idx = string.find(tostring(unit), "^party(%d+)$")
    if idx then return c.party[tonumber(idx)] end
    return nil
  end
  env.SendChatMessage = function(text, chan, _, target)
    if type(text) ~= "string" then error("sent a non-string") end
    if string.len(text) > 255 then
      error("whisper of " .. string.len(text) .. " chars would be dropped by 1.12")
    end
    table.insert(c.sent, { text = text, chan = chan, target = target })
  end
  c.addonSent = {}
  env.SendAddonMessage = function(prefix, text, chan)
    if type(prefix) ~= "string" or type(text) ~= "string" then
      error("SendAddonMessage takes a prefix and a text")
    end
    if string.find(prefix, "\t", 1, true) then error("a tab in an addon prefix") end
    if string.len(prefix) + string.len(text) > 254 then
      error("addon message of " .. (string.len(prefix) + string.len(text)) ..
        " chars is over the client's 254")
    end
    table.insert(c.addonSent, { prefix = prefix, text = text, chan = chan })
    table.insert(net.wire, { from = name, prefix = prefix, text = text, chan = chan })
  end
  net.online[name] = c
  env.DEFAULT_CHAT_FRAME = {
    AddMessage = function(_, m) table.insert(c.chat, m) end,
  }
  env.SlashCmdList = {}
  -- A stand-in for the client's own chat dispatcher, so the hook has
  -- something real to wrap and suppress.
  env.ChatFrame_OnEvent = function(evt)
    if evt == "CHAT_MSG_WHISPER" then
      table.insert(c.clientShown, env.arg1)
    end
  end
  --[[ Enough of the widget API to actually build the popup, and to read back
       what it says. A stub that accepts every call and remembers nothing can
       only prove the code ran without erroring -- which is not the question
       for something whose whole job is to be visible. ]]
  local function region()
    local r = { shown = true, text = "" }
    function r:SetText(t) self.text = tostring(t or "") end
    function r:GetText() return self.text end
    -- The last anchor it was given, so where something was put can be read.
    function r:SetPoint(...) self.point = { ... } end
    function r:ClearAllPoints() self.point = nil end
    function r:SetAllPoints() end
    function r:SetWidth(v) self.w = v end
    function r:SetHeight(v) self.h = v end
    function r:GetWidth() return self.w or 0 end
    function r:GetHeight() return self.h or 0 end
    function r:SetTexture() end
    function r:SetVertexColor() end
    function r:SetFont() end
    function r:SetTextColor() end
    function r:SetJustifyH() end
    function r:Show() self.shown = true end
    -- Hiding something that was showing runs its OnHide, as the client does.
    function r:Hide()
      local was = self.shown
      self.shown = false
      if was and self.scripts and self.scripts.OnHide then
        env.this = self
        self.scripts.OnHide()
        env.this = nil
      end
    end
    function r:IsShown() return self.shown end
    return r
  end

  env.UIParent = region()

  --[[ For the minimap button: the map with its centre at (100, 100), a
       cursor a test can move, a tooltip that keeps its lines, and the
       client's dropdown menu -- which runs the menu's own builder each time
       it opens, as the real one does, and keeps the lines it was given. ]]
  --[[ The game world: what a click on a mob or the ground lands on.
       `opts.worldScript` is an OnMouseDown another addon set before this one
       loaded -- Dewdrop sets one -- which must still run. ]]
  env.WorldFrame = region()
  env.WorldFrame.scripts = { OnMouseDown = opts.worldScript }
  function env.WorldFrame:SetScript(k, fn) self.scripts[k] = fn end
  function env.WorldFrame:GetScript(k) return self.scripts[k] end

  env.Minimap = region()
  function env.Minimap:GetCenter() return 100, 100 end
  function env.Minimap:GetEffectiveScale() return 1 end
  c.cursor = { 0, 0 }
  env.GetCursorPosition = function() return c.cursor[1], c.cursor[2] end
  c.tooltip = {}
  env.GameTooltip = {
    SetOwner = function() c.tooltip = {} end,
    SetText = function(_, t) table.insert(c.tooltip, t) end,
    AddLine = function(_, t) table.insert(c.tooltip, t) end,
    Show = function() end,
    Hide = function() end,
  }
  c.menu, c.menuOpen = {}, false
  env.UIDropDownMenu_AddButton = function(info) table.insert(c.menu, info) end
  env.UIDropDownMenu_Initialize = function(frame, init, mode)
    frame.initialize, frame.displayMode = init, mode
    c.menu = {}
    init()
  end
  env.ToggleDropDownMenu = function(level, _, frame)
    if c.menuOpen then c.menuOpen = false return end
    env.UIDROPDOWNMENU_MENU_LEVEL = level
    c.menu = {}
    frame.initialize()
    c.menuOpen = true
  end
  env.CloseDropDownMenus = function() c.menuOpen = false end
  env.CreateFrame = function(kind, name)
    local f = region()
    f.scripts, f.events, f.name = {}, {}, name
    f.shown = true
    function f:SetScript(k, fn) self.scripts[k] = fn end
    function f:GetScript(k) return self.scripts[k] end
    function f:RegisterEvent(e) self.events[e] = true end
    function f:EnableMouse() end
    function f:SetFrameStrata() end
    function f:CreateTexture() return region() end
    function f:CreateFontString() return region() end
    -- ScrollingMessageFrame: the client keeps the scrollback, so the window
    -- does not reimplement one.
    f.lines = {}
    function f:AddMessage(m) table.insert(self.lines, tostring(m)) end
    function f:Clear() self.lines = {} end
    function f:SetMaxLines() end
    function f:SetFading() end
    function f:ScrollUp() end
    function f:ScrollDown() end
    function f:SetMovable() end
    function f:SetResizable() end
    function f:SetMinResize() end
    function f:SetMaxResize() end
    function f:StartSizing() end
    function f:RegisterForDrag() end
    function f:StartMoving() end
    function f:StopMovingOrSizing() end
    function f:EnableMouseWheel() end
    function f:SetFrameLevel() end
    function f:SetHighlightTexture() end
    function f:RegisterForClicks() end
    -- EditBox. Focus is modelled because the panel deliberately refuses to
    -- overwrite text while it is being typed.
    f.focused = false
    function f:SetAutoFocus() end
    function f:SetMaxLetters(n) self.maxLetters = n end
    --[[ As the client does it: gaining or losing the keyboard runs the box's
         focus scripts, and only when it actually changes hands. No
         HasFocus: not every 1.12 client has one, so nothing may rely on it. ]]
    f.clearCalls = 0
    function f:SetFocus()
      if self.focused then return end
      self.focused = true
      local run = self.scripts.OnEditFocusGained
      if run then env.this = self run() env.this = nil end
    end
    function f:ClearFocus()
      self.clearCalls = self.clearCalls + 1
      if not self.focused then return end
      self.focused = false
      local run = self.scripts.OnEditFocusLost
      if run then env.this = self run() env.this = nil end
    end
    function f:HighlightText() end
    function f:SetTextInsets() end
    function f:EnableKeyboard() end

    -- The first frame is the addon's event frame; the popup comes later and
    -- must not quietly take its place.
    if not c.frame then c.frame = f end
    if name then c.byName[name] = f end
    return f
  end

  local chunk = assert(loadfile("WhisperRelay.lua", "t", env))
  chunk()

  c.WR = env.WhisperRelay

  function c:fire(event, a1, a2, a3, a4)
    if not self.frame.events[event] then
      error(self.name .. " never registered " .. event)
    end
    env.event = event
    env.arg1 = a1
    env.arg2 = a2
    env.arg3 = a3
    env.arg4 = a4
    self.frame.scripts.OnEvent()
  end

  -- A frame: whatever the server has for anyone arrives first.
  function c:tick(step)
    pump()
    env.arg1 = step or 1
    self.frame.scripts.OnUpdate()
  end

  --- Log out for good: says goodbye, then is not there to be found.
  function c:logout()
    self:fire("PLAYER_LOGOUT")
    net.online[self.name] = nil
  end

  -- Drain the outgoing queue the way the game would, a frame at a time.
  function c:drain()
    for _ = 1, 40 do self:tick(1) end
  end

  --[[ Click a widget the way the client does: `this` is the frame being
       clicked, which handlers read to find out which button they are. ]]
  function c:click(frame, button)
    env.this = frame
    env.arg1 = button or "LeftButton"
    if frame.scripts and frame.scripts.OnClick then frame.scripts.OnClick() end
    env.this = nil
  end

  -- Press, one frame of moving, let go: what the client runs for a drag.
  function c:drag(frame)
    env.this = frame
    frame.scripts.OnDragStart()
    env.this, env.arg1 = frame, 0.02
    if frame.scripts.OnUpdate then frame.scripts.OnUpdate() end
    env.this = frame
    frame.scripts.OnDragStop()
    env.this = nil
  end

  --- A click in the game world: on a mob, the ground, anything not a window.
  function c:clickWorld(button)
    env.this, env.arg1 = env.WorldFrame, button or "LeftButton"
    env.WorldFrame.scripts.OnMouseDown()
    env.this = nil
  end

  --- A mouse press on a frame itself, not on anything inside it.
  function c:press(frame)
    env.this, env.arg1 = frame, "LeftButton"
    if frame.scripts.OnMouseDown then frame.scripts.OnMouseDown() end
    env.this = nil
  end

  function c:hover(frame)
    env.this = frame
    frame.scripts.OnEnter()
    env.this = nil
  end

  --[[ A line of the open menu, picked the way the client picks it: its
       function gets the line's arg1, with the line as `this` -- or, as an
       older client does it, nothing at all (`bare`). A line that does not
       keep the menu open closes it. ]]
  function c:pick(text, bare)
    for _, info in ipairs(self.menu) do
      if info.text == text then
        env.this = { value = info.value, checked = info.checked }
        if info.func then
          if bare then info.func() else info.func(info.arg1, info.arg2) end
        end
        env.this = nil
        if not info.keepShownOnClick then self.menuOpen = false end
        return info
      end
    end
    error("no menu line says: " .. text)
  end

  -- Clicking anywhere else, which closes a menu.
  function c:closeMenu() self.menuOpen = false end

  function c:cmd(text)
    env.SlashCmdList["WHISPERRELAY"](text)
  end

  function c:reply(text)
    env.SlashCmdList["WHISPERRELAYREPLY"](text)
  end

  --[[ Named apart from c.party, which is the roster: defining a method of
       the same name silently replaced the list of who is grouped with this
       character, and the failure surfaced three functions away. ]]
  function c:toParty(text)
    env.SlashCmdList["WHISPERRELAYPARTY"](text)
  end

  function c:toGuild(text)
    env.SlashCmdList["WHISPERRELAYGUILD"](text)
  end

  function c:whisper(from, text)
    self:fire("CHAT_MSG_WHISPER", text, from)
  end

  -- The client dispatches a whisper to the chat frames as well as to us.
  function c:deliver(from, text)
    env.this = env.DEFAULT_CHAT_FRAME
    env.arg1, env.arg2 = text, from
    env.ChatFrame_OnEvent("CHAT_MSG_WHISPER")
    self:whisper(from, text)
    self:tick(0)
  end

  c:fire("VARIABLES_LOADED")
  c:fire("PLAYER_ENTERING_WORLD")
  return c
end

----------------------------------------------------------------------

local pass, fail = 0, 0
local function step(label, fn)
  -- Every test starts with an empty shared folder, or one test teaches the
  -- next one that a character it never heard of is logged in. Likewise the
  -- server: nobody logged in, nothing on the wire.
  resetFiles()
  resetNet()
  -- xpcall rather than pcall so a crash reports where it happened instead of
  -- just what it said.
  local ok, err = xpcall(fn, function(e)
    return tostring(e) .. "\n" .. debug.traceback("", 2)
  end)
  if ok then
    pass = pass + 1
    print(string.format("  ok    %s", label))
  else
    fail = fail + 1
    print(string.format("  FAIL  %s\n        %s", label, tostring(err)))
  end
end

--- A client says it is still here, as a running one does every minute.
local function activate_beat(c)
  c.WR.sinceBeat = 999
  c:tick(1)
end

local function toTarget(c, target)
  local out = {}
  for _, m in ipairs(c.sent) do
    if m.target == target then table.insert(out, m) end
  end
  return out
end

print("\nWhisperRelay\n")

step("the version reported is the one in the .toc", function()
  local c = newClient("Salahaja")
  local shipped = tocVersion()
  if not shipped then error("could not read the .toc") end
  if c.WR.version ~= shipped then
    error("reports " .. tostring(c.WR.version) .. ", .toc ships " .. shipped)
  end
end)

step("nothing is forwarded before a target is set", function()
  local c = newClient("Salahaja")
  c:whisper("Bobby", "you there?")
  c:drain()
  if table.getn(c.sent) > 0 then
    error("sent " .. c.sent[1].text .. " with no target configured")
  end
end)

step("a whisper is forwarded, carrying who sent it", function()
  local c = newClient("Salahaja")
  c:cmd("to Salabeard")
  c:whisper("Bobby", "you there?")
  c:drain()

  local fwd = toTarget(c, "Salabeard")
  if table.getn(fwd) ~= 1 then
    error("expected one forward, got " .. table.getn(fwd))
  end
  if not string.find(fwd[1].text, "Bobby", 1, true) then
    error("the forward does not say who it was from: " .. fwd[1].text)
  end
  if not string.find(fwd[1].text, "you there?", 1, true) then
    error("the forward lost the message: " .. fwd[1].text)
  end
  if fwd[1].chan ~= "WHISPER" then
    error("forwarded over " .. tostring(fwd[1].chan) .. ", not WHISPER")
  end
end)

step("the sender is told which character to whisper instead", function()
  local c = newClient("Salahaja")
  c:cmd("to Salabeard")
  c:cmd("reply on")    -- off by default: it is a bot reply in their window
  c:whisper("Bobby", "you there?")
  c:drain()

  local back = toTarget(c, "Bobby")
  if table.getn(back) ~= 1 then
    error("expected one answer to Bobby, got " .. table.getn(back))
  end
  if not string.find(back[1].text, "Salabeard", 1, true) then
    error("the answer does not name the character: " .. back[1].text)
  end
end)

step("one person is not answered twice inside the cooldown", function()
  local c = newClient("Salahaja")
  c:cmd("to Salabeard")
  c:cmd("reply on")
  c:cmd("every 300")
  c:whisper("Bobby", "one")
  c:whisper("Bobby", "two")
  c:whisper("Bobby", "three")
  c:drain()

  local back = toTarget(c, "Bobby")
  if table.getn(back) ~= 1 then
    error("answered Bobby " .. table.getn(back) .. " times")
  end
  -- ...but all three still get forwarded.
  if table.getn(toTarget(c, "Salabeard")) ~= 3 then
    error("forwarded " .. table.getn(toTarget(c, "Salabeard")) .. " of 3")
  end

  -- Past the cooldown, answering again is right.
  clock.t = clock.t + 301
  c:whisper("Bobby", "four")
  c:drain()
  if table.getn(toTarget(c, "Bobby")) ~= 2 then
    error("did not answer again after the cooldown expired")
  end
  clock.t = clock.t - 301
end)

--[[ The one that matters. Two clients pointed at each other, one real whisper
     in: if a forward can be forwarded, this never stops. ]]
step("two clients pointed at each other do not bounce a whisper", function()
  local a = newClient("Salahaja")
  local b = newClient("Salabeard")
  a:cmd("to Salabeard")
  b:cmd("to Salahaja")

  a:whisper("Bobby", "you there?")
  a:drain()

  -- Deliver everything A sent to Salabeard as a real whisper arriving at B.
  local hops = 0
  local pending = toTarget(a, "Salabeard")
  while table.getn(pending) > 0 do
    hops = hops + 1
    if hops > 4 then error("still relaying after " .. hops .. " hops - it loops") end

    for _, m in ipairs(pending) do b:whisper("Salahaja", m.text) end
    a.sent = {}
    b:drain()

    local back = toTarget(b, "Salahaja")
    if table.getn(back) > 0 then
      error("B forwarded the forward straight back: " .. back[1].text)
    end
    pending = {}
  end

  -- And B must not "helpfully" answer Salahaja either.
  if table.getn(toTarget(b, "Salahaja")) > 0 then
    error("B auto-answered the character it forwards to")
  end
end)

step("a whisper from the forward target is left alone", function()
  local c = newClient("Salahaja")
  c:cmd("to Salabeard")
  c:whisper("Salabeard", "grab me a stack of runes")
  c:drain()
  if table.getn(c.sent) > 0 then
    error("relayed a message from the target itself: " .. c.sent[1].text)
  end
end)

step("a long whisper is split, and every part fits", function()
  local c = newClient("Salahaja")
  c:cmd("to Salabeard")
  c:cmd("reply off")

  local long = string.rep("abcdefghij", 40)   -- 400 characters
  c:whisper("Bobby", long)
  c:drain()

  local fwd = toTarget(c, "Salabeard")
  if table.getn(fwd) < 2 then
    error("400 characters went out in " .. table.getn(fwd) .. " part(s)")
  end

  -- The stub already errors over 255; check the content survived too.
  local joined = ""
  for _, m in ipairs(fwd) do
    local body = string.gsub(m.text, "^>>%s*Bobby:%s*%d*%)?%s*", "")
    joined = joined .. body
  end
  joined = string.gsub(joined, " %[cut%]$", "")
  if string.sub(long, 1, string.len(joined)) ~= joined then
    error("the parts do not reassemble into the original message")
  end
end)

step("outgoing whispers are spaced out, not sent in one frame", function()
  local c = newClient("Salahaja")
  c:cmd("to Salabeard")
  c:cmd("reply on")
  c:whisper("Bobby", "one")
  c:whisper("Charlie", "two")

  c:tick(0)
  if table.getn(c.sent) > 1 then
    error("sent " .. table.getn(c.sent) .. " whispers in a single frame")
  end
  c:drain()
  if table.getn(c.sent) < 4 then
    error("only " .. table.getn(c.sent) .. " of 4 queued messages went out")
  end
end)

step("forwarding to yourself is refused", function()
  local c = newClient("Salahaja")
  c:cmd("to Salahaja")
  c:whisper("Bobby", "you there?")
  c:drain()
  if table.getn(c.sent) > 0 then
    error("accepted itself as the target and relayed to itself")
  end
end)

step("a target saved for this character is dropped on login", function()
  local a = newClient("Salahaja")
  a:cmd("to Salabeard")
  local saved = a.env.WhisperRelayDB

  -- Same account, now logged in as the character it used to forward to.
  local b = newClient("Salabeard")
  b.env.WhisperRelayDB = saved
  b.WR.ready = false
  b:fire("PLAYER_LOGIN")
  if b.WR.config.target == "Salabeard" then
    error("Salabeard is set to forward to itself")
  end
end)

step("off means off, and on resumes", function()
  local c = newClient("Salahaja")
  c:cmd("to Salabeard")
  c:cmd("off")
  c:whisper("Bobby", "one")
  c:drain()
  if table.getn(c.sent) > 0 then error("forwarded while off") end

  c:cmd("on")
  c:whisper("Bobby", "two")
  c:drain()
  if table.getn(toTarget(c, "Salabeard")) ~= 1 then
    error("did not resume after /wf on")
  end
end)

step("the custom answer keeps naming the current target", function()
  local c = newClient("Salahaja")
  c:cmd("to Salabeard")
  c:cmd("reply on")   -- setting the wording no longer switches it on
  c:cmd("reply ping {char} instead")
  c:whisper("Bobby", "hi")
  c:drain()
  local back = toTarget(c, "Bobby")
  if table.getn(back) ~= 1 or back[1].text ~= "ping Salabeard instead" then
    error("answered with: " .. (back[1] and back[1].text or "nothing"))
  end

  -- Point somewhere else; the saved text must follow.
  c:cmd("to Mahislap")
  clock.t = clock.t + 1000
  c:whisper("Bobby", "hi again")
  c:drain()
  back = toTarget(c, "Bobby")
  if back[table.getn(back)].text ~= "ping Mahislap instead" then
    error("stale target in the answer: " .. back[table.getn(back)].text)
  end
  clock.t = clock.t - 1000
end)

step("/wf test drives the same path a real whisper does", function()
  local c = newClient("Salahaja")
  c:cmd("to Salabeard")
  c:cmd("test")
  c:drain()
  if table.getn(toTarget(c, "Salabeard")) == 0 then
    error("/wf test sent nothing to the target")
  end
end)

step("every command runs", function()
  local c = newClient("Salahaja")
  for _, cmd in ipairs({ "", "status", "to Salabeard", "on", "off", "on",
                         "reply", "reply", "reply hello {char}", "every 60",
                         "every abc", "echo", "echo", "test", "nonsense",
                         "to", "to Salahaja" }) do
    c:cmd(cmd)
  end
  c:drain()
end)

--[[ The silent failure. A misspelled target eats every whisper, and without
     this the only clue is people saying you ignored them. ]]
step("an offline target is reported, not swallowed", function()
  local c = newClient("Salahaja")
  c:cmd("to Salabeard")
  c:whisper("Bobby", "you there?")
  c:drain()

  c:fire("CHAT_MSG_SYSTEM", "No player named 'Salabeard' is currently playing.")
  local warned = false
  for _, m in ipairs(c.chat) do
    if string.find(m, "not online", 1, true) then warned = true end
  end
  if not warned then error("said nothing about the target being unreachable") end
end)

step("someone else's failed whisper is not blamed on the relay", function()
  local c = newClient("Salahaja")
  c:cmd("to Salabeard")
  c.chat = {}
  c:fire("CHAT_MSG_SYSTEM", "No player named 'Zzzzz' is currently playing.")
  c:fire("CHAT_MSG_SYSTEM", "Welcome to N'Zoth.")
  for _, m in ipairs(c.chat) do
    if string.find(m, "not online", 1, true) then
      error("warned about a name that is not the target")
    end
  end
end)

step("the offline warning does not repeat per queued whisper", function()
  local c = newClient("Salahaja")
  c:cmd("to Salabeard")
  c.chat = {}
  for _ = 1, 5 do
    c:fire("CHAT_MSG_SYSTEM", "No player named 'Salabeard' is currently playing.")
  end
  local n = 0
  for _, m in ipairs(c.chat) do
    if string.find(m, "not online", 1, true) then n = n + 1 end
  end
  if n ~= 1 then error("warned " .. n .. " times for one outage") end
end)

step("the name is still found without the client's format string", function()
  local c = newClient("Salahaja")
  c.env.ERR_CHAT_PLAYER_NOT_FOUND_S = nil
  c:cmd("to Salabeard")
  c.chat = {}
  c:fire("CHAT_MSG_SYSTEM", "No player named 'Salabeard' is currently playing.")
  local warned = false
  for _, m in ipairs(c.chat) do
    if string.find(m, "not online", 1, true) then warned = true end
  end
  if not warned then error("the fallback pattern did not match") end
end)

--[[ Whichever way it is displayed, the point is a clickable name. These look
     for the link itself rather than for one particular line, so the assertion
     survives a change of presentation. ]]
local function linkLines(c)
  local out = {}
  for _, m in ipairs(c.chat) do
    if string.find(m, "|Hplayer:", 1, true) then table.insert(out, m) end
  end
  return out
end

local function handleLines(c)
  local out = {}
  for _, m in ipairs(c.chat) do
    if string.find(m, "reply to", 1, true) then table.insert(out, m) end
  end
  return out
end

--[[ The character you are PLAYING normally has no target of its own, so this
     has to happen before any of the forwarding checks. ]]
step("an arriving forward gets a clickable name with no target configured", function()
  local b = newClient("Salabeard")
  b:deliver("Salahaja", ">> Bobby: you around for Strat tonight?")

  local lines = linkLines(b)
  if table.getn(lines) ~= 1 then
    error("got " .. table.getn(lines) .. " clickable names, expected 1")
  end
  if not string.find(lines[1], "|Hplayer:Bobby|h[Bobby]|h", 1, true) then
    error("not a player link: " .. lines[1])
  end
end)

--[[ The thing actually asked for: the name clickable IN the message, which
     means the client's own copy of that whisper must not also appear. ]]
step("inline mode replaces the client's line instead of adding one", function()
  local b = newClient("Salabeard")
  b:deliver("Salahaja", ">> Bobby: hi there")

  if table.getn(b.clientShown) > 0 then
    error("the client's own unclickable copy was shown as well")
  end
  local lines = linkLines(b)
  if table.getn(lines) ~= 1 then
    error("expected one rewritten line, got " .. table.getn(lines))
  end
  if not string.find(lines[1], "hi there", 1, true) then
    error("the rewritten line lost the message: " .. lines[1])
  end
  if table.getn(handleLines(b)) > 0 then
    error("added a handle line on top of rewriting it")
  end
end)

step("an ordinary whisper is left to the client untouched", function()
  local b = newClient("Salabeard")
  b:deliver("Bobby", "you around?")
  if table.getn(b.clientShown) ~= 1 then
    error("suppressed a whisper that was not a forward")
  end
  if table.getn(linkLines(b)) > 0 then
    error("rewrote a whisper that was not a forward")
  end
end)

--[[ The failure this has to survive: a chat addon that replaces
     ChatFrame_OnEvent after us, so the rewrite never runs. Something
     clickable must still appear. ]]
step("a chat addon taking the hook back still leaves a clickable name", function()
  local b = newClient("Salabeard")
  b.env.ChatFrame_OnEvent = function(evt)
    if evt == "CHAT_MSG_WHISPER" then table.insert(b.clientShown, b.env.arg1) end
  end

  b:deliver("Salahaja", ">> Bobby: hi")
  if table.getn(b.clientShown) ~= 1 then
    error("expected the other addon to show it")
  end
  local lines = linkLines(b)
  if table.getn(lines) ~= 1 then
    error("no clickable name once the hook was taken back")
  end
  if not string.find(lines[1], "|Hplayer:Bobby|h", 1, true) then
    error("wrong link: " .. lines[1])
  end
end)

step("with inline off, the client shows it and a handle is added", function()
  local b = newClient("Salabeard")
  b:cmd("inline")
  b:deliver("Salahaja", ">> Bobby: hi")

  if table.getn(b.clientShown) ~= 1 then
    error("suppressed the whisper with inline off")
  end
  if table.getn(handleLines(b)) ~= 1 then
    error("no handle line with inline off")
  end
end)

step("the clickable name is the original sender, not the forwarder", function()
  local b = newClient("Salabeard")
  b:deliver("Salahaja", ">> Bobby: hi")
  local lines = linkLines(b)
  if string.find(lines[1], "|Hplayer:Salahaja|h", 1, true) then
    error("linked the forwarder instead of Bobby: " .. lines[1])
  end
end)

step("a split forward yields one handle, not three", function()
  local b = newClient("Salabeard")
  b:cmd("inline")
  b:deliver("Salahaja", ">> Bobby: 1) first part of it")
  b:deliver("Salahaja", ">> Bobby: 2) second part of it")
  b:deliver("Salahaja", ">> Bobby: 3) third part of it")
  local n = table.getn(handleLines(b))
  if n ~= 1 then error("offered " .. n .. " handles for one split message") end
end)

step("a later message from the same person gets its own handle", function()
  local b = newClient("Salabeard")
  b:cmd("inline")
  b:deliver("Salahaja", ">> Bobby: first")
  clock.t = clock.t + 60
  b:deliver("Salahaja", ">> Bobby: much later")
  clock.t = clock.t - 60
  local n = table.getn(handleLines(b))
  if n ~= 2 then error("offered " .. n .. " handles for two conversations") end
end)

step("/wf link turns the fallback handle off", function()
  local b = newClient("Salabeard")
  b:cmd("inline")
  b:cmd("link")
  b:deliver("Salahaja", ">> Bobby: hi")
  if table.getn(handleLines(b)) > 0 then error("still offered a handle") end
end)

--[[ The clickable name must not come at the cost of the loop guard: a client
     that both forwards and receives has to show the link and still refuse to
     pass the forward on. ]]
step("a client that also forwards does not relay an arriving forward", function()
  local b = newClient("Salabeard")
  b:cmd("to Salahaja")
  b:deliver("Salahaja", ">> Bobby: hi")
  b:drain()
  if table.getn(b.sent) > 0 then
    error("forwarded an arriving forward: " .. b.sent[1].text)
  end
  if table.getn(linkLines(b)) ~= 1 then
    error("and showed no clickable name either")
  end
end)

step("a forwarded message containing a colon still parses", function()
  local b = newClient("Salabeard")
  b:deliver("Salahaja", ">> Bobby: look at this: 5:1 odds")
  local lines = linkLines(b)
  if table.getn(lines) ~= 1 then error("did not parse the sender out") end
  if not string.find(lines[1], "|Hplayer:Bobby|h", 1, true) then
    error("linked the wrong thing: " .. lines[1])
  end
  if not string.find(lines[1], "5:1 odds", 1, true) then
    error("lost part of the message: " .. lines[1])
  end
end)

step("/wf demo shows a clickable name without needing a whisper", function()
  local b = newClient("Salabeard")
  b:cmd("demo")
  if table.getn(linkLines(b)) == 0 then
    error("/wf demo produced nothing clickable to test with")
  end
  -- and the raw form, so a screenshot can show whether links parse at all
  local raw = false
  for _, m in ipairs(b.chat) do
    if string.find(m, "||Hplayer:", 1, true) then raw = true end
  end
  if not raw then error("/wf demo did not print the escaped form") end
end)

step("the chat hook is installed, and only once", function()
  local b = newClient("Salabeard")
  if not b.WR.hooked then error("the chat hook was never installed") end
  local after = b.env.ChatFrame_OnEvent
  b:fire("PLAYER_ENTERING_WORLD")
  if b.env.ChatFrame_OnEvent ~= after then
    error("hooked itself a second time, stacking wrappers")
  end
end)

----------------------------------------------------------------------
-- finding the other character with nothing typed
----------------------------------------------------------------------

step("two clients find each other with no target configured", function()
  local a = newClient("Salahaja")
  local b = newClient("Salabeard")

  if a.WR.Target() ~= "Salabeard" then
    error("Salahaja resolved " .. tostring(a.WR.Target()))
  end
  if b.WR.Target() ~= "Salahaja" then
    error("Salabeard resolved " .. tostring(b.WR.Target()))
  end

  a:deliver("Bobby", "you around?")
  a:drain()
  if table.getn(toTarget(a, "Salabeard")) ~= 1 then
    error("nothing was forwarded to the character it found")
  end
end)

--[[ Auto mode points both clients at each other by default, with nobody
     having typed anything -- which is precisely the loop setup. If the guard
     were wrong, the out-of-the-box configuration would be the broken one. ]]
step("auto mode does not create a loop out of the box", function()
  local a = newClient("Salahaja")
  local b = newClient("Salabeard")

  a:deliver("Bobby", "you around?")
  a:drain()
  local forwarded = toTarget(a, "Salabeard")
  if table.getn(forwarded) ~= 1 then error("nothing forwarded to start with") end

  for _, m in ipairs(forwarded) do b:deliver("Salahaja", m.text) end
  b:drain()
  if table.getn(toTarget(b, "Salahaja")) > 0 then
    error("bounced it straight back: " .. toTarget(b, "Salahaja")[1].text)
  end
end)

step("nothing is forwarded while the other client is not running", function()
  local a = newClient("Salahaja")
  a:deliver("Bobby", "you around?")
  a:drain()
  if table.getn(a.sent) > 0 then
    error("forwarded to " .. tostring(a.sent[1].target) .. " with nobody there")
  end
end)

step("a client that stopped saying it was there stops being the target", function()
  local a = newClient("Salahaja")
  local b = newClient("Salabeard")
  if a.WR.Target() ~= "Salabeard" then error("did not find it to begin with") end

  -- Salabeard's client is gone; its last word was three minutes ago.
  clock.t = clock.t + 200
  a.WR.others, a.WR.othersAt = nil, nil
  if a.WR.Target() ~= nil then
    error("still forwarding to " .. tostring(a.WR.Target()) .. " long after it went quiet")
  end
  clock.t = clock.t - 200
end)

--[[ The reason this exists rather than just typing a name: switching which alt
     you play must not need anything typed again. ]]
step("switching to a different alt moves the target", function()
  local a = newClient("Salahaja")
  local b = newClient("Salabeard")
  if a.WR.Target() ~= "Salabeard" then error("did not find Salabeard") end

  -- Logged out of Salabeard, logged in on Mahislap.
  clock.t = clock.t + 30
  local c = newClient("Mahislap")
  a.WR.others, a.WR.othersAt = nil, nil
  if a.WR.Target() ~= "Mahislap" then
    error("still aimed at " .. tostring(a.WR.Target()) .. " after switching alt")
  end
  clock.t = clock.t - 30
end)

step("it never picks itself, even alone in the file", function()
  local a = newClient("Salahaja")
  a:fire("PLAYER_LOGIN")
  if a.WR.Target() == "Salahaja" then error("resolved to itself") end
  if a.WR.Target() ~= nil then error("resolved " .. tostring(a.WR.Target())) end
end)

step("naming a character by hand switches automatic off", function()
  local a = newClient("Salahaja")
  local b = newClient("Salabeard")
  a:cmd("to Mahidot")
  if a.WR.config.auto then error("still automatic after being given a name") end
  if a.WR.Target() ~= "Mahidot" then
    error("used " .. tostring(a.WR.Target()) .. " instead of the name given")
  end

  a:cmd("auto")
  if a.WR.Target() ~= "Salabeard" then
    error("/wf auto did not go back to the live character")
  end
end)

step("the auto-answer names the character it found", function()
  local a = newClient("Salahaja")
  local b = newClient("Salabeard")
  a:cmd("reply on")
  a:deliver("Bobby", "hi")
  a:drain()
  local back = toTarget(a, "Bobby")
  if table.getn(back) ~= 1 then error("did not answer Bobby") end
  if not string.find(back[1].text, "Salabeard", 1, true) then
    error("answered without naming the live character: " .. back[1].text)
  end
end)

step("with no file API, automatic forwards nothing and says why", function()
  local a = newClient("Salahaja")
  a.env.WriteCustomFile = nil
  a.env.ReadCustomFile = nil
  a.WR.ready = false
  a.chat = {}
  a:fire("PLAYER_LOGIN")

  local told = false
  for _, m in ipairs(a.chat) do
    if string.find(m, "Nampower", 1, true) then told = true end
  end
  if not told then error("said nothing about automatic being unavailable") end

  a:deliver("Bobby", "hi")
  a:drain()
  if table.getn(a.sent) > 0 then error("forwarded somewhere anyway") end
end)

step("the presence file does not grow without limit", function()
  local a = newClient("Salahaja")
  files["WhisperRelay_presence.txt"] =
    string.rep("P~Filler~" .. clock.t .. "\n", 3000)
  local before = string.len(files["WhisperRelay_presence.txt"])
  a.WR.ReadPresence()
  local after = string.len(files["WhisperRelay_presence.txt"])
  if after >= before then
    error("presence file was " .. before .. " bytes and is now " .. after)
  end
  -- and trimming must not lose who is live
  if not a.WR.ReadPresence()["Filler"] then
    error("trimming dropped a live character")
  end
end)

step("a corrupt presence line is skipped, not fatal", function()
  local a = newClient("Salahaja")
  files["WhisperRelay_presence.txt"] =
    "garbage\nP~Salabeard~" .. clock.t .. "\nP~broken~notanumber\n~~~\n"
  a.WR.others, a.WR.othersAt = nil, nil
  if a.WR.Target() ~= "Salabeard" then
    error("resolved " .. tostring(a.WR.Target()) .. " from a file with junk in it")
  end
end)

----------------------------------------------------------------------
-- telling the other window that something popped
----------------------------------------------------------------------

local function alerts(c, target)
  local out = {}
  for _, m in ipairs(c.sent) do
    if m.target == target and string.sub(m.text, 1, 2) == ">!" then
      table.insert(out, m.text)
    end
  end
  return out
end

step("a battleground invite is passed to the other window", function()
  local a = newClient("Salahaja")
  local b = newClient("Salabeard")

  a.queues[1] = { status = "confirm", map = "Warsong Gulch" }
  a:fire("UPDATE_BATTLEFIELD_STATUS")
  a:drain()

  local got = alerts(a, "Salabeard")
  if table.getn(got) ~= 1 then
    error("sent " .. table.getn(got) .. " alerts, expected 1")
  end
  if not string.find(got[1], "Warsong Gulch", 1, true) then
    error("the alert does not say which battleground: " .. got[1])
  end
end)

--[[ The event fires again for every twitch of the queue list while the
     invite stands. One pop must not become a whisper a second. ]]
step("a standing invite is announced once, not per event", function()
  local a = newClient("Salahaja")
  local b = newClient("Salabeard")
  a.queues[1] = { status = "confirm", map = "Warsong Gulch" }
  for _ = 1, 8 do a:fire("UPDATE_BATTLEFIELD_STATUS") end
  a:drain()
  local n = table.getn(alerts(a, "Salabeard"))
  if n ~= 1 then error("sent " .. n .. " alerts for one invite") end
end)

step("a second, different pop is still announced", function()
  local a = newClient("Salahaja")
  local b = newClient("Salabeard")
  a.queues[1] = { status = "confirm", map = "Warsong Gulch" }
  a:fire("UPDATE_BATTLEFIELD_STATUS")
  -- Declined or expired, then Alterac pops.
  a.queues[1] = nil
  a:fire("UPDATE_BATTLEFIELD_STATUS")
  a.queues[2] = { status = "confirm", map = "Alterac Valley" }
  a:fire("UPDATE_BATTLEFIELD_STATUS")
  a:drain()
  local got = alerts(a, "Salabeard")
  if table.getn(got) ~= 2 then
    error("sent " .. table.getn(got) .. " alerts, expected 2")
  end
end)

step("being merely queued is not a pop", function()
  local a = newClient("Salahaja")
  local b = newClient("Salabeard")
  a.queues[1] = { status = "queued", map = "Warsong Gulch" }
  a:fire("UPDATE_BATTLEFIELD_STATUS")
  a:drain()
  if table.getn(alerts(a, "Salabeard")) > 0 then
    error("announced a queue that had not popped")
  end
end)

--[[ This server's dungeon finder, read the way UnitXP_SP3 reads it. There is
     no dungeon queue in vanilla at all, so this is the only signal there is. ]]
step("a dungeon group is passed on", function()
  local a = newClient("Salahaja")
  local b = newClient("Salabeard")
  a:fire("CHAT_MSG_ADDON", "LFT", "S2C_OFFER_NEW;something")
  a:drain()
  local got = alerts(a, "Salabeard")
  if table.getn(got) ~= 1 then
    error("sent " .. table.getn(got) .. " alerts for a dungeon offer")
  end
  if not string.find(got[1], "dungeon", 1, true) then
    error("the alert does not mention a dungeon: " .. got[1])
  end
end)

step("another addon's traffic is ignored", function()
  local a = newClient("Salahaja")
  local b = newClient("Salabeard")
  a:fire("CHAT_MSG_ADDON", "SomeOtherAddon", "S2C_OFFER_NEW")
  a:fire("CHAT_MSG_ADDON", "LFT", "S2C_HEARTBEAT")
  a:drain()
  if table.getn(alerts(a, "Salabeard")) > 0 then
    error("announced something that was not a dungeon offer")
  end
end)

step("a repeated offer inside the window is not repeated", function()
  local a = newClient("Salahaja")
  local b = newClient("Salabeard")
  for _ = 1, 5 do a:fire("CHAT_MSG_ADDON", "LFT", "S2C_OFFER_NEW") end
  a:drain()
  local n = table.getn(alerts(a, "Salabeard"))
  if n ~= 1 then error("sent " .. n .. " alerts for one offer") end
end)

step("an arriving alert is shown, loudly, with nobody to reply to", function()
  local b = newClient("Salabeard")
  b:deliver("Salahaja", ">! Warsong Gulch is ready to join")

  local shown = false
  for _, m in ipairs(b.chat) do
    if string.find(m, "Warsong Gulch", 1, true) then shown = true end
  end
  if not shown then error("the alert was never displayed") end
  for _, m in ipairs(b.chat) do
    if string.find(m, "|Hplayer:", 1, true) then
      error("offered a clickable reply to a person who does not exist")
    end
  end
end)

--[[ An alert is a message arriving by whisper like any other. If it could be
     forwarded on, two clients alerting each other would bounce it. ]]
step("an alert is never forwarded onward", function()
  local a = newClient("Salahaja")
  local b = newClient("Salabeard")
  b:deliver("Salahaja", ">! Warsong Gulch is ready to join")
  b:drain()
  if table.getn(b.sent) > 0 then
    error("relayed an alert back out: " .. b.sent[1].text)
  end
end)

step("/wf alerts turns it off", function()
  local a = newClient("Salahaja")
  local b = newClient("Salabeard")
  a:cmd("alerts")
  a.queues[1] = { status = "confirm", map = "Warsong Gulch" }
  a:fire("UPDATE_BATTLEFIELD_STATUS")
  a:drain()
  if table.getn(alerts(a, "Salabeard")) > 0 then error("still alerting") end
end)

step("nothing is sent when nobody else is logged in", function()
  local a = newClient("Salahaja")
  a.queues[1] = { status = "confirm", map = "Warsong Gulch" }
  a:fire("UPDATE_BATTLEFIELD_STATUS")
  a:drain()
  if table.getn(a.sent) > 0 then
    error("whispered " .. tostring(a.sent[1].target) .. " with nobody there")
  end
end)

step("a client with no dungeon finder is not confused by it", function()
  local a = newClient("Salahaja")
  local b = newClient("Salabeard")
  a.env.LFT_ADDON_PREFIX = nil
  a:fire("CHAT_MSG_ADDON", "LFT", "S2C_OFFER_NEW")
  a:drain()
  if table.getn(alerts(a, "Salabeard")) > 0 then
    error("announced a dungeon offer on a client with no dungeon finder")
  end
end)

----------------------------------------------------------------------
-- the popup on the window you are playing
----------------------------------------------------------------------

local function popupOf(c)
  return c.byName["WhisperRelayPopup"]
end

step("an arriving alert puts a popup on screen", function()
  local b = newClient("Salabeard")
  b:deliver("Salahaja", ">! Warsong Gulch is ready to join")

  local p = popupOf(b)
  if not p then error("no popup frame was ever built") end
  if not p:IsShown() then error("the popup was built but not shown") end
  if not string.find(p.what:GetText(), "Warsong Gulch", 1, true) then
    error("the popup says '" .. p.what:GetText() .. "'")
  end
  if not string.find(p.who:GetText(), "Salahaja", 1, true) then
    error("the popup does not say which character it is about: " .. p.who:GetText())
  end
end)

step("an ordinary forwarded whisper does not raise one", function()
  local b = newClient("Salabeard")
  b:deliver("Salahaja", ">> Bobby: you around?")
  local p = popupOf(b)
  if p and p:IsShown() then
    error("a normal whisper raised the queue popup")
  end
end)

step("clicking it dismisses it", function()
  local b = newClient("Salabeard")
  b:deliver("Salahaja", ">! Warsong Gulch is ready to join")
  local p = popupOf(b)
  p.scripts.OnClick()
  if p:IsShown() then error("clicking did not dismiss it") end
end)

--[[ It has to clear itself. A popup still on screen twenty minutes after the
     invite expired is worse than no popup, because the next real one is
     indistinguishable from the stale one. ]]
step("it clears itself once the invite would have expired", function()
  local b = newClient("Salabeard")
  b:deliver("Salahaja", ">! Warsong Gulch is ready to join")
  local p = popupOf(b)

  clock.gt = clock.gt + 30
  p.scripts.OnUpdate()
  if not p:IsShown() then error("it vanished while the invite was still live") end

  clock.gt = clock.gt + 40
  p.scripts.OnUpdate()
  if p:IsShown() then error("it is still up long after the invite expired") end
  clock.gt = clock.gt - 70
end)

step("a second pop replaces the first and gets the full time", function()
  local b = newClient("Salabeard")
  b:deliver("Salahaja", ">! Warsong Gulch is ready to join")
  local p = popupOf(b)

  clock.gt = clock.gt + 50
  b:deliver("Salahaja", ">! A dungeon group is ready")
  if not string.find(p.what:GetText(), "dungeon", 1, true) then
    error("the popup still shows the old pop: " .. p.what:GetText())
  end

  clock.gt = clock.gt + 20    -- 70s since the first, 20s since the second
  p.scripts.OnUpdate()
  if not p:IsShown() then
    error("the second pop inherited the first one's countdown")
  end
  clock.gt = clock.gt - 70
end)

step("/wf popup turns it off, and hides one already up", function()
  local b = newClient("Salabeard")
  b:deliver("Salahaja", ">! Warsong Gulch is ready to join")
  local p = popupOf(b)
  if not p:IsShown() then error("nothing to turn off") end

  b:cmd("popup")
  if p:IsShown() then error("turning it off left one on screen") end

  b:deliver("Salahaja", ">! Alterac Valley is ready to join")
  if p:IsShown() then error("still popping up while off") end

  -- and the chat line still arrives, because that half is separate
  local told = false
  for _, m in ipairs(b.chat) do
    if string.find(m, "Alterac Valley", 1, true) then told = true end
  end
  if not told then error("turning the popup off silenced the alert entirely") end
end)

step("/wf testpop shows one without waiting for a queue", function()
  local b = newClient("Salabeard")
  b:cmd("testpop")
  local p = popupOf(b)
  if not p or not p:IsShown() then error("/wf testpop showed nothing") end
end)

step("it makes a noise and flashes the taskbar", function()
  local b = newClient("Salabeard")
  local before = b.sounds
  b:deliver("Salahaja", ">! Warsong Gulch is ready to join")
  if b.sounds <= before then error("no sound was played") end
  if (b.flashed or 0) == 0 then error("the taskbar icon was not flashed") end
end)

step("the popup frame is not the event frame", function()
  local b = newClient("Salabeard")
  b:deliver("Salahaja", ">! Warsong Gulch is ready to join")
  if popupOf(b) == b.frame then
    error("the popup replaced the addon's event frame")
  end
  -- ...and events still work afterwards
  b:deliver("Salahaja", ">> Bobby: still here?")
  local ok = false
  for _, m in ipairs(b.chat) do
    if string.find(m, "still here?", 1, true) then ok = true end
  end
  if not ok then error("the addon stopped handling whispers") end
end)

----------------------------------------------------------------------
-- giving up when the target is not there
----------------------------------------------------------------------

local function notFound(c, name)
  c:fire("CHAT_MSG_SYSTEM", "No player named '" .. name .. "' is currently playing.")
end

step("a named target going offline turns forwarding off", function()
  local c = newClient("Salahaja")
  c:cmd("to Salabeard")
  c:deliver("Bobby", "you around?")
  c:drain()
  notFound(c, "Salabeard")

  if c.WR.config.enabled then
    error("still forwarding to a character that is not there")
  end
  c.sent = {}
  c:deliver("Charlie", "hello?")
  c:drain()
  if table.getn(c.sent) > 0 then
    error("sent " .. c.sent[1].text .. " after giving up")
  end
end)

--[[ The server answers every forward still in flight with the same refusal.
     Each one arriving is not a fresh reason to announce anything. ]]
step("it gives up once, not once per bounced message", function()
  local c = newClient("Salahaja")
  c:cmd("to Salabeard")
  for _ = 1, 4 do notFound(c, "Salabeard") end
  local said = 0
  for _, m in ipairs(c.chat) do
    if string.find(m, "not online", 1, true) then said = said + 1 end
  end
  if said ~= 1 then error("announced it " .. said .. " times") end
end)

--[[ Messages already queued for a character who is not there would each be
     delivered to nobody and each bounce another refusal. ]]
step("anything still queued for them is dropped, and said so", function()
  local c = newClient("Salahaja")
  c:cmd("to Salabeard")
  c:cmd("reply off")
  for i = 1, 5 do c:deliver("Bobby", "message " .. i) end
  if table.getn(c.WR.queue) == 0 then error("nothing was queued to drop") end

  notFound(c, "Salabeard")
  if table.getn(c.WR.queue) > 0 then
    error(table.getn(c.WR.queue) .. " message(s) still queued for a dead target")
  end
  local told = false
  for _, m in ipairs(c.chat) do
    if string.find(m, "were not sent", 1, true) then told = true end
  end
  if not told then error("dropped them silently") end
end)

step("/wf on tries again", function()
  local c = newClient("Salahaja")
  c:cmd("to Salabeard")
  notFound(c, "Salabeard")
  if c.WR.config.enabled then error("did not give up") end

  c:cmd("on")
  c.sent = {}
  c:deliver("Bobby", "you around?")
  c:drain()
  if table.getn(toTarget(c, "Salabeard")) == 0 then
    error("/wf on did not resume forwarding")
  end
end)

step("naming a different character resumes too", function()
  local c = newClient("Salahaja")
  c:cmd("to Salabeard")
  notFound(c, "Salabeard")
  c:cmd("to Mahislap")
  c.sent = {}
  c:deliver("Bobby", "you around?")
  c:drain()
  if table.getn(toTarget(c, "Mahislap")) == 0 then
    error("naming a new character did not resume forwarding")
  end
end)

--[[ Auto mode has nothing to disable -- it just has no target. What it must
     NOT do is pick the same logged-out character straight back up, which is
     exactly what it would do: their last heartbeat is still recent. ]]
step("auto mode drops the dead character instead of re-picking it", function()
  local a = newClient("Salahaja")
  local b = newClient("Salabeard")
  if a.WR.Target() ~= "Salabeard" then error("did not find Salabeard") end

  notFound(a, "Salabeard")
  if a.WR.Target() == "Salabeard" then
    error("picked the logged-out character straight back up")
  end
  if not a.WR.config.enabled then
    error("turned forwarding off in auto mode, where there is nothing to turn off")
  end
end)

step("auto mode moves to whoever else is there", function()
  local a = newClient("Salahaja")
  local b = newClient("Salabeard")
  clock.t = clock.t + 5
  local c = newClient("Mahislap")

  a.WR.others, a.WR.othersAt = nil, nil
  if a.WR.Target() ~= "Mahislap" then
    error("expected the newest, got " .. tostring(a.WR.Target()))
  end
  notFound(a, "Mahislap")
  if a.WR.Target() ~= "Salabeard" then
    error("did not fall back to the other live client: " ..
      tostring(a.WR.Target()))
  end
  clock.t = clock.t - 5
end)

step("a character that logs back in is used again", function()
  local a = newClient("Salahaja")
  local b = newClient("Salabeard")
  notFound(a, "Salabeard")
  if a.WR.Target() == "Salabeard" then error("still aimed at it") end

  -- Back at the keyboard: a heartbeat newer than the refusal.
  clock.t = clock.t + 120
  b.WR.sinceBeat = 999
  b:tick(1)
  a.WR.others, a.WR.othersAt = nil, nil
  if a.WR.Target() ~= "Salabeard" then
    error("did not come back after logging in again: " ..
      tostring(a.WR.Target()))
  end
  clock.t = clock.t - 120
end)

step("someone else's failed whisper does not stop anything", function()
  local c = newClient("Salahaja")
  c:cmd("to Salabeard")
  notFound(c, "Zzzzz")
  if not c.WR.config.enabled then
    error("gave up because an unrelated whisper failed")
  end
end)

--[[ "off" is an instruction, not a message. Taking it literally set the
     auto-answer TO the word "off" and left it on, so the next person to
     whisper you got told "off". ]]
step("/wf reply off means off, not a message saying off", function()
  local c = newClient("Salahaja")
  c:cmd("to Salabeard")
  c:cmd("reply off")
  if c.WR.config.autoReply then error("auto-answer is still on") end

  c:deliver("Bobby", "you around?")
  c:drain()
  if table.getn(toTarget(c, "Bobby")) > 0 then
    error("answered Bobby with: " .. toTarget(c, "Bobby")[1].text)
  end

  c:cmd("reply on")
  if not c.WR.config.autoReply then error("/wf reply on did not turn it back on") end
end)

----------------------------------------------------------------------
-- the list of characters it has learned
----------------------------------------------------------------------

local function known(c)
  return c.WR.config.known or {}
end

local function hasName(c, name)
  for _, n in ipairs(known(c)) do
    if n == name then return true end
  end
  return false
end

--[[ The point of the list: typed once, never again. ]]
step("naming a character remembers it", function()
  local c = newClient("Salahaja")
  c:cmd("to Bobby")
  if not hasName(c, "Bobby") then error("did not remember a name that was typed") end
  c:cmd("to Bobalt")
  if not hasName(c, "Bobby") then error("forgot the first one") end
  if known(c)[1] ~= "Bobalt" then
    error("the newest is not first: " .. tostring(known(c)[1]))
  end
end)

step("naming the same character twice does not duplicate it", function()
  local c = newClient("Salahaja")
  c:cmd("to Bobby")
  c:cmd("to Bobby")
  local n = 0
  for _, name in ipairs(known(c)) do
    if name == "Bobby" then n = n + 1 end
  end
  if n ~= 1 then error("remembered Bobby " .. n .. " times") end
end)

--[[ Your own characters need no typing at all: the presence file already
     grows every time one of them logs in beside this client. ]]
step("your own alts are learned from logging in, with nothing typed", function()
  local a = newClient("Salahaja")
  local b = newClient("Salabeard")
  a.WR.others, a.WR.othersAt = nil, nil
  a.WR.Target()
  if not hasName(a, "Salabeard") then
    error("did not learn the character that logged in beside it")
  end

  clock.t = clock.t + 5
  local c = newClient("Mahislap")
  a.WR.others, a.WR.othersAt = nil, nil
  a.WR.Target()
  if not hasName(a, "Mahislap") then error("did not learn the next alt") end
  clock.t = clock.t - 5
end)

step("it never learns itself", function()
  local a = newClient("Salahaja")
  local b = newClient("Salabeard")
  a.WR.others, a.WR.othersAt = nil, nil
  a.WR.Target()
  if hasName(a, "Salahaja") then error("put itself in its own list") end
end)

--[[ A name merely seen must not displace the one you chose. ]]
step("a name that logged in does not outrank one you typed", function()
  local a = newClient("Salahaja")
  a:cmd("to Bobby")
  -- /wf to turns auto off, and the presence file is only read in auto mode.
  a:cmd("auto")
  local b = newClient("Salabeard")
  a.WR.others, a.WR.othersAt = nil, nil
  a.WR.Target()
  if not hasName(a, "Salabeard") then
    error("never learned the alt, so this proves nothing")
  end
  if known(a)[1] ~= "Bobby" then
    error("a passing alt took the front: " .. tostring(known(a)[1]))
  end
end)

----------------------------------------------------------------------
-- what the list is, and is not, used for
----------------------------------------------------------------------

--[[ Deliberately NOT clever. The shared folder decides where forwards go;
     the list is a record of what this machine has seen, so /wf list can
     show you that both of your accounts are being noticed. Picking a target
     off it on a hunch would mean forwarding private messages to whoever
     happened to be online. ]]
step("a remembered name is not used just because it is remembered", function()
  local c = newClient("Salahaja")
  c:cmd("to Bobby")
  c:cmd("auto")           -- back to deciding from the shared folder
  c.WR.others, c.WR.othersAt = nil, nil
  if c.WR.Target() ~= nil then
    error("picked " .. tostring(c.WR.Target()) .. " with nobody logged in")
  end
end)

step("a name you typed is used when there is no shared folder at all", function()
  local c = newClient("Salahaja")
  c.env.WriteCustomFile, c.env.ReadCustomFile = nil, nil
  c:cmd("to Bobby")
  if c.WR.Target() ~= "Bobby" then
    error("ignored the name it was given: " .. tostring(c.WR.Target()))
  end
end)

step("/wf list says which of them is logged in right now", function()
  local a = newClient("Salahaja")
  local b = newClient("Salabeard")
  a.WR.others, a.WR.othersAt = nil, nil
  a.WR.Target()                     -- learns Salabeard from the shared folder
  a:cmd("to Bobby")                 -- and a name typed by hand
  a.chat = {}
  a:cmd("list")

  local sawLive, sawNot = false, false
  for _, m in ipairs(a.chat) do
    if string.find(m, "Salabeard", 1, true)
       and string.find(m, "logged in", 1, true)
       and not string.find(m, "not logged in", 1, true) then sawLive = true end
    if string.find(m, "Bobby", 1, true)
       and string.find(m, "not logged in", 1, true) then sawNot = true end
  end
  if not sawLive then error("did not show the live client as logged in") end
  if not sawNot then error("did not show the typed name as not logged in") end
end)

step("/wf forget drops one, and all", function()
  local c = newClient("Salahaja")
  c:cmd("to Bobby")
  c:cmd("to Bobalt")
  c:cmd("forget Bobby")
  if hasName(c, "Bobby") then error("/wf forget did not drop it") end
  if not hasName(c, "Bobalt") then error("/wf forget dropped the wrong one") end
  c:cmd("forget all")
  if table.getn(known(c)) > 0 then error("/wf forget all left names behind") end
end)

step("the list does not grow without limit", function()
  local c = newClient("Salahaja")
  for i = 1, 25 do c:cmd("to Alt" .. i) end
  if table.getn(known(c)) > 10 then
    error("remembered " .. table.getn(known(c)) .. " names")
  end
  if not hasName(c, "Alt25") then error("dropped the most recent one") end
end)

----------------------------------------------------------------------
-- more than two accounts on the one machine
----------------------------------------------------------------------

--[[ Four accounts means three windows you are not looking at. Picking the
     likeliest one leaves two that can still hide a whisper. ]]
step("a whisper reaches every other client, not just one", function()
  local a = newClient("Alpha")
  local b = newClient("Bravo")
  local c = newClient("Charlie")
  local d = newClient("Delta")

  b:deliver("Bobby", "you around?")
  b:drain()

  for _, name in ipairs({ "Alpha", "Charlie", "Delta" }) do
    local got = toTarget(b, name)
    if table.getn(got) ~= 1 then
      error(name .. " got " .. table.getn(got) .. " forwards, expected 1")
    end
    if not string.find(got[1].text, "Bobby", 1, true) then
      error("the forward to " .. name .. " lost the sender: " .. got[1].text)
    end
  end
  if table.getn(toTarget(b, "Bravo")) > 0 then error("forwarded to itself") end
end)

step("whichever one is whispered, the rest hear about it", function()
  local a = newClient("Alpha")
  local b = newClient("Bravo")
  local c = newClient("Charlie")
  local d = newClient("Delta")

  d:deliver("Bobby", "and now you?")
  d:drain()
  for _, name in ipairs({ "Alpha", "Bravo", "Charlie" }) do
    if table.getn(toTarget(d, name)) ~= 1 then
      error(name .. " heard nothing when Delta was whispered")
    end
  end
end)

--[[ The loop guard has to hold for all of them. With four clients a forward
     landing on three others is three chances to bounce it back. ]]
step("four clients do not bounce a forward between them", function()
  local a = newClient("Alpha")
  local b = newClient("Bravo")
  local c = newClient("Charlie")
  local d = newClient("Delta")

  b:deliver("Bobby", "you around?")
  b:drain()

  local relayed = {}
  for _, m in ipairs(b.sent) do table.insert(relayed, m) end
  for _, other in ipairs({ a, c, d }) do
    for _, m in ipairs(relayed) do
      if m.target == other.name then other:deliver("Bravo", m.text) end
    end
    other:drain()
    if table.getn(other.sent) > 0 then
      error(other.name .. " passed the forward on: " .. other.sent[1].text)
    end
  end
end)

step("one of your own windows whispering you is not forwarded", function()
  local a = newClient("Alpha")
  local b = newClient("Bravo")
  local c = newClient("Charlie")

  -- Charlie is third in the list, not first: the guard must check them all.
  b:deliver("Charlie", "bring me a stack of runes")
  b:drain()
  if table.getn(b.sent) > 0 then
    error("relayed a message from another of your own clients: " .. b.sent[1].text)
  end
end)

step("a queue pop is told to every other client", function()
  local a = newClient("Alpha")
  local b = newClient("Bravo")
  local c = newClient("Charlie")

  b.queues[1] = { status = "confirm", map = "Warsong Gulch" }
  b:fire("UPDATE_BATTLEFIELD_STATUS")
  b:drain()

  for _, name in ipairs({ "Alpha", "Charlie" }) do
    local got = toTarget(b, name)
    if table.getn(got) ~= 1 then
      error(name .. " was not told about the pop")
    end
    if string.sub(got[1].text, 1, 2) ~= ">!" then
      error("not sent as an alert: " .. got[1].text)
    end
  end
end)

step("a long whisper is split once and every part goes to everyone", function()
  local a = newClient("Alpha")
  local b = newClient("Bravo")
  local c = newClient("Charlie")

  b:deliver("Bobby", string.rep("abcdefghij", 40))
  b:drain()
  local toA = table.getn(toTarget(b, "Alpha"))
  local toC = table.getn(toTarget(b, "Charlie"))
  if toA < 2 then error("Alpha got " .. toA .. " parts") end
  if toA ~= toC then
    error("Alpha got " .. toA .. " parts and Charlie got " .. toC)
  end
end)

step("with nobody else logged in, nothing goes anywhere", function()
  local a = newClient("Alpha")
  a:deliver("Bobby", "you around?")
  a:drain()
  if table.getn(a.sent) > 0 then
    error("forwarded to " .. tostring(a.sent[1].target) .. " with nobody there")
  end
end)

step("the echo names everyone it went to", function()
  local a = newClient("Alpha")
  local b = newClient("Bravo")
  local c = newClient("Charlie")
  b.chat = {}
  b:deliver("Bobby", "you around?")

  local named = false
  for _, m in ipairs(b.chat) do
    if string.find(m, "Alpha", 1, true) and string.find(m, "Charlie", 1, true) then
      named = true
    end
  end
  if not named then error("the echo did not list both windows") end
end)

--[[ Answering the sender has to name ONE character to go to, so it names the
     window that spoke most recently -- the best guess at where you are. ]]
step("the auto-answer names the most recently active window", function()
  local a = newClient("Alpha")
  clock.t = clock.t + 10
  local c = newClient("Charlie")
  local b = newClient("Bravo")
  b:cmd("reply on")
  b.WR.others, b.WR.othersAt = nil, nil

  b:deliver("Bobby", "you around?")
  b:drain()
  local back = toTarget(b, "Bobby")
  if table.getn(back) ~= 1 then error("answered " .. table.getn(back) .. " times") end
  if not string.find(back[1].text, "Charlie", 1, true) then
    error("named the wrong window: " .. back[1].text)
  end
  clock.t = clock.t - 10
end)

step("the auto-answer stays off unless asked for", function()
  local a = newClient("Alpha")
  local b = newClient("Bravo")
  b:deliver("Bobby", "you around?")
  b:drain()
  if table.getn(toTarget(b, "Bobby")) > 0 then
    error("answered the sender without being asked to")
  end
end)

----------------------------------------------------------------------
-- the settings window
----------------------------------------------------------------------

local function panelOf(c) return c.byName["WhisperRelaySettings"] end

local function boxFor(c, key)
  local p = panelOf(c)
  for _, b in ipairs((p and p.boxes) or {}) do
    if b.key == key then return b end
  end
  return nil
end

step("/wf config opens a window with a switch for each setting", function()
  local c = newClient("Salahaja")
  c:cmd("config")
  local p = panelOf(c)
  if not p then error("no settings window was built") end
  if not p:IsShown() then error("built it but did not show it") end

  for _, key in ipairs({ "enabled", "alerts", "popup", "inline",
                         "replyLink", "autoReply", "announce" }) do
    if not boxFor(c, key) then error("no switch for " .. key) end
  end
end)

step("the switches show what the setting currently is", function()
  local c = newClient("Salahaja")
  c:cmd("config")
  -- autoReply is off by default, enabled is on.
  if boxFor(c, "autoReply").tick:IsShown() then
    error("showed the auto-answer as on when it is off by default")
  end
  if not boxFor(c, "enabled").tick:IsShown() then
    error("showed forwarding as off when it is on by default")
  end
end)

step("clicking a switch changes the setting and the tick", function()
  local c = newClient("Salahaja")
  c:cmd("config")
  local b = boxFor(c, "autoReply")
  b.scripts.OnClick()
  if not c.WR.config.autoReply then error("the click did not change the setting") end
  if not b.tick:IsShown() then error("the setting changed but the tick did not") end

  b.scripts.OnClick()
  if c.WR.config.autoReply then error("it did not turn back off") end
  if b.tick:IsShown() then error("the tick stayed on") end
end)

step("a switch changed by command shows up when reopened", function()
  local c = newClient("Salahaja")
  c:cmd("config")
  c:cmd("config")                -- closed again
  c:cmd("reply on")
  c:cmd("config")
  if not boxFor(c, "autoReply").tick:IsShown() then
    error("the window did not pick up a change made by command")
  end
end)

step("turning the popup off from the window takes down one on screen", function()
  local b = newClient("Salabeard")
  b:deliver("Salahaja", ">! Warsong Gulch is ready to join")
  local popup = b.byName["WhisperRelayPopup"]
  if not popup:IsShown() then error("no popup to take down") end

  b:cmd("config")
  boxFor(b, "popup").scripts.OnClick()
  if popup:IsShown() then error("the popup stayed up") end
end)

--[[ The one thing no slash command shows as plainly: whether it is doing
     anything at all right now. ]]
step("the window says where forwards are going", function()
  local a = newClient("Alpha")
  local b = newClient("Bravo")
  local c = newClient("Charlie")
  b.WR.others, b.WR.othersAt = nil, nil
  b:cmd("config")
  local said = panelOf(b).state:GetText()
  if not (string.find(said, "Alpha", 1, true) and string.find(said, "Charlie", 1, true)) then
    error("it says: " .. said)
  end
end)

--[[ Nothing logged in is not a fault, and must not read like one -- it
     starts again by itself when another window appears. ]]
step("with nobody else logged in it says so, without alarm", function()
  local a = newClient("Alpha")
  a:cmd("config")
  local said = panelOf(a).state:GetText()
  if not string.find(said, "No other character", 1, true) then
    error("it says: " .. said)
  end
  if string.find(said, "/wf to", 1, true) then
    error("told you to fix something that is not broken: " .. said)
  end
end)

step("with forwarding switched off it says that instead", function()
  local a = newClient("Alpha")
  local b = newClient("Bravo")
  a:cmd("off")
  a:cmd("config")
  local said = panelOf(a).state:GetText()
  if not string.find(said, "off", 1, true) then error("it says: " .. said) end
end)

step("/wf config closes it again", function()
  local c = newClient("Salahaja")
  c:cmd("config")
  c:cmd("config")
  if panelOf(c):IsShown() then error("did not close") end
end)

step("the settings window is not the event frame or the popup", function()
  local b = newClient("Salabeard")
  b:cmd("config")
  if panelOf(b) == b.frame then error("it replaced the event frame") end
  b:deliver("Salahaja", ">> Bobby: still here?")
  local ok = false
  for _, m in ipairs(b.chat) do
    if string.find(m, "still here?", 1, true) then ok = true end
  end
  if not ok then error("the addon stopped handling whispers") end
end)

----------------------------------------------------------------------
-- writing the reply message
----------------------------------------------------------------------

local function replyBox(c) return c.byName["WhisperRelayReplyBox"] end

local function sentTo(c, who)
  local out = {}
  for _, m in ipairs(toTarget(c, who)) do table.insert(out, m.text) end
  return out
end

step("the window has a box with the message in it", function()
  local c = newClient("Salahaja")
  c:cmd("config")
  local e = replyBox(c)
  if not e then error("no edit box was built") end
  if not string.find(e:GetText(), "{char}", 1, true) then
    error("the box does not show the message: " .. e:GetText())
  end
end)

step("typing a message and pressing enter saves it", function()
  local a = newClient("Salahaja")
  local b = newClient("Salabeard")
  a:cmd("reply on")
  a:cmd("config")

  local e = replyBox(a)
  e:SetFocus()
  e:SetText("gone fishing, try {char}")
  e.scripts.OnEnterPressed()

  if a.WR.config.replyText ~= "gone fishing, try {char}" then
    error("saved: " .. tostring(a.WR.config.replyText))
  end
  if a.WR.config.replyDefault then
    error("typing did not switch it off the stock wording")
  end

  a:deliver("Bobby", "you around?")
  a:drain()
  local got = sentTo(a, "Bobby")
  if table.getn(got) ~= 1 then error("answered " .. table.getn(got) .. " times") end
  if got[1] ~= "gone fishing, try Salabeard" then
    error("Bobby received: " .. got[1])
  end
end)

step("clicking away from the box saves it too", function()
  local c = newClient("Salahaja")
  c:cmd("config")
  local e = replyBox(c)
  e:SetFocus()
  e:SetText("back in five")
  e.scripts.OnEditFocusLost()
  if c.WR.config.replyText ~= "back in five" then
    error("saved: " .. tostring(c.WR.config.replyText))
  end
end)

--[[ Escape is "forget this edit", and the only way to find out whether it
     worked is that the box goes back to what is actually stored. ]]
step("escape abandons an edit instead of saving it", function()
  local c = newClient("Salahaja")
  c:cmd("config")
  local e = replyBox(c)
  e:SetFocus()
  e:SetText("half a sen")
  e.scripts.OnEscapePressed()
  if c.WR.config.replyText == "half a sen" then
    error("escape saved the edit anyway")
  end
  if e:GetText() == "half a sen" then
    error("the box kept the abandoned text")
  end
end)

step("Default and Custom choose between two wordings", function()
  local a = newClient("Salahaja")
  local b = newClient("Salabeard")
  a:cmd("reply on")
  a:cmd("config")
  local p = panelOf(a)

  local e = replyBox(a)
  e:SetFocus()
  e:SetText("mine says this, {char}")
  e.scripts.OnEnterPressed()

  p.useDefault.scripts.OnClick()
  if not a.WR.config.replyDefault then error("Default did not take") end
  a:deliver("Bobby", "one")
  a:drain()
  if not string.find(sentTo(a, "Bobby")[1], "Not watching", 1, true) then
    error("Default sent: " .. sentTo(a, "Bobby")[1])
  end

  --[[ The whole reason there are two fields: going back to Custom must find
       what was typed, not an empty box. ]]
  p.useCustom.scripts.OnClick()
  if a.WR.config.replyText ~= "mine says this, {char}" then
    error("Custom lost the typed message: " .. tostring(a.WR.config.replyText))
  end
end)

step("the box shows the stock wording while Default is chosen", function()
  local c = newClient("Salahaja")
  c:cmd("config")
  local p, e = panelOf(c), replyBox(c)
  p.useCustom.scripts.OnClick()
  e:SetFocus()
  e:SetText("custom thing")
  e.scripts.OnEnterPressed()

  p.useDefault.scripts.OnClick()
  if string.find(e:GetText(), "custom thing", 1, true) then
    error("still showing the custom text while Default is chosen")
  end
  if not string.find(e:GetText(), "Not watching", 1, true) then
    error("the box shows: " .. e:GetText())
  end
end)

--[[ Refresh runs on every click in this window. Replacing the text under the
     cursor mid-sentence is what makes a settings window feel broken. ]]
step("refreshing does not overwrite what is being typed", function()
  local c = newClient("Salahaja")
  c:cmd("config")
  local e = replyBox(c)
  e:SetFocus()
  e:SetText("half written")
  c.WR.RefreshPanel()
  if e:GetText() ~= "half written" then
    error("the text changed under the cursor: " .. e:GetText())
  end
end)

--[[ {char} is the one part of this nobody can picture, so the window shows
     the finished sentence. ]]
step("the preview shows what they actually receive", function()
  local a = newClient("Salahaja")
  local b = newClient("Salabeard")
  a.WR.others, a.WR.othersAt = nil, nil
  a:cmd("config")
  local said = panelOf(a).preview:GetText()
  if string.find(said, "{char}", 1, true) then
    error("the preview still shows the token: " .. said)
  end
  if not string.find(said, "Salabeard", 1, true) then
    error("the preview does not name the live window: " .. said)
  end
end)

step("/wf reply default goes back to the stock wording", function()
  local c = newClient("Salahaja")
  c:cmd("reply something of my own")
  if c.WR.config.replyDefault then error("a typed message did not take") end
  c:cmd("reply default")
  if not c.WR.config.replyDefault then error("/wf reply default did nothing") end
  if c.WR.config.replyText ~= "something of my own" then
    error("going back to default threw the custom one away")
  end
end)

step("an emptied box falls back rather than whispering nothing", function()
  local a = newClient("Salahaja")
  local b = newClient("Salabeard")
  a:cmd("reply on")
  a:cmd("config")
  -- Custom, then emptied: Default would answer with the stock wording and
  -- prove nothing about an empty custom message.
  panelOf(a).useCustom.scripts.OnClick()
  local e = replyBox(a)
  e:SetFocus()
  e:SetText("")
  e.scripts.OnEditFocusLost()
  if a.WR.config.replyDefault then error("not actually on the custom message") end

  a:deliver("Bobby", "you around?")
  a:drain()
  local got = sentTo(a, "Bobby")
  if table.getn(got) ~= 1 then error("answered " .. table.getn(got) .. " times") end
  if got[1] == "" then error("whispered an empty message") end
end)

----------------------------------------------------------------------
-- party and raid chat, to the window that is not in the group
----------------------------------------------------------------------

local function groupLines(c, target)
  local out = {}
  for _, m in ipairs(toTarget(c, target)) do
    if string.sub(m.text, 1, 2) == ">#" then table.insert(out, m.text) end
  end
  return out
end

step("party chat reaches the window that is not in the party", function()
  local a = newClient("Alpha")
  local b = newClient("Bravo")
  a:cmd("group")
  a.party = { "Bobby", "Charlie" }

  a:fire("CHAT_MSG_PARTY", "pull in 10", "Bobby")
  a:drain()

  local got = groupLines(a, "Bravo")
  if table.getn(got) ~= 1 then
    error("sent " .. table.getn(got) .. " lines, expected 1")
  end
  if not string.find(got[1], "pull in 10", 1, true) then
    error("the line lost what was said: " .. got[1])
  end
  if not string.find(got[1], "Bobby", 1, true) then
    error("the line lost who said it: " .. got[1])
  end
end)

--[[ The check that makes this a feature rather than an echo. A character in
     the same party already has every line in its own chat window. ]]
step("a window already in that party is not told again", function()
  local a = newClient("Alpha")
  local b = newClient("Bravo")
  a:cmd("group")
  a.party = { "Bravo" }                 -- both characters in the one group

  a:fire("CHAT_MSG_PARTY", "pull in 10", "Bobby")
  a:drain()
  if table.getn(groupLines(a, "Bravo")) > 0 then
    error("echoed party chat to a character standing in the same party")
  end
end)

step("with three windows, only the ones outside hear it", function()
  local a = newClient("Alpha")
  local b = newClient("Bravo")
  local c = newClient("Charlie")
  a:cmd("group")
  a.party = { "Bravo" }                 -- Bravo is here, Charlie is not

  a:fire("CHAT_MSG_PARTY", "invis pot now", "Bobby")
  a:drain()
  if table.getn(groupLines(a, "Bravo")) > 0 then
    error("told the window that is in the party")
  end
  if table.getn(groupLines(a, "Charlie")) ~= 1 then
    error("did not tell the window that is outside it")
  end
end)

step("raid chat and raid warnings come through too", function()
  local a = newClient("Alpha")
  local b = newClient("Bravo")
  a:cmd("group")
  a.raid = { "Bobby" }

  a:fire("CHAT_MSG_RAID", "healers on the tank", "Bobby")
  a:fire("CHAT_MSG_RAID_LEADER", "moving in", "Bobby")
  a:fire("CHAT_MSG_RAID_WARNING", "RUN", "Bobby")
  a:drain()
  if table.getn(groupLines(a, "Bravo")) ~= 3 then
    error("got " .. table.getn(groupLines(a, "Bravo")) .. " of 3")
  end
end)

step("it is off until asked for", function()
  local a = newClient("Alpha")
  local b = newClient("Bravo")
  a.party = { "Bobby" }
  a:fire("CHAT_MSG_PARTY", "anyone there?", "Bobby")
  a:drain()
  if table.getn(groupLines(a, "Bravo")) > 0 then
    error("forwarded group chat without being turned on")
  end
end)

step("your own lines are not forwarded back to you", function()
  local a = newClient("Alpha")
  local b = newClient("Bravo")
  a:cmd("group")
  a.party = { "Bobby" }
  a:fire("CHAT_MSG_PARTY", "on my way", "Alpha")
  a:drain()
  if table.getn(groupLines(a, "Bravo")) > 0 then
    error("forwarded this character's own party line")
  end
end)

--[[ A busy run is a line every few seconds and every one becomes a whisper.
     Unchecked that is a flood, and the client answers a flood by silently
     dropping what you send. ]]
step("a talkative group is muted rather than flooded", function()
  local a = newClient("Alpha")
  local b = newClient("Bravo")
  a:cmd("group")
  a.party = { "Bobby" }

  for i = 1, 60 do
    a:fire("CHAT_MSG_PARTY", "line " .. i, "Bobby")
  end
  a:drain()

  local n = table.getn(groupLines(a, "Bravo"))
  if n > 30 then error("forwarded " .. n .. " lines without stopping") end
  if n == 0 then error("forwarded nothing at all") end

  local warned = false
  for _, m in ipairs(a.chat) do
    if string.find(m, "paused", 1, true) then warned = true end
  end
  if not warned then error("went quiet without saying why") end
end)

step("and starts again once the mute expires", function()
  local a = newClient("Alpha")
  local b = newClient("Bravo")
  a:cmd("group")
  a.party = { "Bobby" }
  for i = 1, 60 do a:fire("CHAT_MSG_PARTY", "line " .. i, "Bobby") end
  a:drain()
  a.sent = {}

  clock.t = clock.t + 200
  -- Bravo is still logged in, so it has gone on saying so; without that its
  -- heartbeat ages out and the test proves the wrong thing.
  activate_beat(b)
  a.WR.others, a.WR.othersAt = nil, nil
  a:fire("CHAT_MSG_PARTY", "still here?", "Bobby")
  a:drain()
  if table.getn(groupLines(a, "Bravo")) ~= 1 then
    error("did not resume after the pause")
  end
  clock.t = clock.t - 200
end)

step("an arriving line is shown, with the speaker clickable", function()
  local b = newClient("Bravo")
  b:deliver("Alpha", ">#P~Bobby~pull in 10")

  local shown = false
  for _, m in ipairs(b.chat) do
    if string.find(m, "pull in 10", 1, true)
       and string.find(m, "|Hplayer:Bobby|h", 1, true)
       and string.find(m, "Party", 1, true) then shown = true end
  end
  if not shown then
    error("shown as: " .. table.concat(b.chat, " | "))
  end
end)

--[[ From a STRANGER, not from one of our own windows: a line from Alpha is
     already refused because Alpha is a window we forward to, which would let
     this pass while proving nothing about the marker. ]]
step("a line carrying the group marker is never forwarded onward", function()
  local a = newClient("Alpha")
  local b = newClient("Bravo")
  b:cmd("group")
  b.party = { "Someone" }
  b:deliver("Stranger", ">#P~Bobby~pull in 10")
  b:drain()
  for _, m in ipairs(b.sent) do
    if m.target == "Alpha" then
      error("relayed a relayed line: " .. m.text)
    end
  end
end)

step("a line containing a separator survives", function()
  local b = newClient("Bravo")
  b:deliver("Alpha", ">#R~Bobby~use the ~ key, then run")
  local ok = false
  for _, m in ipairs(b.chat) do
    if string.find(m, "use the ~ key, then run", 1, true) then ok = true end
  end
  if not ok then error("mangled: " .. table.concat(b.chat, " | ")) end
end)

----------------------------------------------------------------------
-- answering as the character they actually wrote to
----------------------------------------------------------------------

local function relayAsks(c, target)
  local out = {}
  for _, m in ipairs(toTarget(c, target)) do
    if string.sub(m.text, 1, 2) == ">@" then table.insert(out, m.text) end
  end
  return out
end

--[[ Clicking the name answers from whoever you are sitting on, which is a
     different character from the one they wrote to. This is the other half. ]]
step("/wr answers through the window the whisper arrived on", function()
  local a = newClient("Salahaja")
  local b = newClient("Salabeard")

  b:deliver("Salahaja", ">> Bobby: you around?")
  b:reply("yes, five minutes")
  b:drain()

  local asks = relayAsks(b, "Salahaja")
  if table.getn(asks) ~= 1 then
    error("sent " .. table.getn(asks) .. " requests, expected 1")
  end
  if not string.find(asks[1], "Bobby", 1, true) then
    error("the request does not name who to answer: " .. asks[1])
  end

  -- ...and the window it lands on says it, to Bobby, as itself.
  for _, m in ipairs(asks) do a:deliver("Salabeard", m) end
  a:drain()
  local said = toTarget(a, "Bobby")
  if table.getn(said) ~= 1 then
    error("Salahaja said " .. table.getn(said) .. " things to Bobby")
  end
  if said[1].text ~= "yes, five minutes" then
    error("Bobby received: " .. said[1].text)
  end
end)

--[[ The one that matters. Without the check this is a remote mouth: anyone
     who worked out the marker could have you whisper anything to anyone. ]]
step("a request from a stranger is refused", function()
  local a = newClient("Salahaja")
  local b = newClient("Salabeard")

  a:deliver("Stranger", ">@Victim~something I never said")
  a:drain()
  if table.getn(toTarget(a, "Victim")) > 0 then
    error("said it anyway: " .. toTarget(a, "Victim")[1].text)
  end
  local told = false
  for _, m in ipairs(a.chat) do
    if string.find(m, "not one of your windows", 1, true) then told = true end
  end
  if not told then error("ignored it silently") end
end)

step("a request from one of your own windows is honoured", function()
  local a = newClient("Salahaja")
  local b = newClient("Salabeard")
  a:deliver("Salabeard", ">@Bobby~on my way")
  a:drain()
  if table.getn(toTarget(a, "Bobby")) ~= 1 then
    error("refused a request from its own window")
  end
end)

step("with nothing forwarded yet it says so", function()
  local a = newClient("Salahaja")
  local b = newClient("Salabeard")
  a.chat = {}
  a:reply("hello?")
  a:drain()
  if table.getn(a.sent) > 0 then error("sent something with no context") end
  local told = false
  for _, m in ipairs(a.chat) do
    if string.find(m, "no forwarded whisper", 1, true) then told = true end
  end
  if not told then error("said nothing about why") end
end)

step("an empty message is refused", function()
  local a = newClient("Salahaja")
  local b = newClient("Salabeard")
  a:deliver("Salabeard", ">> Bobby: you around?")
  a.sent = {}
  a:reply("")
  a:drain()
  if table.getn(a.sent) > 0 then error("whispered an empty line") end
end)

--[[ A whisper that arrived here directly does not need a round trip; going
     through the relay would ask another window to say what this one can. ]]
step("answering a whisper that came here directly goes straight out", function()
  local a = newClient("Salahaja")
  local b = newClient("Salabeard")
  a:deliver("Salabeard", ">> Bobby: you around?")
  a.sent = {}
  -- Pretend it arrived on this character rather than via another window.
  a.WR.lastForward = { from = "Bobby", via = "Salahaja" }
  a:reply("right here")
  a:drain()

  local said = toTarget(a, "Bobby")
  if table.getn(said) ~= 1 then error("did not answer directly") end
  if said[1].text ~= "right here" then error("said: " .. said[1].text) end
  if table.getn(relayAsks(a, "Salabeard")) > 0 then
    error("asked another window to say what this one could")
  end
end)

step("a relay request is never forwarded onward", function()
  local a = newClient("Salahaja")
  local b = newClient("Salabeard")
  local c = newClient("Mahislap")
  b:deliver("Stranger", ">@Someone~text")
  b:drain()
  for _, m in ipairs(b.sent) do
    if m.target == "Salahaja" or m.target == "Mahislap" then
      error("relayed a relay request: " .. m.text)
    end
  end
end)

step("a message containing a separator survives the round trip", function()
  local a = newClient("Salahaja")
  local b = newClient("Salabeard")
  b:deliver("Salahaja", ">> Bobby: you around?")
  b:reply("use the ~ key, then run")
  b:drain()
  for _, m in ipairs(relayAsks(b, "Salahaja")) do a:deliver("Salabeard", m) end
  a:drain()
  local said = toTarget(a, "Bobby")
  if table.getn(said) ~= 1 or said[1].text ~= "use the ~ key, then run" then
    error("Bobby received: " .. (said[1] and said[1].text or "nothing"))
  end
end)

----------------------------------------------------------------------
-- talking in the party your other window is in
----------------------------------------------------------------------

local function sayAsks(c, target)
  local out = {}
  for _, m in ipairs(toTarget(c, target)) do
    if string.sub(m.text, 1, 2) == ">+" then table.insert(out, m.text) end
  end
  return out
end

local function channelLines(c, channel)
  local out = {}
  for _, m in ipairs(c.sent) do
    if m.chan == channel then table.insert(out, m.text) end
  end
  return out
end

--[[ Char A is in a party, you are sitting on char B, and A relays the party
     chat to B. Reading it without being able to answer is worse than not
     hearing it: you know a decision is being made and cannot join in. ]]
step("/wp puts your words in the party your other window is in", function()
  local a = newClient("Alpha")
  local b = newClient("Bravo")
  a:cmd("group")
  a.party = { "Bobby" }

  -- Alpha forwards a line of party chat to Bravo...
  a:fire("CHAT_MSG_PARTY", "who is tanking?", "Bobby")
  a:drain()
  local forwarded = toTarget(a, "Bravo")
  for _, m in ipairs(forwarded) do b:deliver("Alpha", m.text) end

  -- ...and Bravo answers into it.
  b:toParty("I'll tank")
  b:drain()
  local asks = sayAsks(b, "Alpha")
  if table.getn(asks) ~= 1 then
    error("sent " .. table.getn(asks) .. " requests, expected 1")
  end

  for _, m in ipairs(asks) do a:deliver("Bravo", m) end
  a:drain()
  local said = channelLines(a, "PARTY")
  if table.getn(said) ~= 1 then
    error("Alpha said " .. table.getn(said) .. " things in party")
  end
  if said[1] ~= "I'll tank" then error("the party heard: " .. said[1]) end
end)

step("in a raid it goes to raid chat, not party", function()
  local a = newClient("Alpha")
  local b = newClient("Bravo")
  a:cmd("group")
  a.raid = { "Bobby" }

  a:fire("CHAT_MSG_RAID", "positions", "Bobby")
  a:drain()
  for _, m in ipairs(toTarget(a, "Bravo")) do b:deliver("Alpha", m.text) end

  b:toParty("moving now")
  b:drain()
  for _, m in ipairs(sayAsks(b, "Alpha")) do a:deliver("Bravo", m) end
  a:drain()

  if table.getn(channelLines(a, "RAID")) ~= 1 then
    error("did not use raid chat")
  end
  if table.getn(channelLines(a, "PARTY")) > 0 then
    error("used party chat while in a raid")
  end
end)

--[[ The same rule as the whisper version, and for the same reason: without
     it this is a way to make somebody talk in a group they are in. ]]
step("a request from a stranger is refused", function()
  local a = newClient("Alpha")
  local b = newClient("Bravo")
  a.party = { "Bobby" }

  a:deliver("Stranger", ">+something I never said")
  a:drain()
  if table.getn(channelLines(a, "PARTY")) > 0 then
    error("said it anyway: " .. channelLines(a, "PARTY")[1])
  end
  local told = false
  for _, m in ipairs(a.chat) do
    if string.find(m, "not one of your windows", 1, true) then told = true end
  end
  if not told then error("ignored it silently") end
end)

step("a window that left the group says so rather than shouting into nothing", function()
  local a = newClient("Alpha")
  local b = newClient("Bravo")
  a.party = {}                        -- no longer grouped
  a.chat = {}

  a:deliver("Bravo", ">+are we going?")
  a:drain()
  if table.getn(a.sent) > 0 then
    error("sent something while in no group at all")
  end
  local told = false
  for _, m in ipairs(a.chat) do
    if string.find(m, "not in one", 1, true) then told = true end
  end
  if not told then error("said nothing about why") end
end)

step("with no group chat forwarded yet it says so", function()
  local a = newClient("Alpha")
  local b = newClient("Bravo")
  a.chat = {}
  a:toParty("hello?")
  a:drain()
  if table.getn(a.sent) > 0 then error("sent something with no group in mind") end
  local told = false
  for _, m in ipairs(a.chat) do
    if string.find(m, "no group chat", 1, true) then told = true end
  end
  if not told then error("said nothing about why") end
end)

step("an empty message is refused", function()
  local a = newClient("Alpha")
  local b = newClient("Bravo")
  a.WR.lastGroupFrom = "Bravo"
  a.sent = {}
  a:toParty("")
  a:drain()
  if table.getn(a.sent) > 0 then error("sent an empty line") end
end)

step("a say request is never forwarded onward", function()
  local a = newClient("Alpha")
  local b = newClient("Bravo")
  local c = newClient("Mahislap")
  b.party = { "Someone" }
  b:deliver("Stranger", ">+text")
  b:drain()
  for _, m in ipairs(b.sent) do
    if m.target == "Alpha" or m.target == "Mahislap" then
      error("relayed a say request: " .. m.text)
    end
  end
end)

----------------------------------------------------------------------
-- nothing we send may look like a chat substitution token
----------------------------------------------------------------------

--[[ Reported from the game: "/wp tanything" failed with "no target", and only
     sentences starting with t failed.

     The marker was ">%", so the whisper carrying the request began ">%t..." --
     and %t is WoW's token for your current target. The client expanded it,
     found nothing selected, and refused the message. Every other letter was
     fine, which is exactly what makes this the kind of bug you stare at. ]]
step("a relayed line beginning with t is not read as a target token", function()
  local a = newClient("Alpha")
  local b = newClient("Bravo")
  a:cmd("group")
  a.party = { "Bobby" }
  a:fire("CHAT_MSG_PARTY", "who is tanking?", "Bobby")
  a:drain()
  for _, m in ipairs(toTarget(a, "Bravo")) do b:deliver("Alpha", m.text) end

  b.sent = {}
  b:toParty("tanything")
  b:drain()

  local asks = sayAsks(b, "Alpha")
  if table.getn(asks) ~= 1 then error("nothing was sent at all") end
  if string.find(asks[1], "%%t") then
    error("the wire text contains a %t token: " .. asks[1])
  end

  for _, m in ipairs(asks) do a:deliver("Bravo", m) end
  a:drain()
  local said = channelLines(a, "PARTY")
  if table.getn(said) ~= 1 or said[1] ~= "tanything" then
    error("the party heard: " .. (said[1] or "nothing"))
  end
end)

step("the same for a whisper answered through another window", function()
  local a = newClient("Salahaja")
  local b = newClient("Salabeard")
  b:deliver("Salahaja", ">> Bobby: you around?")
  b.sent = {}
  b:reply("ten minutes")
  b:drain()

  local asks = relayAsks(b, "Salahaja")
  if table.getn(asks) ~= 1 then error("nothing was sent") end
  if string.find(asks[1], "%%t") then
    error("the wire text contains a %t token: " .. asks[1])
  end
end)

--[[ A guard rather than a test of behaviour: every marker is two characters
     that go out at the front of a whisper, so any of them ending in % would
     make the next letter a substitution token. ]]
step("no marker can turn the next letter into a token", function()
  local client = newClient("Alpha")
  local seen = {}
  for _, probe in ipairs({ ">> Bobby: t", ">! t", ">#P~Bobby~t" }) do
    table.insert(seen, probe)
  end
  for _, text in ipairs(seen) do
    if string.find(text, "%%") then
      error("a marker contains a percent sign: " .. text)
    end
  end

  -- And the three that carry a request, built the way the addon builds them.
  local a = newClient("Alpha")
  local b = newClient("Bravo")
  a.WR.lastGroupFrom = "Bravo"
  a.WR.lastGuildFrom = "Bravo"
  a.WR.lastForward = { from = "Bobby", via = "Bravo" }
  a.sent = {}
  a:toParty("t")
  a:toGuild("t")
  a:reply("t")
  a:drain()
  if table.getn(a.sent) ~= 3 then error("expected three requests, sent " .. table.getn(a.sent)) end
  for _, m in ipairs(a.sent) do
    if string.find(m.text, "%%") then
      error("an outgoing request contains a percent sign: " .. m.text)
    end
  end
end)

----------------------------------------------------------------------
-- the relay window
----------------------------------------------------------------------

local function chatWindow(c) return c.byName["WhisperRelayChat"] end
local function chatBox(c) return c.byName["WhisperRelayChatBox"] end

local function windowLines(c)
  local w = chatWindow(c)
  return (w and w.log and w.log.lines) or {}
end

step("/wf chat opens a window with what has already arrived", function()
  local b = newClient("Salabeard")
  -- Kept shut until asked for, or the whisper would open it by itself.
  b:cmd("autoopen")
  b:deliver("Salahaja", ">> Bobby: you around?")
  b:cmd("chat")

  local w = chatWindow(b)
  if not w then error("no window was built") end
  if not w:IsShown() then error("built but not shown") end

  local found = false
  for _, l in ipairs(windowLines(b)) do
    if string.find(l, "you around?", 1, true) then found = true end
  end
  if not found then error("opened empty: " .. table.concat(windowLines(b), " | ")) end
end)

step("things arriving afterwards appear in it", function()
  local b = newClient("Salabeard")
  b:cmd("chat")
  b:deliver("Salahaja", ">> Bobby: still there?")

  local found = false
  for _, l in ipairs(windowLines(b)) do
    if string.find(l, "still there?", 1, true) then found = true end
  end
  if not found then error("the window did not update") end
end)

step("group chat and queue pops land in it too", function()
  local b = newClient("Salabeard")
  b:cmd("chat")
  b:deliver("Salahaja", ">#P~Bobby~pull in 10")
  b:deliver("Salahaja", ">! Warsong Gulch is ready to join")

  local sawGroup, sawAlert = false, false
  for _, l in ipairs(windowLines(b)) do
    if string.find(l, "pull in 10", 1, true) then sawGroup = true end
    if string.find(l, "Warsong Gulch", 1, true) then sawAlert = true end
  end
  if not sawGroup then error("group chat did not reach the window") end
  if not sawAlert then error("the alert did not reach the window") end
end)

--[[ The reason the window exists: answering meant choosing between /wr and
     /wp per message. Here it goes wherever the last thing came from. ]]
step("typing answers a whisper as the character they wrote to", function()
  local a = newClient("Salahaja")
  local b = newClient("Salabeard")
  b:deliver("Salahaja", ">> Bobby: you around?")
  b:cmd("chat")

  b.sent = {}
  local e = chatBox(b)
  e:SetText("five minutes")
  e.scripts.OnEnterPressed()
  b:drain()

  local asks = relayAsks(b, "Salahaja")
  if table.getn(asks) ~= 1 then
    error("sent " .. table.getn(asks) .. " requests, expected 1")
  end
  if not string.find(asks[1], "five minutes", 1, true) then
    error("sent: " .. asks[1])
  end
  if e:GetText() ~= "" then error("the box kept the text after sending") end
end)

step("and answers the group when that is what last arrived", function()
  local a = newClient("Alpha")
  local b = newClient("Bravo")
  b:cmd("chat")
  b:deliver("Alpha", ">#P~Bobby~who is tanking?")

  b.sent = {}
  local e = chatBox(b)
  e:SetText("I'll tank")
  e.scripts.OnEnterPressed()
  b:drain()

  if table.getn(sayAsks(b, "Alpha")) ~= 1 then
    error("did not answer into the group")
  end
end)

step("the window says where the reply will go before you send it", function()
  local a = newClient("Alpha")
  local b = newClient("Bravo")
  b:cmd("chat")
  b:deliver("Alpha", ">#P~Bobby~who is tanking?")

  local said = chatWindow(b).target:GetText()
  if not string.find(said, "group", 1, true) then
    error("it says: " .. said)
  end
end)

--[[ Both can be live at once, and the last thing to arrive is not always the
     one you meant to answer. ]]
step("switch flips between the group and the whisper", function()
  local a = newClient("Salahaja")
  local b = newClient("Salabeard")
  b:cmd("chat")
  b:deliver("Salahaja", ">> Bobby: you around?")
  b:deliver("Salahaja", ">#P~Charlie~pull in 10")

  local before = chatWindow(b).target:GetText()
  if not string.find(before, "group", 1, true) then
    error("expected the group first: " .. before)
  end

  b.WR.ToggleChatDestination()
  local after = chatWindow(b).target:GetText()
  if not string.find(after, "Bobby", 1, true) then
    error("switching did not move to the whisper: " .. after)
  end

  b.sent = {}
  local e = chatBox(b)
  e:SetText("on my way")
  e.scripts.OnEnterPressed()
  b:drain()
  if table.getn(relayAsks(b, "Salahaja")) ~= 1 then
    error("sent to the group after switching to the whisper")
  end
end)

step("with nothing relayed it says so rather than guessing", function()
  local a = newClient("Salahaja")
  local b = newClient("Salabeard")
  b:cmd("chat")
  local said = chatWindow(b).target:GetText()
  if not string.find(said, "nothing", 1, true) then
    error("it says: " .. said)
  end

  b.sent = {}
  local e = chatBox(b)
  e:SetText("hello?")
  e.scripts.OnEnterPressed()
  b:drain()
  if table.getn(b.sent) > 0 then error("sent it somewhere anyway") end
end)

step("an empty line sends nothing", function()
  local a = newClient("Salahaja")
  local b = newClient("Salabeard")
  b:deliver("Salahaja", ">> Bobby: you around?")
  b:cmd("chat")
  b.sent = {}
  local e = chatBox(b)
  e:SetText("")
  e.scripts.OnEnterPressed()
  b:drain()
  if table.getn(b.sent) > 0 then error("sent an empty line") end
end)

step("/wf chat closes it again", function()
  local b = newClient("Salabeard")
  b:cmd("chat")
  b:cmd("chat")
  if chatWindow(b):IsShown() then error("did not close") end
end)

--[[ It has to remember while closed, or the first thing you do after opening
     it is scroll back through chat looking for what you missed. ]]
step("it keeps a history while closed, and does not grow forever", function()
  local b = newClient("Salabeard")
  for i = 1, 120 do
    b:deliver("Salahaja", ">> Bobby: message " .. i)
  end
  if table.getn(b.WR.chatLog) > 60 then
    error("kept " .. table.getn(b.WR.chatLog) .. " lines")
  end
  b:cmd("chat")
  local lines = windowLines(b)
  if table.getn(lines) == 0 then error("opened empty after all that") end
end)

step("the window is not the event frame or the popup", function()
  local b = newClient("Salabeard")
  b:cmd("chat")
  if chatWindow(b) == b.frame then error("it replaced the event frame") end
  b:deliver("Salahaja", ">> Bobby: still here?")
  local ok = false
  for _, m in ipairs(b.chat) do
    if string.find(m, "still here?", 1, true) then ok = true end
  end
  if not ok then error("the addon stopped handling whispers") end
end)

----------------------------------------------------------------------
-- every line says which character it reached
----------------------------------------------------------------------

--[[ With four windows talking, the first fact you need is WHICH of your
     characters a line arrived on. In the normal chat frame that is trailing
     off the end of a whisper as "(via Salahaja)"; in the window it leads. ]]
step("a whisper line leads with the character it arrived on", function()
  local b = newClient("Salabeard")
  b:cmd("chat")
  b:deliver("Salahaja", ">> Bobby: you around?")

  local line
  for _, l in ipairs(windowLines(b)) do
    if string.find(l, "you around?", 1, true) then line = l end
  end
  if not line then error("nothing in the window") end

  local whereChar = string.find(line, "Salahaja", 1, true)
  local whereFrom = string.find(line, "Bobby", 1, true)
  if not whereChar then error("the line never names the character: " .. line) end
  if whereChar > whereFrom then
    error("the character comes after the sender: " .. line)
  end
  if not string.find(line, "|Hplayer:Bobby|h", 1, true) then
    error("the sender is not clickable: " .. line)
  end
end)

step("a group line does the same, and says which channel", function()
  local b = newClient("Salabeard")
  b:cmd("chat")
  b:deliver("Salahaja", ">#R~Charlie~healers up")

  local line
  for _, l in ipairs(windowLines(b)) do
    if string.find(l, "healers up", 1, true) then line = l end
  end
  if not line then error("nothing in the window") end
  if string.find(line, "Salahaja", 1, true) > string.find(line, "Charlie", 1, true) then
    error("the character comes after the speaker: " .. line)
  end
  if not string.find(line, "Raid", 1, true) then
    error("the line does not say which channel: " .. line)
  end
end)

step("an alert says which window it popped on", function()
  local b = newClient("Salabeard")
  b:cmd("chat")
  b:deliver("Salahaja", ">! Warsong Gulch is ready to join")

  local line
  for _, l in ipairs(windowLines(b)) do
    if string.find(l, "Warsong", 1, true) then line = l end
  end
  if not line or not string.find(line, "Salahaja", 1, true) then
    error("the alert does not name the window: " .. tostring(line))
  end
end)

--[[ What you send is shown as the character that will actually say it, not as
     whoever typed it -- that being the entire point of sending it through. ]]
step("your own reply is shown as the character saying it", function()
  local a = newClient("Salahaja")
  local b = newClient("Salabeard")
  b:cmd("chat")
  b:deliver("Salahaja", ">> Bobby: you around?")

  local e = chatBox(b)
  e:SetText("five minutes")
  e.scripts.OnEnterPressed()

  local line
  for _, l in ipairs(windowLines(b)) do
    if string.find(l, "five minutes", 1, true) then line = l end
  end
  if not line then error("what you sent is not in the window") end
  if not string.find(line, "Salahaja", 1, true) then
    error("it does not say who will say it: " .. line)
  end
  if string.find(line, "Salabeard", 1, true) then
    error("it names the character that typed it instead: " .. line)
  end
end)

step("talking to the group shows as that window talking", function()
  local a = newClient("Alpha")
  local b = newClient("Bravo")
  b:cmd("chat")
  b:deliver("Alpha", ">#P~Bobby~who is tanking?")

  local e = chatBox(b)
  e:SetText("I'll tank")
  e.scripts.OnEnterPressed()

  local line
  for _, l in ipairs(windowLines(b)) do
    if string.find(l, "I'll tank", 1, true) then line = l end
  end
  if not line then error("what you sent is not in the window") end
  if not string.find(line, "Alpha", 1, true) then
    error("it does not name the window that will say it: " .. line)
  end
end)

step("lines from two different windows are told apart", function()
  local a = newClient("Alpha")
  local b = newClient("Bravo")
  local c = newClient("Charlie")
  c:cmd("chat")
  c:deliver("Alpha", ">> Bobby: from the first window")
  c:deliver("Bravo", ">> Bobby: from the second")

  local sawA, sawB = false, false
  for _, l in ipairs(windowLines(c)) do
    if string.find(l, "from the first window", 1, true)
       and string.find(l, "Alpha", 1, true) then sawA = true end
    if string.find(l, "from the second", 1, true)
       and string.find(l, "Bravo", 1, true) then sawB = true end
  end
  if not (sawA and sawB) then
    error("could not tell them apart: " .. table.concat(windowLines(c), " | "))
  end
end)

----------------------------------------------------------------------
-- tabs, and resizing
----------------------------------------------------------------------

local function tabFor(c, key)
  local w = chatWindow(c)
  for _, t in ipairs((w and w.tabs) or {}) do
    if t.key == key then return t end
  end
  return nil
end

local function lineWith(c, text)
  for _, l in ipairs(windowLines(c)) do
    if string.find(l, text, 1, true) then return l end
  end
  return nil
end

--[[ The actual complaint: whispers and party chat arrive at different rates
     about different things, and the one you are watching is rarely the one
     filling the window. ]]
step("the Whispers tab shows whispers and not party chat", function()
  local b = newClient("Salabeard")
  b:cmd("chat")
  b:deliver("Salahaja", ">> Bobby: you around?")
  b:deliver("Salahaja", ">#P~Charlie~pull in 10")

  b:click(tabFor(b, "whisper"))
  if not lineWith(b, "you around?") then error("the whisper is missing") end
  if lineWith(b, "pull in 10") then error("party chat leaked into Whispers") end
end)

step("the Party tab shows party chat and not whispers", function()
  local b = newClient("Salabeard")
  b:cmd("chat")
  b:deliver("Salahaja", ">> Bobby: you around?")
  b:deliver("Salahaja", ">#P~Charlie~pull in 10")

  b:click(tabFor(b, "group"))
  if not lineWith(b, "pull in 10") then error("the party line is missing") end
  if lineWith(b, "you around?") then error("a whisper leaked into Party") end
end)

step("All still shows everything, alerts included", function()
  local b = newClient("Salabeard")
  b:cmd("chat")
  b:deliver("Salahaja", ">> Bobby: you around?")
  b:deliver("Salahaja", ">#P~Charlie~pull in 10")
  b:deliver("Salahaja", ">! Warsong Gulch is ready to join")

  b:click(tabFor(b, "all"))
  if not lineWith(b, "you around?") then error("no whisper on All") end
  if not lineWith(b, "pull in 10") then error("no party line on All") end
  if not lineWith(b, "Warsong") then error("no alert on All") end
end)

--[[ The tab decides where Enter goes. That is most of the point of having
     them: on Whispers you are answering the whisper, full stop. ]]
step("the tab decides where a reply goes", function()
  local a = newClient("Salahaja")
  local b = newClient("Salabeard")
  b:cmd("chat")
  b:deliver("Salahaja", ">> Bobby: you around?")
  b:deliver("Salahaja", ">#P~Charlie~pull in 10")

  -- Party arrived last, so All would answer the group. The tab overrides it.
  b:click(tabFor(b, "whisper"))
  b.sent = {}
  local e = chatBox(b)
  e:SetText("five minutes")
  e.scripts.OnEnterPressed()
  b:drain()
  if table.getn(relayAsks(b, "Salahaja")) ~= 1 then
    error("answered the group while on the Whispers tab")
  end

  b:click(tabFor(b, "group"))
  b.sent = {}
  e:SetText("on my way")
  e.scripts.OnEnterPressed()
  b:drain()
  if table.getn(sayAsks(b, "Salahaja")) ~= 1 then
    error("answered the whisper while on the Party tab")
  end
end)

step("your own reply lands on the tab it answers", function()
  local a = newClient("Salahaja")
  local b = newClient("Salabeard")
  b:cmd("chat")
  b:deliver("Salahaja", ">> Bobby: you around?")

  b:click(tabFor(b, "whisper"))
  local e = chatBox(b)
  e:SetText("five minutes")
  e.scripts.OnEnterPressed()
  if not lineWith(b, "five minutes") then
    error("what you sent is not beside the whisper it answers")
  end
end)

step("a tab with nothing in it says so rather than guessing", function()
  local a = newClient("Salahaja")
  local b = newClient("Salabeard")
  b:cmd("chat")
  b:deliver("Salahaja", ">> Bobby: you around?")

  b:click(tabFor(b, "group"))
  local said = chatWindow(b).target:GetText()
  if not string.find(said, "no group chat", 1, true) then
    error("it says: " .. said)
  end

  b.sent = {}
  local e = chatBox(b)
  e:SetText("hello?")
  e.scripts.OnEnterPressed()
  b:drain()
  if table.getn(b.sent) > 0 then
    error("answered the whisper from the empty Party tab")
  end
end)

--[[ Something arriving on a tab you are not watching is the case tabs create
     and have to answer for. ]]
step("a tab you are not on says something arrived", function()
  local b = newClient("Salabeard")
  b:cmd("chat")
  b:click(tabFor(b, "whisper"))
  b:deliver("Salahaja", ">#P~Charlie~pull in 10")

  if not (b.WR.chatUnread and b.WR.chatUnread["group"]) then
    error("nothing marked the Party tab")
  end
  b:click(tabFor(b, "group"))
  if b.WR.chatUnread["group"] then
    error("the mark survived looking at the tab")
  end
end)

step("switch is only offered where the tab is not deciding", function()
  local a = newClient("Salahaja")
  local b = newClient("Salabeard")
  b:cmd("chat")
  b:deliver("Salahaja", ">> Bobby: you around?")

  b:click(tabFor(b, "all"))
  if not chatWindow(b).swap:IsShown() then
    error("switch is hidden on All, where it is the only way to choose")
  end
  b:click(tabFor(b, "whisper"))
  if chatWindow(b).swap:IsShown() then
    error("switch is offered on a tab that already decides")
  end
end)

step("the window can be resized, and remembers it", function()
  local b = newClient("Salabeard")
  b:cmd("chat")
  local w = chatWindow(b)
  if not w.grip then error("no resize grip") end

  w:SetWidth(600)
  w:SetHeight(400)
  w.grip.scripts.OnDragStop()
  if b.WR.config.chatW ~= 600 or b.WR.config.chatH ~= 400 then
    error("the size was not remembered: " ..
      tostring(b.WR.config.chatW) .. "x" .. tostring(b.WR.config.chatH))
  end

  -- A later session builds it at the size you left it.
  b.WR.chatFrame = nil
  local rebuilt = b.WR.BuildChat()
  if rebuilt:GetWidth() ~= 600 then
    error("rebuilt at " .. tostring(rebuilt:GetWidth()) .. " wide")
  end
end)

step("every tab renders without erroring", function()
  local a = newClient("Salahaja")
  local b = newClient("Salabeard")
  b:cmd("chat")
  b:deliver("Salahaja", ">> Bobby: one")
  b:deliver("Salahaja", ">#R~Charlie~two")
  b:deliver("Salahaja", ">! three")
  for _ = 1, 2 do
    for _, key in ipairs({ "all", "whisper", "group" }) do
      b:click(tabFor(b, key))
    end
  end
end)

----------------------------------------------------------------------
-- setting the wording is not asking for it to be said
----------------------------------------------------------------------

--[[ /wf reply <text> used to switch the answering on as a side effect, so
     trying out a message quietly started sending it to people. Deciding what
     it WOULD say is not the same as asking for it to be said. ]]
step("writing the wording does not start answering people", function()
  local a = newClient("Salahaja")
  local b = newClient("Salabeard")
  a:cmd("reply here is my wording for {char}")
  if a.WR.config.autoReply then
    error("setting the wording switched answering on")
  end

  a:deliver("Bobby", "you around?")
  a:drain()
  if table.getn(toTarget(a, "Bobby")) > 0 then
    error("answered Bobby: " .. toTarget(a, "Bobby")[1].text)
  end
end)

step("but it is kept, and used once you ask for it", function()
  local a = newClient("Salahaja")
  local b = newClient("Salabeard")
  a:cmd("reply here is my wording for {char}")
  a:cmd("reply on")
  a:deliver("Bobby", "you around?")
  a:drain()
  local back = toTarget(a, "Bobby")
  if table.getn(back) ~= 1 then error("did not answer once asked") end
  if back[1].text ~= "here is my wording for Salabeard" then
    error("Bobby received: " .. back[1].text)
  end
end)

step("and it says answering is still off when it is", function()
  local a = newClient("Salahaja")
  a.chat = {}
  a:cmd("reply something new")
  local told = false
  for _, m in ipairs(a.chat) do
    if string.find(m, "still off", 1, true) then told = true end
  end
  if not told then error("changed the wording without saying it is unused") end
end)

----------------------------------------------------------------------
-- /wf lists everything it can do
----------------------------------------------------------------------

--[[ A command list you have to already know the name of is not discovery.
     Every command the handler accepts has to appear in it, or it is a feature
     nobody finds -- which had already happened to the chat window. ]]
step("a bare /wf lists every command the handler accepts", function()
  local a = newClient("Salahaja")
  a.chat = {}
  a:cmd("")

  local printed = table.concat(a.chat, "\n")
  local missing = {}
  for _, cmd in ipairs({ "chat", "config", "status", "auto", "to", "list",
                         "forget", "on", "off", "reply", "every", "group",
                         "alerts", "popup", "inline", "link", "echo",
                         "quiet", "autoopen", "minimap", "guild",
                         "demo", "testpop", "test" }) do
    if not string.find(printed, "/wf " .. cmd, 1, true) then
      table.insert(missing, cmd)
    end
  end
  -- The three that are not /wf commands at all.
  for _, cmd in ipairs({ "/wr ", "/wp ", "/wg " }) do
    if not string.find(printed, cmd, 1, true) then
      table.insert(missing, cmd)
    end
  end

  if table.getn(missing) > 0 then
    error("not listed: " .. table.concat(missing, ", "))
  end
end)

step("and shows the current state above it", function()
  local a = newClient("Salahaja")
  local b = newClient("Salabeard")
  a.chat = {}
  a:cmd("")
  local printed = table.concat(a.chat, "\n")
  if not string.find(printed, "Salabeard", 1, true) then
    error("no state shown: " .. printed)
  end
end)

step("/wf status is the state on its own", function()
  local a = newClient("Salahaja")
  a.chat = {}
  a:cmd("status")
  local printed = table.concat(a.chat, "\n")
  if string.find(printed, "/wf testpop", 1, true) then
    error("/wf status printed the whole command list")
  end
end)

step("an unknown command still gets the list", function()
  local a = newClient("Salahaja")
  a.chat = {}
  a:cmd("nonsense")
  if not string.find(table.concat(a.chat, "\n"), "/wf chat", 1, true) then
    error("said nothing useful about an unknown command")
  end
end)

----------------------------------------------------------------------
-- the quiet channel
----------------------------------------------------------------------

print("\n  the quiet channel: your windows, without whispers\n")

--- A window with the quiet channel on, as it ships. `db` to come back from a
--- /reload, `machine` for one on another PC.
local function quietClient(name, db, machine)
  return newClient(name, { quiet = true, db = db, machine = machine })
end

local function shown(c) return table.concat(c.chat, "\n") end
local function whisperedTo(c, target) return #toTarget(c, target) end

--- How many chat lines show `text`.
local function times(c, text)
  local n = 0
  for _, line in ipairs(c.chat) do
    if string.find(line, text, 1, true) then n = n + 1 end
  end
  return n
end

--- The addon messages a window sent to `to`, as their text.
local function addonTo(c, to)
  local out = {}
  for _, m in ipairs(c.addonSent) do
    if m.prefix == "TW_CHAT_MSG_WHISPER<" .. to .. ">" then table.insert(out, m.text) end
  end
  return out
end

--- Of those, the ones that carried a message rather than a hello or an answer.
local function carried(c, to)
  local out = {}
  for _, text in ipairs(addonTo(c, to)) do
    local kind = string.sub(text, 4, 4)
    if kind == "m" or kind == "c" then table.insert(out, text) end
  end
  return out
end

local function sentKind(c, to, whole)
  local n = 0
  for _, text in ipairs(addonTo(c, to)) do
    if text == whole then n = n + 1 end
  end
  return n
end

--- Frames on each window given, long enough for every hello to be answered.
local function settle(...)
  for _ = 1, 5 do
    for _, c in ipairs({ ... }) do c:tick(1) end
  end
end

step("quiet: a forward to another window is an addon message, not a whisper", function()
  local a = quietClient("Salahaja")
  local b = quietClient("Salabeard")
  a:deliver("Bobby", "you around?")
  a:drain()
  if whisperedTo(a, "Salabeard") > 0 then error("whispered the other window") end
  if #carried(a, "Salabeard") ~= 1 then
    error(#carried(a, "Salabeard") .. " addon messages carried it, not 1")
  end
  for _, m in ipairs(a.addonSent) do
    if m.chan ~= "GUILD" then
      error("sent on " .. tostring(m.chan) .. ", which the server does not route")
    end
  end
  if times(b, "you around?") ~= 1 then error("the other window did not show it once: " .. shown(b)) end
  if not string.find(shown(b), "|Hplayer:Bobby|h", 1, true) then
    error("Bobby's name is not clickable: " .. shown(b))
  end
  if b.sounds < 1 then error("it arrived without a sound") end
end)

step("quiet: nothing sent has a > in it, and it arrives exactly as said", function()
  local a = quietClient("Salahaja")
  local b = quietClient("Salabeard")
  local said = "5 > 4 & |cff1eff00|Hitem:2589:0:0:0|h[Linen Cloth]|h|r LFT tank_spot 100%"
  a:deliver("Bobby", said)
  a:drain()
  for _, m in ipairs(a.addonSent) do
    for _, bad in ipairs({ ">", "|", "_", "LFT" }) do
      if string.find(m.text, bad, 1, true) then error("sent " .. bad .. " in: " .. m.text) end
    end
  end
  if #net.refused > 0 then error("the server refused: " .. net.refused[1]) end
  if not string.find(shown(b), said, 1, true) then error("it arrived changed: " .. shown(b)) end
end)

step("quiet: a long message goes in pieces and arrives whole, once", function()
  local a = quietClient("Salahaja")
  local b = quietClient("Salabeard")
  local long = string.rep("abcdefghi>", 23)   -- 230 characters, 23 of them escaped
  local next_ = string.rep("jklmnopqr>", 23)
  a:deliver("Bobby", long)
  a:drain()
  if #carried(a, "Salabeard") < 2 then error("not cut into pieces") end
  if times(b, long) ~= 1 then error("did not arrive whole, once: " .. shown(b)) end
  a:deliver("Bobby", next_)
  a:drain()
  if times(b, next_) ~= 1 then error("the next one did not arrive whole, once") end
  for _, line in ipairs(b.chat) do
    if string.find(line, "abcdefghi", 1, true) and string.find(line, "jklmnopqr", 1, true) then
      error("the next message came with pieces of the last")
    end
  end
end)

step("quiet: a piece never ends inside a letter", function()
  local a = quietClient("Salahaja")
  local b = quietClient("Salabeard")
  local long = string.rep("\195\182", 110)    -- o-umlaut: two bytes a letter
  a:deliver("Bobbyx", long)
  a:drain()
  local pieces = carried(a, "Salabeard")
  if #pieces < 2 then error("not cut into pieces") end
  for _, text in ipairs(pieces) do
    local body = string.sub(text, 5)
    if string.find(body, "^[\128-\191]") then error("a piece starts inside a letter") end
    if string.find(body, "[\192-\255]$") then error("a piece ends inside a letter") end
  end
  if times(b, long) ~= 1 then error("did not arrive whole") end
end)

step("quiet: /wr answers through the addon channel; only the real reply is a whisper", function()
  local a = quietClient("Salahaja")
  local b = quietClient("Salabeard")
  a:deliver("Bobby", "you around?")
  a:drain()
  b:reply("five minutes")
  b:drain()
  if whisperedTo(b, "Salahaja") > 0 then error("whispered the other window to ask it") end
  local said = toTarget(a, "Bobby")
  if #said ~= 1 or said[1].text ~= "five minutes" then
    error("Bobby did not get the answer from Salahaja")
  end
end)

step("quiet: party chat and /wp go through the addon channel", function()
  local a = quietClient("Alpha")
  local b = quietClient("Bravo")
  a:cmd("group")
  a.party = { "Bobby", "Charlie" }
  a:fire("CHAT_MSG_PARTY", "pull in 10", "Bobby")
  a:drain()
  if whisperedTo(a, "Bravo") > 0 then error("whispered party chat to the other window") end
  if times(b, "pull in 10") < 1 then error("the party line never arrived: " .. shown(b)) end
  b:toParty("coming")
  b:drain()
  if whisperedTo(b, "Alpha") > 0 then error("whispered the other window to say it") end
  local party = {}
  for _, m in ipairs(a.sent) do
    if m.chan == "PARTY" then table.insert(party, m.text) end
  end
  if #party ~= 1 or party[1] ~= "coming" then error("the party did not hear it") end
end)

step("quiet: a queue pop goes through the addon channel", function()
  local a = quietClient("Salahaja")
  local b = quietClient("Salabeard")
  a.queues[1] = { status = "confirm", map = "Warsong Gulch" }
  a:fire("UPDATE_BATTLEFIELD_STATUS")
  a:drain()
  if #alerts(a, "Salabeard") > 0 then error("whispered the pop") end
  if not string.find(shown(b), "Warsong Gulch", 1, true) then error("the pop never arrived") end
end)

step("quiet: the sender's auto-answer is a whisper, even to someone running this", function()
  local a = quietClient("Salahaja")
  local b = quietClient("Salabeard")
  quietClient("Bobby", nil, "far")
  a:cmd("reply on")
  a:deliver("Bobby", "hi")
  a:drain()
  if whisperedTo(a, "Bobby") ~= 1 then error("Bobby was not answered") end
  if #addonTo(a, "Bobby") > 0 then
    error("sent Bobby an addon message, which Bobby would never see")
  end
  if #carried(a, "Salabeard") ~= 1 then error("and the forward itself did not go quietly") end
end)

step("quiet: a window not running this is whispered, after a moment to answer", function()
  local a = quietClient("Salahaja")
  net.online["Oldcopy"] = true               -- logged in, no addon to answer
  a:cmd("to Oldcopy")
  a:deliver("Bobby", "hello")
  a:tick(1)
  if whisperedTo(a, "Oldcopy") > 0 then error("whispered before it had a chance to answer") end
  a:drain()
  if whisperedTo(a, "Oldcopy") ~= 1 then error("never whispered it") end
  if #carried(a, "Oldcopy") > 0 then error("sent the message itself as an addon message") end
end)

step("quiet: a window with quiet off says so, and is whispered without the wait", function()
  local a = quietClient("Salahaja")
  newClient("Salabeard")                     -- quiet off
  a:deliver("Bobby", "hi")
  a:tick(1)
  if whisperedTo(a, "Salabeard") ~= 1 then
    error("waited out the full time for a window that had said no")
  end
end)

step("quiet: one window's wait holds up nobody else's messages", function()
  local a = quietClient("Salahaja")
  local b = quietClient("Salabeard")
  settle(a, b)
  net.online["Oldcopy"] = true
  -- The newer heartbeat, so its message is first in the queue.
  files["WhisperRelay_presence.txt"] = files["WhisperRelay_presence.txt"] ..
    "P~Oldcopy~" .. (clock.t + 1) .. "\n"
  a:deliver("Bobby", "to both")
  a:tick(1)
  if times(b, "to both") ~= 1 then error("Salabeard waited on Oldcopy's answer") end
  if whisperedTo(a, "Oldcopy") > 0 then error("Oldcopy was not given its moment") end
  a:drain()
  if whisperedTo(a, "Oldcopy") ~= 1 then error("Oldcopy was never whispered") end
end)

step("quiet: a window that did not answer is asked again a minute later", function()
  local a = quietClient("Salahaja")
  net.online["Oldcopy"] = true
  a:cmd("to Oldcopy")
  a:deliver("Bobby", "one")
  a:drain()
  a:tick(61)
  a:deliver("Bobby", "two")
  a:tick(1)
  if sentKind(a, "Oldcopy", "WRqh") < 2 then error("never asked again") end
  if whisperedTo(a, "Oldcopy") ~= 2 then error("held the second message up for the question") end
end)

step("quiet: /wf to asks the new window straight away", function()
  local a = quietClient("Salahaja")
  quietClient("Salabeard", nil, "laptop")
  a:cmd("to Salabeard")
  if sentKind(a, "Salabeard", "WRqh") < 1 then error("did not ask") end
end)

step("quiet: a named window on another PC is reached without whispers too", function()
  local a = quietClient("Salahaja", { auto = false, target = "Laptopper" })
  local l = quietClient("Laptopper", nil, "laptop")
  a:deliver("Bobby", "on the laptop?")
  a:drain()
  if whisperedTo(a, "Laptopper") > 0 then error("whispered the laptop") end
  if times(l, "on the laptop?") ~= 1 then error("the laptop never showed it") end
end)

step("quiet: a window that logs in after being asked is asked again, not whispered", function()
  local a = quietClient("Salahaja", { auto = false, target = "Laptopper" })
  a:tick(1)                                  -- the hello finds nobody yet
  a:tick(5)
  local l = quietClient("Laptopper", nil, "laptop")
  a:deliver("Bobby", "you on now?")
  a:drain()
  if whisperedTo(a, "Laptopper") > 0 then error("whispered it, having asked before it logged in") end
  if times(l, "you on now?") ~= 1 then error("it never arrived") end
end)

step("quiet: a window that logs out says so, and is not sent to after it", function()
  local a = quietClient("Salahaja")
  local b = quietClient("Salabeard")
  settle(a, b)
  b:logout()
  if sentKind(b, "Salahaja", "WRqb") ~= 1 then error("logged out without a word") end
  a.chat = {}
  a:deliver("Bobby", "hi")
  a:drain()
  if #carried(a, "Salabeard") > 0 then error("sent it to a window that had logged out") end
  if whisperedTo(a, "Salabeard") ~= 1 then error("and did not whisper it either") end
  if string.find(shown(a), "not delivered", 1, true) then
    error("reported a loss when only a hello went astray")
  end
end)

step("quiet: a window gone without a word: the lost message is reported", function()
  local a = quietClient("Salahaja")
  local b = quietClient("Salabeard")
  settle(a, b)
  net.online["Salabeard"] = nil              -- crashed: no goodbye
  a.chat = {}
  a:deliver("Bobby", "into the void")
  a:drain()
  if not string.find(shown(a), "Salabeard is not online", 1, true) then
    error("lost it without a word: " .. shown(a))
  end
end)

step("quiet: a /reload over there: asked afresh, nothing shown twice or lost", function()
  local a = quietClient("Salahaja")
  local b = quietClient("Salabeard")
  a:deliver("Bobby", "before")
  a:drain()
  b:fire("PLAYER_LOGOUT")                    -- a /reload: logged in throughout
  local b2 = quietClient("Salabeard", b.env.WhisperRelayDB)
  b2.chat = {}
  a:deliver("Bobby", "after")
  a:drain()
  if times(b2, "before") > 0 then error("shown again after the reload") end
  if times(b2, "after") ~= 1 then error("what came after was not shown once: " .. shown(b2)) end
  if whisperedTo(a, "Salabeard") > 0 then error("whispered it") end
end)

step("quiet: nothing that arrives over the addon channel is forwarded on", function()
  local a = quietClient("Salahaja")
  local b = quietClient("Salabeard")
  a:deliver("Bobby", "no bouncing")
  a:drain()
  b:drain()
  if whisperedTo(b, "Salahaja") > 0 or #carried(b, "Salahaja") > 0 then
    error("the forward went round again")
  end
end)

step("quiet: a stranger cannot use it to make you whisper anyone", function()
  local a = quietClient("Salahaja")
  local b = quietClient("Salabeard")
  settle(a, b)
  a:fire("CHAT_MSG_ADDON", "TW_CHAT_MSG_WHISPER",
    "\tWRqm" .. a.WR.Encode(">@Victim~give me gold"), "GUILD", "Evil")
  a:drain()
  if whisperedTo(a, "Victim") > 0 then error("whispered someone for a stranger") end
end)

step("quiet: pieces that never end do not pile up", function()
  local a = quietClient("Salahaja")
  for _ = 1, 50 do
    a:fire("CHAT_MSG_ADDON", "TW_CHAT_MSG_WHISPER", "\tWRqc" .. string.rep("x", 200),
      "GUILD", "Evil")
  end
  local held = a.WR.partial["evil"] or ""
  if string.len(held) > 2400 then error("holding " .. string.len(held) .. " characters for a stranger") end
end)

step("quiet: another addon's 'not found' is not our business", function()
  local a = quietClient("Salahaja")
  a.chat = {}
  a:fire("CHAT_MSG_ADDON", "TW_CHAT_MSG_WHISPER", "Error:CantFindPlayer:Somebody",
    "GUILD", "Salahaja")
  a:tick(1)
  if shown(a) ~= "" then error("said something: " .. shown(a)) end
end)

step("quiet: /wf quiet off goes back to whispers, and tells the other window", function()
  local a = quietClient("Salahaja")
  local b = quietClient("Salabeard")
  settle(a, b)
  b:cmd("quiet off")
  a:deliver("Bobby", "hi")
  a:drain()
  b:deliver("Bobby", "hey")
  b:drain()
  if whisperedTo(a, "Salabeard") ~= 1 then
    error("still sent addon messages to a window that turned it off")
  end
  if whisperedTo(b, "Salahaja") ~= 1 then error("the window that turned it off did not whisper") end
end)

step("quiet: switched off with a hello still in flight, it still says no", function()
  local a = quietClient("Salahaja")
  local b = quietClient("Salabeard")        -- its hello to a is on the wire...
  b:cmd("quiet off")                        -- ...when it changes its mind
  a:deliver("Bobby", "while off")
  a:drain()
  if whisperedTo(a, "Salabeard") ~= 1 then error("not whispered to a window with quiet off") end
  for _, m in ipairs(toTarget(a, "Salabeard")) do b:deliver("Salahaja", m.text) end
  if times(b, "while off") ~= 1 then error("not shown exactly once: " .. shown(b)) end
end)

step("quiet: /wf quiet on again asks the other windows at once", function()
  local a = quietClient("Salahaja")
  local b = quietClient("Salabeard")
  b:cmd("quiet off")
  a:deliver("Bobby", "while off")
  a:drain()                                 -- a now whispers b
  b:cmd("quiet on")
  settle(a, b)
  a:deliver("Bobby", "back on")
  a:tick(0)
  a:tick(1)
  if whisperedTo(a, "Salabeard") ~= 1 then error("still whispering a window that turned it back on") end
  if times(b, "back on") ~= 1 then error("never arrived") end
end)

step("quiet: the settings window has the switch, and it takes effect at once", function()
  local a = quietClient("Salahaja")
  local b = quietClient("Salabeard")
  settle(a, b)
  b:cmd("config")
  local switch
  for _, box in ipairs(b.WR.panel.boxes) do
    if box.key == "quiet" then switch = box end
  end
  if not switch then error("no quiet switch in the settings window") end
  b:click(switch)
  if b.WR.config.quiet then error("clicking it did not turn it off") end
  a:deliver("Bobby", "hi")
  a:drain()
  if whisperedTo(a, "Salabeard") ~= 1 then error("the other window was not told") end
end)

step("quiet: /wf status says who is reached without whispers", function()
  local a = quietClient("Salahaja")
  local b = quietClient("Salabeard")
  settle(a, b)
  a.chat = {}
  a:cmd("status")
  if not string.find(shown(a), "no whispers to Salabeard", 1, true) then
    error("status did not say: " .. shown(a))
  end
end)

step("quiet: /wf status names a window that did not answer", function()
  local a = quietClient("Salahaja")
  net.online["Oldcopy"] = true
  a:cmd("to Oldcopy")
  a:deliver("Bobby", "hi")
  a:drain()
  a.chat = {}
  a:cmd("status")
  if not string.find(shown(a), "Oldcopy did not answer", 1, true) then
    error("status did not say: " .. shown(a))
  end
end)

step("quiet: on a server without it, whispers -- and /wf status says why", function()
  net.turtle = false
  local a = quietClient("Salahaja")
  quietClient("Salabeard")
  a:deliver("Bobby", "hi")
  a:drain()
  if whisperedTo(a, "Salabeard") ~= 1 then error("not whispered when the server could not carry it") end
  if #carried(a, "Salabeard") > 0 then error("sent the message itself with nothing having answered") end
  a.chat = {}
  a:cmd("status")
  if not string.find(shown(a), "did not pass a test message back", 1, true) then
    error("status did not say why: " .. shown(a))
  end
end)

----------------------------------------------------------------------
-- the relay window, opening by itself
----------------------------------------------------------------------

step("the relay window opens on the window a whisper is forwarded to", function()
  local a = quietClient("Salahaja")
  local b = quietClient("Salabeard")
  a:deliver("Bobby", "you around?")
  a:drain()
  local win = b.WR.chatFrame
  if not win or not win:IsShown() then error("the relay window did not open") end
  if win.edit.focused then error("it took the keyboard") end
  if not string.find(table.concat(win.log.lines, "\n"), "you around?", 1, true) then
    error("it opened without the whisper in it")
  end
  if a.WR.chatFrame and a.WR.chatFrame:IsShown() then
    error("it opened on the window the whisper arrived at")
  end
end)

step("the relay window opens for a whispered forward too, and not on Party", function()
  local a = newClient("Salahaja")            -- quiet off: forwards are whispers
  local b = newClient("Salabeard")
  b:cmd("chat")
  b.WR.ShowChatTab("group")                  -- left on Party, then closed
  b:cmd("chat")
  a:deliver("Bobby", "you around?")
  a:drain()
  for _, m in ipairs(toTarget(a, "Salabeard")) do b:deliver("Salahaja", m.text) end
  b:tick(1)
  if not b.WR.chatFrame:IsShown() then error("the relay window did not open") end
  if b.WR.chatTab == "group" then error("opened on Party, where Enter would talk to the group") end
end)

step("the relay window opens when the chat hook cannot rewrite the whisper", function()
  local a = newClient("Salahaja")
  local b = newClient("Salabeard")
  b:cmd("inline")                            -- the hook stands aside: a line underneath
  a:deliver("Bobby", "you around?")
  a:drain()
  for _, m in ipairs(toTarget(a, "Salabeard")) do b:deliver("Salahaja", m.text) end
  b:tick(1)
  if not (b.WR.chatFrame and b.WR.chatFrame:IsShown()) then error("the relay window did not open") end
end)

----------------------------------------------------------------------
-- names as typed, and what older copies saved
----------------------------------------------------------------------

--[[ Found in game: an account saved by an older copy had its target typed as
     "salahaja". The forward reached Salahaja -- the server fixes the case --
     but the answer came back from "Salahaja", and "is this one of my
     windows?" compared the two exactly. Refused, with a warning. ]]
step("a target saved in lower case still honours /wr from that window", function()
  local a = newClient("Salabeard", { db = { quiet = false, auto = false, target = "salahaja" } })
  local b = quietClient("Salahaja")
  a:deliver("Bobby", "you around?")
  a:drain()
  -- The server delivers a whisper whatever case its name was typed in.
  for _, m in ipairs(a.sent) do
    if string.lower(m.target or "") == "salahaja" then b:deliver("Salabeard", m.text) end
  end
  b:reply("hey")
  b:drain()
  for _, m in ipairs(toTarget(b, "Salabeard")) do a:deliver("Salahaja", m.text) end
  a:drain()
  local said = toTarget(a, "Bobby")
  if #said ~= 1 or said[1].text ~= "hey" then
    error("Bobby was not answered: " .. table.concat(a.chat, " | "))
  end
end)

step("/wf to keeps the name the way the server writes it", function()
  local a = newClient("Salabeard")
  a:cmd("to SALAHAJA")
  if a.WR.config.target ~= "Salahaja" then error("saved as " .. tostring(a.WR.config.target)) end
  a:cmd("to salahaja")
  if a.WR.config.target ~= "Salahaja" then error("saved as " .. tostring(a.WR.config.target)) end
  a:cmd("to salabeard")
  if a.WR.config.target ~= "Salahaja" then error("took this character, typed small, as the target") end
end)

step("quiet: /wf quiet on its own turns it on, never off", function()
  local a = quietClient("Salahaja")
  a:cmd("quiet")
  if not a.WR.config.quiet then error("switched it off") end
  a:cmd("quiet off")
  a:cmd("quiet")
  if not a.WR.config.quiet then error("did not switch it back on") end
end)

step("what the folder test build saved is cleared away", function()
  local db = { quiet = false, seen = { ["Salahaja>Salabeard"] = { seq = 0, session = "x" } } }
  newClient("Salabeard", { db = db })
  if db.seen ~= nil then error("left it in the saved variables") end
end)

step("/wf autoopen keeps the relay window shut, and the settings window has it", function()
  local a = quietClient("Salahaja")
  local b = quietClient("Salabeard")
  b:cmd("autoopen")
  a:deliver("Bobby", "you around?")
  a:drain()
  if b.WR.chatFrame and b.WR.chatFrame:IsShown() then error("opened anyway") end
  if times(b, "you around?") ~= 1 then error("and the whisper itself went missing") end
  b:cmd("config")
  local switch
  for _, box in ipairs(b.WR.panel.boxes) do
    if box.key == "openChat" then switch = box end
  end
  if not switch then error("no switch for it in the settings window") end
  b:click(switch)
  if not b.WR.config.openChat then error("clicking it did not turn it back on") end
end)

----------------------------------------------------------------------
-- the minimap button
----------------------------------------------------------------------

print("\n  the minimap button\n")

local function minimapButton(c) return c.byName["WhisperRelayMinimapButton"] end

--- Right-click the button; the menu's lines, by what they say.
local function openMenu(c)
  c:click(minimapButton(c), "RightButton")
  if not c.menuOpen then error("a right-click opened no menu") end
  local lines = {}
  for _, info in ipairs(c.menu) do lines[info.text] = info end
  return lines
end

step("there is a minimap button, and a left-click opens the settings", function()
  local a = newClient("Salahaja")
  local b = minimapButton(a)
  if not b or not b:IsShown() then error("no minimap button") end
  a:click(b, "LeftButton")
  if not (a.WR.panel and a.WR.panel:IsShown()) then error("the settings did not open") end
  a:click(b, "LeftButton")
  if a.WR.panel:IsShown() then error("a second left-click did not close them") end
end)

step("a right-click opens a menu of basic switches, each showing its state", function()
  local a = newClient("Salahaja")           -- quiet off, as older saved settings have it
  local lines = openMenu(a)
  local want = {
    ["Forward whispers"] = true,
    ["Quiet: no whispers between my windows"] = false,
    ["Open the relay window for a whisper"] = true,
    ["Forward party and raid chat"] = false,
    ["Forward guild chat"] = false,
    ["Pass on queue pops"] = true,
    ["Popup for a pop"] = true,
  }
  for text, on in pairs(want) do
    local info = lines[text]
    if not info then error("no line for: " .. text) end
    if (info.checked and true or false) ~= on then error(text .. " shows the wrong state") end
    if not info.keepShownOnClick then error(text .. " closes the menu when ticked") end
  end
  a:click(minimapButton(a), "RightButton")
  if a.menuOpen then error("a second right-click did not close it") end
end)

step("a switch in the menu flips it, and the menu shows that next time", function()
  local a = newClient("Salahaja")
  openMenu(a)
  a:pick("Open the relay window for a whisper")
  if a.WR.config.openChat then error("still on") end
  a:closeMenu()
  if openMenu(a)["Open the relay window for a whisper"].checked then
    error("the menu still shows it on")
  end
end)

step("the menu's quiet switch tells the other window, as the settings window does", function()
  local a = quietClient("Salahaja")
  local b = quietClient("Salabeard")
  settle(a, b)
  openMenu(b)
  b:pick("Quiet: no whispers between my windows")
  a:deliver("Bobby", "hi")
  a:drain()
  if whisperedTo(a, "Salabeard") ~= 1 then error("the other window was not told") end
end)

step("the menu works on a client that hands its lines' functions nothing", function()
  local a = newClient("Salahaja")
  openMenu(a)
  a:pick("Pass on queue pops", true)
  if a.WR.config.alerts then error("did not switch it off") end
end)

step("forwarding switched back on tries the target again", function()
  local c = newClient("Salahaja")
  c:cmd("to Salabeard")
  notFound(c, "Salabeard")
  if c.WR.config.enabled then error("setup: a refusal should have switched it off") end
  openMenu(c)
  c:pick("Forward whispers")
  c:deliver("Bobby", "back?")
  c:drain()
  if #toTarget(c, "Salabeard") < 1 then error("on again, but still forwarding nowhere") end
end)

step("the menu opens the relay window and the settings, and never closes them", function()
  local a = newClient("Salahaja")
  openMenu(a)
  a:pick("Open the relay window")
  if not (a.WR.chatFrame and a.WR.chatFrame:IsShown()) then error("no relay window") end
  if a.menuOpen then error("the menu stayed open") end
  openMenu(a)
  a:pick("Open the relay window")
  if not a.WR.chatFrame:IsShown() then error("a second pick closed the relay window") end
  openMenu(a)
  a:pick("All settings...")
  if not (a.WR.panel and a.WR.panel:IsShown()) then error("no settings window") end
  openMenu(a)
  a:pick("All settings...")
  if not a.WR.panel:IsShown() then error("a second pick closed the settings") end
end)

step("the button drags round the minimap, and stays where it was left", function()
  local a = newClient("Salahaja")
  a.cursor = { 100, 200 }                    -- straight above the map's centre
  a:drag(minimapButton(a))
  if math.abs(a.WR.config.minimapAngle - 90) > 0.001 then
    error("saved " .. tostring(a.WR.config.minimapAngle) .. " degrees, not 90")
  end
  if minimapButton(a).scripts.OnUpdate then error("still following the cursor after the drop") end
  local a2 = newClient("Salahaja", { db = a.env.WhisperRelayDB })
  local p = minimapButton(a2).point
  if not p or p[2] ~= a2.env.Minimap or math.abs(p[4]) > 0.001 or math.abs(p[5] - 80) > 0.001 then
    error("not put back at the top after a /reload")
  end
end)

step("/wf minimap hides the button, and it stays hidden across a /reload", function()
  local a = newClient("Salahaja")
  a:cmd("minimap")
  if minimapButton(a):IsShown() then error("still showing") end
  local a2 = newClient("Salahaja", { db = a.env.WhisperRelayDB })
  local b2 = minimapButton(a2)
  if b2 and b2:IsShown() then error("came back on its own after a /reload") end
  a2:cmd("minimap")
  if not (minimapButton(a2) and minimapButton(a2):IsShown()) then error("did not come back") end
end)

step("the menu can hide the button, and says how to get it back", function()
  local a = newClient("Salahaja")
  a.chat = {}
  openMenu(a)
  a:pick("Hide this button")
  if minimapButton(a):IsShown() then error("still showing") end
  if not string.find(table.concat(a.chat, "\n"), "/wf minimap", 1, true) then
    error("did not say how to get it back")
  end
end)

step("hovering the button says what the clicks do, and where whispers go", function()
  local a = newClient("Salahaja")
  a:cmd("to Salabeard")
  a:hover(minimapButton(a))
  local tip = table.concat(a.tooltip, "\n")
  for _, want in ipairs({ "Left-click", "Right-click", "Forwarding to Salabeard" }) do
    if not string.find(tip, want, 1, true) then
      error("the tooltip does not say " .. want .. ": " .. tip)
    end
  end
  a:cmd("off")
  a:hover(minimapButton(a))
  if not string.find(table.concat(a.tooltip, "\n"), "Forwarding is off", 1, true) then
    error("the tooltip does not say forwarding is off")
  end
end)

----------------------------------------------------------------------
-- guild chat
----------------------------------------------------------------------

print("\n  guild chat\n")

--- One window in a guild and one not: the case this is for.
local function guildPair()
  local a = quietClient("Salahaja")
  local b = quietClient("Salabeard")
  a.guildName = "Some Guild"
  a.roster = { "Salahaja", "Guildie" }
  settle(a, b)
  return a, b
end

local function openWindow(c)
  if not (c.WR.chatFrame and c.WR.chatFrame:IsShown()) then c:cmd("chat") end
end

--- Click one of the relay window's tabs, as the player would.
local function showTab(c, key)
  for _, t in ipairs(c.WR.chatFrame.tabs) do
    if t.key == key then c:click(t) return end
  end
  error("no " .. key .. " tab")
end

local function typeInWindow(c, text)
  local e = chatBox(c)
  e:SetText(text)
  e.scripts.OnEnterPressed()
end

local function saidIn(c, channel)
  local out = {}
  for _, m in ipairs(c.sent) do
    if m.chan == channel then table.insert(out, m.text) end
  end
  return out
end

step("guild chat is not forwarded until it is switched on", function()
  local a = guildPair()
  a:fire("CHAT_MSG_GUILD", "anyone for ZG?", "Guildie")
  a:drain()
  if #carried(a, "Salabeard") > 0 or whisperedTo(a, "Salabeard") > 0 then
    error("forwarded with it off")
  end
end)

step("guild chat lands on the Guild tab of a window outside the guild, not in its chat", function()
  local a, b = guildPair()
  a:cmd("guild")
  b.chat = {}
  a:fire("CHAT_MSG_GUILD", "anyone for ZG?", "Guildie")
  a:drain()
  if whisperedTo(a, "Salabeard") > 0 then error("whispered it") end
  if times(b, "anyone for ZG?") > 0 then error("it went into the chat frame as well") end
  if b.WR.chatFrame and b.WR.chatFrame:IsShown() then error("it opened the window by itself") end
  openWindow(b)
  showTab(b, "guild")
  local seen = table.concat(windowLines(b), "\n")
  if not string.find(seen, "anyone for ZG?", 1, true) then error("not on the Guild tab: " .. seen) end
  if not string.find(seen, "Guild", 1, true) then error("not marked as guild chat") end
  showTab(b, "group")
  if string.find(table.concat(windowLines(b), "\n"), "anyone for ZG?", 1, true) then
    error("it is on the Party tab too")
  end
end)

step("the Guild tab answers the guild, through the window that is in it", function()
  local a, b = guildPair()
  a:cmd("guild")
  a:fire("CHAT_MSG_GUILD", "anyone for ZG?", "Guildie")
  a:drain()
  openWindow(b)
  showTab(b, "guild")
  typeInWindow(b, "me!")
  b:drain()
  local said = saidIn(a, "GUILD")
  if #said ~= 1 or said[1] ~= "me!" then error("the guild did not hear it") end
  if whisperedTo(b, "Salahaja") > 0 then error("whispered the other window to ask it") end
  if not string.find(table.concat(windowLines(b), "\n"), "me!", 1, true) then
    error("what was said is not shown on the Guild tab")
  end
end)

step("/wg answers the guild too", function()
  local a, b = guildPair()
  a:cmd("guild")
  a:fire("CHAT_MSG_GUILD", "anyone for ZG?", "Guildie")
  a:drain()
  b.chat = {}
  b:toGuild("on my way")
  b:drain()
  local said = saidIn(a, "GUILD")
  if #said ~= 1 or said[1] ~= "on my way" then error("the guild did not hear it") end
  -- The relay window is shut, so what was said shows where you typed it.
  if times(b, "on my way") ~= 1 then error("nothing shown for what was said") end
end)

step("the All tab never answers the guild, however recently it spoke", function()
  local a, b = guildPair()
  a:cmd("guild")
  a:deliver("Bobby", "you around?")
  a:drain()
  a:fire("CHAT_MSG_GUILD", "lol", "Guildie")
  a:drain()
  openWindow(b)
  showTab(b, "all")
  typeInWindow(b, "brb")
  b:drain()
  if #saidIn(a, "GUILD") > 0 then error("a reply on All went to the guild") end
  local toBobby = toTarget(a, "Bobby")
  if #toBobby ~= 1 or toBobby[1].text ~= "brb" then error("the whisper was not answered") end
end)

step("guild chat works over whispers too, for a window with quiet off", function()
  local a = newClient("Salahaja", { guild = "Some Guild" })
  local b = newClient("Salabeard")
  a.roster = { "Salahaja", "Guildie" }
  a:cmd("guild")
  a:fire("CHAT_MSG_GUILD", "anyone for ZG?", "Guildie")
  a:drain()
  for _, m in ipairs(toTarget(a, "Salabeard")) do b:deliver("Salahaja", m.text) end
  b:toGuild("me!")
  b:drain()
  for _, m in ipairs(toTarget(b, "Salahaja")) do a:deliver("Salabeard", m.text) end
  local said = saidIn(a, "GUILD")
  if #said ~= 1 or said[1] ~= "me!" then error("the guild did not hear it") end
end)

step("guild chat is not forwarded to a window in the same guild", function()
  local a = guildPair()
  a.roster = { "Salahaja", "Salabeard", "Guildie" }
  a:cmd("guild")
  a:fire("CHAT_MSG_GUILD", "hello", "Guildie")
  a:drain()
  if #carried(a, "Salabeard") > 0 or whisperedTo(a, "Salabeard") > 0 then
    error("sent it to a window that already has it")
  end
end)

step("the roster is asked for when guild chat is switched on, and at login", function()
  local a = guildPair()
  local before = a.rosterAsked
  a:cmd("guild")
  if a.rosterAsked <= before then error("not asked for when switched on") end
  local a2 = newClient("Salahaja", { db = a.env.WhisperRelayDB, guild = "Some Guild" })
  if a2.rosterAsked < 1 then error("not asked for at login") end
end)

step("a stranger cannot make you speak in your guild", function()
  local a = guildPair()
  a:fire("CHAT_MSG_ADDON", "TW_CHAT_MSG_WHISPER",
    "\tWRqm" .. a.WR.Encode(">$give me gold"), "GUILD", "Evil")
  a:drain()
  if #saidIn(a, "GUILD") > 0 then error("spoke in the guild for a stranger") end
end)

step("a window that has left its guild says so, rather than nothing", function()
  local a, b = guildPair()
  a:cmd("guild")
  a:fire("CHAT_MSG_GUILD", "anyone for ZG?", "Guildie")
  a:drain()
  a.guildName = nil
  a.chat = {}
  b:toGuild("hi")
  b:drain()
  if #saidIn(a, "GUILD") > 0 then error("tried to speak in a guild it is not in") end
  if not string.find(table.concat(a.chat, "\n"), "not in a guild any more", 1, true) then
    error("said nothing: " .. table.concat(a.chat, " | "))
  end
end)

step("a busy guild pauses guild forwarding, and not the party's", function()
  local a, b = guildPair()
  a:cmd("guild")
  a:cmd("group")
  a.party = { "Bobby" }
  for i = 1, 30 do a:fire("CHAT_MSG_GUILD", "chatter " .. i, "Guildie") end
  a:drain()
  local guildLines = 0
  for _, entry in ipairs(b.WR.chatLog) do
    if entry.kind == "guild" then guildLines = guildLines + 1 end
  end
  if guildLines > 25 then error(guildLines .. " guild lines got through the limit") end
  a:fire("CHAT_MSG_PARTY", "pull in 10", "Bobby")
  a:drain()
  if times(b, "pull in 10") < 1 then error("the guild's pause silenced the party") end
end)

--[[ A unit check of the window's history rather than a whole conversation:
     the rate limit would take several minutes of clock to push this much
     guild chat through. ]]
step("the relay window keeps its whispers however much the guild says", function()
  local b = newClient("Salabeard")
  b.WR.ChatAdd("from Bobby: important", "whisper")
  for i = 1, 100 do b.WR.ChatAdd("chatter " .. i, "guild") end
  local whispers, guild = 0, 0
  for _, entry in ipairs(b.WR.chatLog) do
    if entry.kind == "whisper" then whispers = whispers + 1 end
    if entry.kind == "guild" then guild = guild + 1 end
  end
  if whispers ~= 1 then error("the guild pushed the whisper out") end
  if guild ~= 60 then error("kept " .. guild .. " guild lines, not the last 60") end
end)

step("the settings window and the minimap menu have the guild switch", function()
  local a = guildPair()
  a:cmd("config")
  local switch
  for _, box in ipairs(a.WR.panel.boxes) do
    if box.key == "guildChat" then switch = box end
  end
  if not switch then error("no guild switch in the settings window") end
  a:click(switch)
  if not a.WR.config.guildChat then error("clicking it did not turn it on") end
  local lines = openMenu(a)
  if not (lines["Forward guild chat"] and lines["Forward guild chat"].checked) then
    error("the menu does not show it on")
  end
end)

----------------------------------------------------------------------
-- the keyboard
----------------------------------------------------------------------

print("\n  the keyboard\n")

--[[ Found in game: click into the relay window's box, then click a mob, and
     every keybind after that went into the box as text until Escape. A box
     has the keyboard only while it is being typed in. ]]
step("the relay box gives the keyboard back once a line is sent", function()
  local a = quietClient("Salahaja")
  local b = quietClient("Salabeard")
  a:deliver("Bobby", "you around?")
  a:drain()
  local e = chatBox(b)
  e:SetFocus()                               -- clicked into it
  e:SetText("five minutes")
  e.scripts.OnEnterPressed()
  if e.focused then error("still holding the keyboard after sending") end
end)

step("a click in the world takes the keyboard back from the relay box", function()
  local b = newClient("Salabeard")
  b:cmd("chat")
  local e = chatBox(b)
  e:SetFocus()
  e:SetText("half a thought")
  b:clickWorld("LeftButton")                 -- a mob
  if e.focused then error("a left-click in the world left the box the keyboard") end
  if e:GetText() ~= "half a thought" then error("what was typed was thrown away") end
  e:SetFocus()
  b:clickWorld("RightButton")
  if e.focused then error("a right-click in the world left the box the keyboard") end
end)

step("a click in the world still reaches what listened for it before", function()
  local heard = 0
  local b = newClient("Salabeard", { worldScript = function() heard = heard + 1 end })
  b:cmd("chat")
  chatBox(b):SetFocus()
  b:clickWorld()
  if heard ~= 1 then error("the script that was there before did not run") end
  if chatBox(b).focused then error("and the box kept the keyboard") end
end)

step("a click on the window around the relay box takes the keyboard back", function()
  local b = newClient("Salabeard")
  b:cmd("chat")
  local e = chatBox(b)
  e:SetFocus()
  b:press(chatWindow(b))
  if e.focused then error("a click beside the box left it the keyboard") end
end)

step("closing the relay window takes the keyboard back", function()
  local b = newClient("Salabeard")
  b:cmd("chat")
  local e = chatBox(b)
  e:SetFocus()
  b:cmd("chat")                              -- closed again
  if e.focused then error("a hidden box kept the keyboard") end
end)

step("the settings box gives the keyboard back too, and keeps what was typed", function()
  local a = newClient("Salahaja")
  a:cmd("config")
  local e = replyBox(a)
  e:SetFocus()
  e:SetText("gone fishing")
  a:clickWorld()
  if e.focused then error("a world click left the settings box the keyboard") end
  if a.WR.config.replyText ~= "gone fishing" then error("what was typed was not kept") end
  e:SetFocus()
  a:cmd("config")                            -- closed
  if e.focused then error("closing the settings left its box the keyboard") end
end)

step("a world click leaves alone a box of ours not being typed in", function()
  -- Nothing of ours has the keyboard, so nothing of ours is told to let go
  -- of it: whatever does have it -- the chat frame's box -- keeps it.
  local b = newClient("Salabeard")
  b:cmd("chat")
  local e = chatBox(b)
  local before = e.clearCalls
  b:clickWorld()
  if e.clearCalls ~= before then error("let go of a keyboard it did not have") end
end)

print(string.format("\n%d passed, %d failed  \n", pass, fail))
if fail > 0 then os.exit(1) end
