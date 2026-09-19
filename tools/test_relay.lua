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
string.gfind = string.gfind or string.gmatch
table.getn = table.getn or function(t) return #t end
unpack = unpack or table.unpack

local clock = { t = 100000, gt = 500 }

--[[ One CustomData directory, shared by every client in a test, because that
     is exactly what makes the two real clients able to see each other: they
     are one installation with one folder. ]]
local files = {}
local function resetFiles()
  for k in pairs(files) do files[k] = nil end
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

local function newClient(name)
  local c = { name = name, sent = {}, chat = {}, sounds = 0, clientShown = {},
              byName = {} }
  local env = setmetatable({}, { __index = _G })
  c.env = env

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
    if mode == "a" then files[name] = (files[name] or "") .. text
    else files[name] = text end
  end
  env.ReadCustomFile = function(name) return files[name] end
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
  env.SendChatMessage = function(text, chan, _, target)
    if type(text) ~= "string" then error("sent a non-string") end
    if string.len(text) > 255 then
      error("whisper of " .. string.len(text) .. " chars would be dropped by 1.12")
    end
    table.insert(c.sent, { text = text, chan = chan, target = target })
  end
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
    function r:SetPoint() end
    function r:SetAllPoints() end
    function r:SetWidth() end
    function r:SetHeight() end
    function r:SetTexture() end
    function r:SetVertexColor() end
    function r:SetFont() end
    function r:SetTextColor() end
    function r:SetJustifyH() end
    function r:Show() self.shown = true end
    function r:Hide() self.shown = false end
    function r:IsShown() return self.shown end
    return r
  end

  env.UIParent = region()
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

    -- The first frame is the addon's event frame; the popup comes later and
    -- must not quietly take its place.
    if not c.frame then c.frame = f end
    if name then c.byName[name] = f end
    return f
  end

  local chunk = assert(loadfile("WhisperRelay.lua", "t", env))
  chunk()

  c.WR = env.WhisperRelay

  function c:fire(event, a1, a2)
    if not self.frame.events[event] then
      error(self.name .. " never registered " .. event)
    end
    env.event = event
    env.arg1 = a1
    env.arg2 = a2
    self.frame.scripts.OnEvent()
  end

  function c:tick(step)
    env.arg1 = step or 1
    self.frame.scripts.OnUpdate()
  end

  -- Drain the outgoing queue the way the game would, a frame at a time.
  function c:drain()
    for _ = 1, 40 do self:tick(1) end
  end

  function c:cmd(text)
    env.SlashCmdList["WHISPERRELAY"](text)
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
  -- next one that a character it never heard of is logged in.
  resetFiles()
  local ok, err = pcall(fn)
  if ok then
    pass = pass + 1
    print(string.format("  ok    %s", label))
  else
    fail = fail + 1
    print(string.format("  FAIL  %s\n        %s", label, tostring(err)))
  end
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

print(string.format("\n%d passed, %d failed\n", pass, fail))
if fail > 0 then os.exit(1) end
