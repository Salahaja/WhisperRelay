--[[ Whisper Relay

When a whisper arrives on this character it is forwarded, as a whisper, to one
character you nominate -- the one you are actually playing on the other
account. The forward carries who it came from, so you can answer.

It can also answer the sender for you, telling them which character you are on
so they stop whispering the one nobody is watching.

The forwards travel as ordinary whispers. That is deliberate: the relay itself
needs nothing shared, so it works whether the other account is a second copy
of the client, a second machine, or a friend covering for you. Only working out
WHO to forward to on its own needs the shared folder, and naming a character by
hand replaces that.

Loops are the danger here. Two characters each forwarding to the other would
bounce one message between them until the server disconnects both for spam, so
three things are never forwarded and never auto-answered: anything from the
character we forward TO, anything already carrying the forward marker, and
ourselves.
]]

WhisperRelay = {}
local WR = WhisperRelay

WR.version = (GetAddOnMetadata and GetAddOnMetadata("WhisperRelay", "Version"))
             or "unknown"

--[[ The marker is the loop guard, not decoration: it is how the other end
     recognises a forward as a forward and refuses to forward it onward. ]]
local MARK = ">>"

--[[ Alerts get their own marker rather than sharing the forward's.

     A forward is "someone said this to me" and carries a name to answer; an
     alert is "something is about to expire on the window you are not looking
     at" and carries nobody. Sending alerts under the forward marker would
     have the other end offer a clickable reply to a person who does not
     exist. Both markers are loop guards, so neither is ever passed on. ]]
local ALERT = ">!"

-- 1.12 drops a whisper over 255 characters. Leave room for the marker and the
-- sender's name rather than finding out by having text silently vanish.
local WHISPER_MAX = 250
local MAX_PARTS = 3

-- Whispers sent back to back trip the client's own flood protection, which
-- drops them without telling you. One every third of a second does not.
local SEND_GAP = 0.35

local DIM = "|cff9d9d9d"
local WARN = "|cffd44f53"
local OK = "|cff63c776"

WR.queue = {}
WR.sinceSend = 0
WR.replied = {}      -- sender -> time() of the last auto-answer
--[[ Characters the server has told us are not there, and when it said so.
     Read by AutoTarget, which runs long before the section that fills it,
     so it is declared up here with the rest of the state rather than beside
     the code that uses it. ]]
WR.offline = {}
WR.ready = false

local defaults = {
  enabled = true,
  target = nil,          -- the character forwards go to
  autoReply = true,
  -- {char} is filled in with the target. Kept as a token so the text stays
  -- correct after the target changes.
  replyText = "Not watching this one right now - I'm on {char}, whisper me there.",
  replyCooldown = 300,   -- seconds, per sender
  announce = true,       -- echo forwards into this window too
  -- The clickable name under an arriving forward. This is the half that runs
  -- on the character you are actually playing.
  replyLink = true,
  -- Rewrite the forward so the name is clickable IN the message, instead of
  -- on a line underneath it.
  inline = true,
  --[[ Work out the other character rather than being told it, so switching
       which alt you play needs nothing typed. Falls back to `target` wherever
       the clients cannot see each other. ]]
  auto = true,
  --[[ Tell the other window when a battleground invite or a dungeon group
       lands on this one. Both expire on a timer. ]]
  alerts = true,
  -- ...and show it on screen there, not only in chat, since a chat line is
  -- exactly what you miss while looking at the other window.
  popup = true,
  popupSeconds = 60,
}

----------------------------------------------------------------------

local function Print(msg)
  DEFAULT_CHAT_FRAME:AddMessage("|cff8fd0ffWhisperRelay|r " .. msg)
end
WR.Print = Print

----------------------------------------------------------------------
-- sending
----------------------------------------------------------------------

function WR.Queue(text, target)
  table.insert(WR.queue, { text = text, target = target })
end

function WR.Flush(step)
  WR.sinceSend = WR.sinceSend + (step or 0)
  if WR.sinceSend < SEND_GAP then return end
  local job = table.remove(WR.queue, 1)
  if not job then return end
  WR.sinceSend = 0
  SendChatMessage(job.text, "WHISPER", nil, job.target)
end

--[[ Split so that marker, sender and body all fit. A long whisper arrives in
     order as "1/2" and "2/2" rather than as a sentence that stops mid-word
     with no sign anything was lost. ]]
function WR.Parts(sender, message)
  local head = MARK .. " " .. sender .. ": "
  local room = WHISPER_MAX - string.len(head)
  if room < 40 then room = 40 end

  if string.len(message) <= room then
    return { head .. message }
  end

  local parts, pos, n = {}, 1, 0
  local total = string.len(message)
  while pos <= total and n < MAX_PARTS do
    n = n + 1
    -- The counter costs a few characters of its own on every part.
    local chunk = string.sub(message, pos, pos + room - 8)
    table.insert(parts, head .. n .. ") " .. chunk)
    pos = pos + string.len(chunk)
  end
  if pos <= total then
    parts[table.getn(parts)] = parts[table.getn(parts)] .. " [cut]"
  end
  return parts
end

----------------------------------------------------------------------
-- working out which character you are actually on
----------------------------------------------------------------------

--[[ Both clients are the same installation, so they share CustomData/, and
     Nampower hands Lua a way to read and write in it. Each one leaves a line
     saying who is logged in, and reads the others -- which is how this knows
     your other character without being told, and keeps knowing after you
     switch to a different alt.

     SavedVariables cannot do this: they are per account, written at logout,
     so the account you are playing has no way to see them. A file the two
     processes already share is the only thing on this client that crosses
     that line.

     One append-only file rather than one per character, because there is no
     way to list a directory from Lua -- a file per character would need a
     roster to find them, and the roster would have the same problem. Two
     clients appending one short line a minute interleave lines rather than
     corrupting each other, and a lost heartbeat costs one minute of knowing.

     Only works when both clients share a machine. Across two PCs there is no
     shared folder, and /wf to <character> is still there. ]]
local PRESENCE = "WhisperRelay_presence.txt"
local BEAT = 60            -- how often we say we are here
local LIVE = 180           -- how recent a heartbeat has to be to count
local LOOKUP_CACHE = 15    -- whispers arrive in bursts; do not re-read per one
local PRESENCE_MAX = 16384

function WR.FileAPI()
  return (WriteCustomFile ~= nil) and (ReadCustomFile ~= nil)
end

function WR.Beat(step)
  if not WR.config.auto or not WR.FileAPI() then return end
  WR.sinceBeat = (WR.sinceBeat or BEAT) + (step or 0)
  if WR.sinceBeat < BEAT then return end
  WR.sinceBeat = 0
  pcall(WriteCustomFile, PRESENCE, "P~" .. WR.me .. "~" .. time() .. "\n", "a")
end

--- name -> the most recent time it said it was logged in.
function WR.ReadPresence()
  local seen = {}
  if not WR.FileAPI() then return seen end
  local ok, text = pcall(ReadCustomFile, PRESENCE)
  if not ok or not text then return seen end

  for line in string.gfind(text, "[^\n]+") do
    local _, _, name, stamp = string.find(line, "^P~([^~]+)~(%d+)$")
    if name then
      stamp = tonumber(stamp) or 0
      if not seen[name] or stamp > seen[name] then seen[name] = stamp end
    end
  end

  -- Trimmed by whoever notices. Losing a heartbeat to the race costs a minute.
  if string.len(text) > PRESENCE_MAX then
    local keep = {}
    for name, stamp in pairs(seen) do
      table.insert(keep, "P~" .. name .. "~" .. stamp)
    end
    pcall(WriteCustomFile, PRESENCE, table.concat(keep, "\n") .. "\n", "w")
  end
  return seen
end

--- The other character logged in right now, or nil if there isn't one.
function WR.AutoTarget()
  local now = time()
  if WR.autoName ~= nil and WR.autoAt and (now - WR.autoAt) < LOOKUP_CACHE then
    return WR.autoName or nil
  end

  local best, bestAt = nil, 0
  for name, stamp in pairs(WR.ReadPresence()) do
    --[[ Every character that has ever logged in beside this one gets
         remembered, so your own alts build the list with nothing typed at
         all. It keeps working after the other client closes, because the
         rosters can then confirm the same names. ]]
    WR.Remember(name, false)
    --[[ Skip anyone the server has since refused, unless they have said they
         are here again SINCE that refusal. Without the second half this
         picks the logged-out character straight back up: their last
         heartbeat is still recent, and stays recent for three more minutes. ]]
    local refused = WR.offline[name]
    local gone = refused and stamp <= refused
    if name ~= WR.me and not gone and (now - stamp) < LIVE and stamp > bestAt then
      best, bestAt = name, stamp
    end
  end

  -- false rather than nil, so "looked and found nobody" is still a cached answer.
  WR.autoName = best or false
  WR.autoAt = now
  return best
end

----------------------------------------------------------------------
-- names you have used before
----------------------------------------------------------------------

--[[ Every name you type is remembered, and from then on the addon picks
     whichever of them is logged in.

     Every character you log in on this machine appears here, across all the
     accounts you run, because each one writes to the shared folder. Names you
     type are remembered too. Nothing else can add itself, so nothing can
     volunteer to receive your whispers.

     It is a record, not a guess: what forwards actually follow is the shared
     folder, and a name is only ever used because you typed it. The list is
     here so /wf list can show you that both accounts are being seen. ]]

--[[ `promote` is the difference between "I typed this" and "I saw this".

     A name you typed goes to the front, because you just said that is where
     you want things to go. A name that merely appeared in the presence file
     is appended, so logging an alt in for a minute cannot displace the
     character you actually chose. ]]
function WR.Remember(name, promote)
  if not name or name == "" or name == WR.me then return end
  local known = WR.config.known or {}

  if not promote then
    for i = 1, table.getn(known) do
      if string.lower(known[i]) == string.lower(name) then return end
    end
    table.insert(known, name)
    while table.getn(known) > 10 do table.remove(known, 1) end
    WR.config.known = known
    return
  end

  local out = { name }
  for i = 1, table.getn(known) do
    if string.lower(known[i]) ~= string.lower(name) then
      table.insert(out, known[i])
    end
  end
  while table.getn(out) > 10 do table.remove(out) end
  WR.config.known = out
end

function WR.Forget(name)
  local known, out = WR.config.known or {}, {}
  for i = 1, table.getn(known) do
    if string.lower(known[i]) ~= string.lower(name or "") then
      table.insert(out, known[i])
    end
  end
  WR.config.known = out
end

--- Where forwards go: whoever you are playing, or whoever you nominated.
function WR.Target()
  --[[ The shared folder decides, and only it. Deliberately nothing clever
       here: this machine's own clients are the only thing that can be known
       for certain, and guessing from anywhere else -- a guild roster, a name
       that was typed once -- risks forwarding private messages to somebody
       who merely happens to be online. A named target is used only when
       there is no shared folder to consult. ]]
  if WR.config.auto then
    local live = WR.AutoTarget()
    if live then return live end
    -- Auto mode with nobody else logged in means exactly that.
    if WR.FileAPI() then return nil end
  end

  local named = WR.config.target
  if named and WR.offline[named] then return nil end
  return named
end

----------------------------------------------------------------------

--- Is this a message we must leave alone to avoid a loop?
function WR.IsLoop(sender, message, target)
  if not sender or sender == "" then return true end
  if sender == WR.me then return true end
  if target and sender == target then return true end
  -- Already relayed once: someone else's relay, or ours coming back.
  local head = string.sub(message or "", 1, 2)
  if head == MARK or head == ALERT then return true end
  return false
end

----------------------------------------------------------------------
-- something popped on the window you are not looking at
----------------------------------------------------------------------

--[[ A battleground invite and a dungeon group both expire on a timer, and
     both land on whichever client is queued -- which, when dual-boxing, is
     routinely the one nobody is watching. By the time you alt-tab for an
     unrelated reason the queue is gone and you are back at the end of it.

     The battleground half is the vanilla API: UPDATE_BATTLEFIELD_STATUS, then
     GetBattlefieldStatus until one of them says "confirm".

     The dungeon half is this server's own, and is not guesswork -- the LFT
     system talks over CHAT_MSG_ADDON, and S2C_OFFER_NEW is the offer landing.
     Read exactly the way UnitXP_SP3 reads it, including asking whether
     LFT_ADDON_PREFIX exists at all, since a client without that system simply
     never sets it. ]]

--- Send something that is not a forwarded message and needs no reply.
function WR.Alert(text)
  if not WR.ready or not WR.config.enabled or not WR.config.alerts then return end
  local target = WR.Target()
  if not target then return end
  -- A line break would split this into two whispers, the second of which
  -- carries no marker and would be forwarded straight back.
  local body = string.gsub(tostring(text or ""), "%s+", " ")
  WR.Queue(ALERT .. " " .. body, target)
  if WR.config.announce then
    DEFAULT_CHAT_FRAME:AddMessage(DIM .. "told " .. target .. ": " .. text .. "|r")
  end
end

--[[ The event fires repeatedly for as long as the invite stands, so the alert
     is keyed to the queue that caused it and only sent when that queue is
     newly confirmed. Otherwise one battleground pop is a whisper every time
     anything in the queue list twitches. ]]
WR.confirmed = {}

function WR.OnBattlefield()
  if not WR.ready then return end
  local slots = MAX_BATTLEFIELD_QUEUES or 3
  local nowConfirmed = {}

  for i = 1, slots do
    if GetBattlefieldStatus then
      local status, mapName = GetBattlefieldStatus(i)
      if status == "confirm" then
        local key = tostring(mapName or i)
        nowConfirmed[key] = true
        if not WR.confirmed[key] then
          WR.Alert((mapName or "A battleground") .. " is ready to join")
        end
      end
    end
  end

  WR.confirmed = nowConfirmed
end

function WR.OnAddonMessage(prefix, message)
  if not WR.ready then return end
  if not LFT_ADDON_PREFIX or prefix ~= LFT_ADDON_PREFIX then return end
  if not message then return end

  local what
  if string.find(message, "S2C_OFFER_NEW", 1, true) then
    what = "A dungeon group is ready"
  elseif string.find(message, "S2C_ROLECHECK_START", 1, true) then
    what = "Dungeon role check started"
  end
  if not what then return end

  -- One offer can be announced more than once; a whisper per repeat is spam.
  if WR.lastLFT and (time() - WR.lastLFT) < 20 then return end
  WR.lastLFT = time()
  WR.Alert(what)
end

function WR.ShouldReply(sender, target)
  if not WR.config.autoReply then return false end
  if not target then return false end
  local last = WR.replied[sender]
  if last and (time() - last) < WR.config.replyCooldown then return false end
  return true
end

function WR.ReplyBody(target)
  local text = WR.config.replyText or ""
  return (string.gsub(text, "{char}", target or WR.Target() or "?"))
end

----------------------------------------------------------------------
-- the other end: a forward arriving, and how to answer it
----------------------------------------------------------------------

--- The original sender and message out of a forward, or nil if it isn't one.
function WR.ParseForward(message)
  local text = message or ""
  if string.sub(text, 1, string.len(MARK)) ~= MARK then return nil end
  local _, _, name, body = string.find(text, "^" .. MARK .. " ([^:]+): (.*)$")
  if not name or name == "" then return nil end
  -- A split forward carries "2) " after the colon.
  body = string.gsub(body or "", "^%d+%)%s*", "")
  return name, body
end

--- A clickable name. Exactly the link the client builds for a whisper sender.
function WR.NameLink(name)
  return "|cffff80ff|Hplayer:" .. name .. "|h[" .. name .. "]|h|r"
end

--- The forward rewritten so it reads like a whisper from the person who wrote it.
function WR.InlineText(name, body, via)
  return WR.NameLink(name) .. "|cffff80ff whispers:|r " .. (body or "") ..
    DIM .. "  (via " .. tostring(via) .. ")|r"
end

--[[ Replace the client's own display of an arriving forward with one whose
     name is clickable.

     The link cannot travel in the whisper: 1.12 strips link escapes out of
     anything SendChatMessage sends, so it has to be rebuilt here. And to have
     it IN the message rather than on a line underneath, the client's own
     display has to be suppressed, which means standing in front of
     ChatFrame_OnEvent.

     That is a global other chat addons also replace. If one of them replaces
     it after us, or bypasses it entirely, this never runs -- so nothing here
     is load-bearing: WR.claimed records that the line was handled, and the
     frame after a forward arrives, anything unclaimed falls back to a
     separate clickable line. Inline when it can, a line underneath when it
     cannot, and never neither. ]]
function WR.InlineWhisper(evt)
  if evt ~= "CHAT_MSG_WHISPER" then return false end
  if not WR.ready or not WR.config.inline then return false end

  local name, body = WR.ParseForward(arg1)
  if not name then return false end

  WR.claimed = arg1
  local target = this or DEFAULT_CHAT_FRAME
  target:AddMessage(WR.InlineText(name, body, arg2))
  return true
end

function WR.InstallChatHook()
  if WR.hooked then return end
  if type(ChatFrame_OnEvent) ~= "function" then return end
  local original = ChatFrame_OnEvent
  ChatFrame_OnEvent = function(evt)
    if WR.InlineWhisper(evt) then return end
    return original(evt)
  end
  WR.hooked = true
end

--- The fallback: a short clickable line under a forward we could not rewrite.
function WR.ShowHandle(name, sender)
  if not WR.config.replyLink then return end

  -- A split forward is one conversation, so it gets one handle.
  if WR.handleFor == name and WR.handleAt and (time() - WR.handleAt) < 15 then
    return
  end
  WR.handleFor, WR.handleAt = name, time()

  DEFAULT_CHAT_FRAME:AddMessage(DIM .. "    reply to |r" ..
    WR.NameLink(name) .. DIM .. "  (forwarded by " .. tostring(sender) .. ")|r")
end

--[[ Decided a frame later, not here, because whether the chat hook got to
     rewrite this message is not known until every frame registered for the
     event has seen it. ]]
function WR.Settle()
  if not WR.pending then return end
  local p = WR.pending
  WR.pending = nil
  local handled = (WR.claimed == p.message)
  WR.claimed = nil
  if not handled then WR.ShowHandle(p.name, p.sender) end
end

----------------------------------------------------------------------
-- the popup
----------------------------------------------------------------------

--[[ A line in chat is easy to miss, and missing it is the entire problem --
     a queue invite expires while you are looking at the other window.

     Its own frame rather than StaticPopup, because a battleground invite
     arrives at exactly the moments the default popup slots are busy: loot
     rolls, a resurrect, a group invite. A dialog that queues behind those is
     a dialog that appears after the thing it was warning about expired. ]]
local POPUP_W, POPUP_H = 320, 84

function WR.BuildPopup()
  if WR.popup then return WR.popup end

  local f = CreateFrame("Button", "WhisperRelayPopup", UIParent)
  f:SetWidth(POPUP_W)
  f:SetHeight(POPUP_H)
  f:SetPoint("TOP", UIParent, "TOP", 0, -180)
  f:SetFrameStrata("FULLSCREEN_DIALOG")
  f:EnableMouse(true)
  f:Hide()

  local bg = f:CreateTexture(nil, "BACKGROUND")
  bg:SetTexture("Interface\\Buttons\\WHITE8X8")
  bg:SetVertexColor(0, 0, 0, 0.82)
  bg:SetAllPoints(f)

  -- Four edges rather than a backdrop: no edge file to tile badly at any size.
  local edges = {}
  for i = 1, 4 do
    local t = f:CreateTexture(nil, "BORDER")
    t:SetTexture("Interface\\Buttons\\WHITE8X8")
    t:SetVertexColor(1, 0.5, 0, 0.9)
    edges[i] = t
  end
  edges[1]:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
  edges[1]:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, 0)
  edges[1]:SetHeight(2)
  edges[2]:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 0, 0)
  edges[2]:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0)
  edges[2]:SetHeight(2)
  edges[3]:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
  edges[3]:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 0, 0)
  edges[3]:SetWidth(2)
  edges[4]:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, 0)
  edges[4]:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0)
  edges[4]:SetWidth(2)

  f.who = f:CreateFontString(nil, "OVERLAY")
  f.who:SetFont("Fonts\\FRIZQT__.TTF", 12)
  f.who:SetTextColor(1, 0.65, 0.1)
  f.who:SetPoint("TOP", f, "TOP", 0, -10)

  f.what = f:CreateFontString(nil, "OVERLAY")
  f.what:SetFont("Fonts\\FRIZQT__.TTF", 15)
  f.what:SetTextColor(1, 1, 1)
  f.what:SetPoint("TOP", f.who, "BOTTOM", 0, -8)
  f.what:SetWidth(POPUP_W - 24)

  f.hint = f:CreateFontString(nil, "OVERLAY")
  f.hint:SetFont("Fonts\\FRIZQT__.TTF", 10)
  f.hint:SetTextColor(0.6, 0.6, 0.6)
  f.hint:SetPoint("BOTTOM", f, "BOTTOM", 0, 8)
  f.hint:SetText("click to dismiss")

  f:SetScript("OnClick", function() WR.HidePopup() end)

  --[[ Its own countdown rather than the send queue's: this has to keep
       running while nothing is being sent, and has to survive the alert that
       raised it being the last thing that happened for a minute. ]]
  f:SetScript("OnUpdate", function()
    if not WR.popupUntil then return end
    if GetTime() >= WR.popupUntil then WR.HidePopup() end
  end)

  WR.popup = f
  return f
end

function WR.HidePopup()
  WR.popupUntil = nil
  if WR.popup then WR.popup:Hide() end
end

function WR.ShowPopup(who, what)
  if not WR.config.popup then return end
  local f = WR.BuildPopup()
  f.who:SetText("on " .. tostring(who))
  f.what:SetText(what)
  -- Re-raised rather than stacked: a second pop replaces the first and gets
  -- the full time again.
  WR.popupUntil = GetTime() + (WR.config.popupSeconds or 60)
  f:Show()
end

--- An alert arriving from the other client. Loud, and nobody to reply to.
function WR.ShowAlert(message, sender)
  local text = message or ""
  if string.sub(text, 1, string.len(ALERT)) ~= ALERT then return false end
  local body = string.gsub(string.sub(text, string.len(ALERT) + 1), "^%s+", "")

  DEFAULT_CHAT_FRAME:AddMessage("|cffff8000[" .. tostring(sender) ..
    "]  " .. body .. "|r")
  WR.ShowPopup(sender, body)
  if PlaySound then pcall(PlaySound, "ReadyCheck") end
  -- Worth a try when the window is not even focused; absent on some clients.
  if FlashClientIcon then pcall(FlashClientIcon) end
  return true
end

function WR.OnWhisper(message, sender)
  if not WR.ready then return end

  -- Before the forward checks, and before the target check: this is the
  -- window being told, not the one doing the telling.
  if WR.ShowAlert(message, sender) then return end

  --[[ Before anything else, and before the target check: the character you
       are PLAYING is usually the one with no target of its own, and it is the
       one that needs the clickable name. ]]
  local fwd = WR.ParseForward(message)
  if fwd then
    WR.pending = { name = fwd, sender = sender, message = message }
    return
  end

  if not WR.config.enabled then return end

  --[[ Resolved once per whisper. In auto mode this is nil whenever the other
       client is not running, and that is the right answer: with nobody at the
       other end there is nothing to forward to, and telling the sender to go
       whisper a character who is offline would be worse than saying nothing. ]]
  local target = WR.Target()
  if not target then return end
  if WR.IsLoop(sender, message, target) then return end

  for _, part in ipairs(WR.Parts(sender, message or "")) do
    WR.Queue(part, target)
  end

  if WR.config.announce then
    DEFAULT_CHAT_FRAME:AddMessage(DIM .. "forwarded " .. sender .. " to " ..
      target .. "|r")
  end

  if WR.ShouldReply(sender, target) then
    WR.replied[sender] = time()
    WR.Queue(WR.ReplyBody(target), sender)
  end
end

----------------------------------------------------------------------
-- noticing that the target cannot be reached
----------------------------------------------------------------------

--[[ A misspelled or logged-out target is the worst failure this addon has:
     whispers are consumed and forwarded to nobody, and nothing on screen says
     so. The server does say so -- as a system message -- so watch for it.

     Built from the client's own string rather than a copy of it, so it cannot
     drift out of step with the client. ]]
function WR.NotFoundName(msg)
  local fmt = ERR_CHAT_PLAYER_NOT_FOUND_S
    or "No player named '%s' is currently playing."
  local pat = string.gsub(fmt, "([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
  pat = string.gsub(pat, "%%%%s", "(.+)")
  local _, _, name = string.find(msg or "", pat)
  if not name then return nil end
  -- The client quotes the name in some phrasings and not others.
  return (string.gsub(name, "^['\"]*(.-)['\"]*$", "%1"))
end

--[[ A refusal is remembered rather than acted on once, because auto mode
     would otherwise pick the same logged-out character straight back out of
     the presence file: their last heartbeat is still inside the three-minute
     window, and stays inside it for three more minutes. A heartbeat NEWER
     than the refusal clears it, which is what happens when they log in. ]]
--[[ Stop, rather than keep shouting into the void.

     One forward that goes nowhere is a message lost. The next twenty are the
     same message lost twenty times over, one server error each, while you
     carry on believing you are covered. So the first refusal ends it: the
     queue for that character is dropped on the floor rather than delivered
     to nobody, and forwarding stops until there is somewhere for it to go. ]]
function WR.TargetGone(name)
  local kept, dropped = {}, 0
  for i = 1, table.getn(WR.queue) do
    local job = WR.queue[i]
    if job.target == name then dropped = dropped + 1
    else table.insert(kept, job) end
  end
  WR.queue = kept

  WR.offline[name] = time()
  WR.autoName, WR.autoAt = nil, nil

  local lost = (dropped > 0)
    and ("  " .. dropped .. " queued message(s) were not sent.") or ""

  if WR.config.auto then
    --[[ Nothing to disable: auto mode simply has no target now, and picks up
         whoever is next to say they are here. A spelling mistake is not the
         explanation either -- the name came from the other client itself. ]]
    local next_ = WR.Target()
    Print(WARN .. name .. " is not online|r any more." .. lost ..
      (next_ and ("  Forwarding to " .. OK .. next_ .. "|r instead.")
             or "  Nothing is being forwarded until another client appears."))
  else
    WR.config.enabled = false
    Print(WARN .. name .. " is not online|r, so forwarding is now off." .. lost ..
      "  |cffe0a22c/wf to <character>|r to point it somewhere, or " ..
      "|cffe0a22c/wf on|r to try again.")
  end
end

function WR.OnSystem(msg)
  if not WR.ready then return end
  local target = WR.Target()
  if not target then return end
  local name = WR.NotFoundName(msg)
  if not name or string.lower(name) ~= string.lower(target) then return end

  -- The server repeats this for every forward still in flight; the first one
  -- has already stopped everything, so the rest are noise.
  if WR.offline[target] and (time() - WR.offline[target]) < 60 then return end
  WR.TargetGone(target)
end

----------------------------------------------------------------------
-- commands
----------------------------------------------------------------------

--[[ Proves, without needing anyone to whisper you, which of three things is
     wrong when the name is not clickable: nothing printed at all means the
     addon is not loaded; a line that shows the raw escapes means this chat
     frame is not turning links into links; a proper [name] that does nothing
     when clicked means the click is not reaching the client handler. ]]
function WR.Demo()
  local name = UnitName("player") or "Nobody"
  Print("chat hook installed: " .. (WR.hooked and "yes" or "NO") ..
    ", inline: " .. (WR.config.inline and "on" or "off"))
  DEFAULT_CHAT_FRAME:AddMessage(WR.InlineText(name, "this is what a forward looks like", "TestChar"))
  WR.handleFor = nil
  WR.ShowHandle(name, "TestChar")
  Print("click " .. name .. " above. If it is not clickable, send me this line:")
  DEFAULT_CHAT_FRAME:AddMessage((string.gsub(WR.NameLink(name), "|", "||")))
end

local function Status()
  Print("v" .. WR.version .. " on " .. tostring(WR.me))

  local target = WR.Target()
  if WR.config.auto then
    if not WR.FileAPI() then
      Print(WARN .. "automatic, but there is no file API|r -- this needs " ..
        "Nampower, or name one with |cffe0a22c/wf to <character>|r")
    elseif target then
      Print("forwarding to " .. OK .. target .. "|r, found automatically -- " ..
        (WR.config.enabled and "enabled" or WARN .. "disabled|r"))
    else
      Print("automatic, and " .. DIM .. "no other character is logged in|r " ..
        "right now, so nothing is being forwarded")
    end

    -- Everyone the shared file has heard from, so a missing client is obvious.
    local now, any = time(), false
    for name, stamp in pairs(WR.ReadPresence()) do
      local age = now - stamp
      Print(DIM .. "  " .. name .. (name == WR.me and " (this one)" or "") ..
        ", last seen " .. age .. "s ago" ..
        (age < 180 and "" or " -- too long ago to count") .. "|r")
      any = true
    end
    if not any then
      Print(DIM .. "  nothing in the shared file yet; it is written a minute " ..
        "after login|r")
    end

  elseif not WR.config.target then
    Print(WARN .. "no forward target set|r -- " ..
      "|cffe0a22c/wf to <character>|r, or |cffe0a22c/wf auto|r")
  else
    Print("forwarding to " .. OK .. WR.config.target .. "|r, named by hand -- " ..
      (WR.config.enabled and "enabled" or WARN .. "disabled|r"))
  end
  Print("auto-answer the sender: " ..
    (WR.config.autoReply and ("on, once per " ..
      WR.config.replyCooldown .. "s per person") or "off"))
  if WR.config.autoReply then
    Print(DIM .. "  \"" .. WR.ReplyBody() .. "\"|r")
  end
  Print("clickable name: " ..
    (WR.config.inline and "in the message" or "on a line underneath") ..
    ", chat hook: " .. (WR.hooked and "installed" or WARN .. "not installed|r"))
  local n = table.getn(WR.queue)
  if n > 0 then Print(n .. " message(s) still going out") end
end

local function Usage()
  Print("|cffe0a22c/wf auto|r -- find your other character instead of naming one")
  Print("|cffe0a22c/wf list|r, |cffe0a22c/wf forget <character>|r -- the names it has learned")
  Print("|cffe0a22c/wf to <character>|r -- forward whispers to that character")
  Print("|cffe0a22c/wf|r status  |  on  |  off  |  reply  |  echo  |  link  |  test")
  Print("|cffe0a22c/wf reply <text>|r -- what to tell the sender ({char} = target)")
  Print("|cffe0a22c/wf every <seconds>|r -- how often to answer one person")
  Print("|cffe0a22c/wf link|r -- the clickable name under an arriving forward")
  Print("|cffe0a22c/wf inline|r -- clickable name in the message, or underneath")
  Print("|cffe0a22c/wf demo|r -- show what a forward looks like, to test clicking")
  Print("|cffe0a22c/wf alerts|r, |cffe0a22c/wf popup|r -- battleground and dungeon pops")
  Print("|cffe0a22c/wf testpop|r -- show the popup now")
end

function WR.Command(input)
  local msg = input or ""
  local cmd = string.lower((string.gsub(msg, "%s.*$", "")))
  local rest = string.gsub(msg, "^%S*%s*", "")

  if cmd == "" or cmd == "status" then
    Status()

  elseif cmd == "to" then
    local name = string.gsub(rest, "%s.*$", "")
    if name == "" then
      Print("usage: /wf to <character>")
    elseif name == WR.me then
      Print(WARN .. "that is this character|r -- forwarding would loop.")
    else
      WR.config.target = name
      WR.config.enabled = true
      WR.offline[name] = nil
      WR.Remember(name, true)
      -- Naming one explicitly is the point of naming one.
      WR.config.auto = false
      Print("forwarding whispers to " .. OK .. name .. "|r.")
    end

  elseif cmd == "on" then
    WR.config.enabled = true
    -- Turning it back on means "try them again", so forget the refusal.
    WR.offline = {}
    WR.autoName, WR.autoAt = nil, nil
    Print(WR.config.target and ("forwarding to " .. WR.config.target .. ".")
      or "enabled, but no target yet: /wf to <character>")

  elseif cmd == "off" then
    WR.config.enabled = false
    Print("forwarding off.")

  elseif cmd == "reply" then
    --[[ "off" reads as an instruction, not as the message to send. Taking it
         literally sets the auto-answer to the word "off" and leaves it ON,
         which is the exact opposite of what was asked, and says so to the
         next person who whispers you. ]]
    local word = string.lower(rest)
    if word == "off" or word == "on" then
      WR.config.autoReply = (word == "on")
      Print("auto-answer: " .. (WR.config.autoReply and "on" or "off"))
    elseif rest == "" then
      WR.config.autoReply = not WR.config.autoReply
      Print("auto-answer: " .. (WR.config.autoReply and "on" or "off"))
    else
      WR.config.replyText = rest
      WR.config.autoReply = true
      Print("auto-answer: " .. DIM .. WR.ReplyBody() .. "|r")
    end

  elseif cmd == "every" then
    local n = tonumber((string.gsub(rest, "%s.*$", "")))
    if not n or n < 0 then
      Print("usage: /wf every <seconds>")
    else
      WR.config.replyCooldown = n
      Print("answering one person at most once every " .. n .. "s.")
    end

  elseif cmd == "auto" then
    WR.config.auto = not WR.config.auto
    WR.autoName, WR.autoAt = nil, nil
    if WR.config.auto then
      WR.sinceBeat = BEAT
      WR.Beat(0)
      local found = WR.Target()
      Print("finding your other character automatically" ..
        (found and (": " .. OK .. found .. "|r") or
          " -- nobody else logged in yet"))
    else
      Print("using the character you name: " ..
        (WR.config.target or "none set yet, /wf to <character>"))
    end

  elseif cmd == "popup" then
    WR.config.popup = not WR.config.popup
    if not WR.config.popup then WR.HidePopup() end
    Print("on-screen popup when something pops: " ..
      (WR.config.popup and "on" or "off"))

  elseif cmd == "testpop" then
    -- Proves the popup without waiting for a queue, and drives the same
    -- function a real alert does.
    WR.ShowAlert(">! this is what a queue pop looks like", WR.me)

  elseif cmd == "list" then
    local known = WR.config.known or {}
    if table.getn(known) == 0 then
      Print("no characters known yet. |cffe0a22c/wf to <character>|r, or " ..
        "log one in beside this client.")
    else
      -- Live means "said so in the shared folder recently", which is the
      -- only thing this addon actually knows.
      local seen, now = WR.ReadPresence(), time()
      Print("characters seen on this machine, most recent first:")
      for i = 1, table.getn(known) do
        local n = known[i]
        local stamp = seen[n]
        local live = stamp and (now - stamp) < LIVE
        DEFAULT_CHAT_FRAME:AddMessage("   " ..
          (live and (OK .. n .. "|r  logged in")
                 or (DIM .. n .. "  not logged in|r")))
      end
    end

  elseif cmd == "forget" then
    local name = string.gsub(rest, "%s.*$", "")
    if name == "" then
      Print("usage: /wf forget <character>, or /wf forget all")
    elseif string.lower(name) == "all" then
      WR.config.known = {}
      Print("forgot every remembered character.")
    else
      WR.Forget(name)
      Print("forgot " .. name .. ".")
    end

  elseif cmd == "alerts" then
    WR.config.alerts = not WR.config.alerts
    Print("telling the other window about pops: " ..
      (WR.config.alerts and "on" or "off"))

  elseif cmd == "inline" then
    WR.config.inline = not WR.config.inline
    Print("clickable name inside the message: " ..
      (WR.config.inline and "on" or "off (a line underneath instead)"))

  elseif cmd == "demo" then
    WR.Demo()

  elseif cmd == "link" then
    WR.config.replyLink = not WR.config.replyLink
    Print("clickable name under an arriving forward: " ..
      (WR.config.replyLink and "on" or "off"))

  elseif cmd == "echo" then
    WR.config.announce = not WR.config.announce
    Print("echo forwards in this window: " ..
      (WR.config.announce and "on" or "off"))

  elseif cmd == "test" then
    --[[ Verifying this for real means finding someone to whisper you. The
         test drives the same handler a real whisper does, so a target that is
         misspelled or offline fails here exactly as it would then. ]]
    local target = WR.Target()
    if not target then
      Print(WR.config.auto
        and "no other character is logged in, so there is nowhere to send it."
        or "set a target first: /wf to <character>")
    else
      WR.replied["WhisperRelayTest"] = nil
      WR.OnWhisper("test message from /wf test", "WhisperRelayTest")
      Print("sent a test forward to " .. target .. ". Check that window.")
    end

  else
    Usage()
  end
end

----------------------------------------------------------------------
-- wiring
----------------------------------------------------------------------

local frame = CreateFrame("Frame", "WhisperRelayFrame")
WR.frame = frame

frame:RegisterEvent("VARIABLES_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("CHAT_MSG_WHISPER")
frame:RegisterEvent("CHAT_MSG_SYSTEM")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("UPDATE_BATTLEFIELD_STATUS")
frame:RegisterEvent("CHAT_MSG_ADDON")

function WR.Init()
  if WR.ready then return end

  WhisperRelayDB = WhisperRelayDB or {}
  for k, v in pairs(defaults) do
    if WhisperRelayDB[k] == nil then WhisperRelayDB[k] = v end
  end
  WR.config = WhisperRelayDB
  WR.me = UnitName("player") or "Unknown"
  WR.ready = true

  if WR.config.target == WR.me then
    -- Saved per account, so logging in on the target itself is normal.
    WR.config.target = nil
  end

  --[[ Say we are here straight away rather than in a minute: the other client
       is probably already waiting to find out, and a whisper arriving in the
       first minute would otherwise have nowhere to go. ]]
  WR.sinceBeat = BEAT
  WR.Beat(0)

  if WR.config.auto and WR.FileAPI() then
    Print("v" .. WR.version .. " on " .. WR.me ..
      ", forwarding to whichever character you are playing. " ..
      "|cffe0a22c/wf|r for status.")
  elseif WR.config.auto then
    Print("v" .. WR.version .. " ready, but automatic needs Nampower's file " ..
      "API. Name one instead: |cffe0a22c/wf to <character>|r")
  elseif WR.config.target then
    Print("v" .. WR.version .. " forwarding whispers to " .. OK ..
      WR.config.target .. "|r. |cffe0a22c/wf|r for status.")
  else
    Print("v" .. WR.version .. " ready. Set where whispers go: " ..
      "|cffe0a22c/wf to <character>|r")
  end
end

frame:SetScript("OnEvent", function()
  if event == "VARIABLES_LOADED" or event == "PLAYER_LOGIN" then
    WR.Init()
  elseif event == "PLAYER_ENTERING_WORLD" then
    -- Late on purpose: whatever chat addon is going to replace
    -- ChatFrame_OnEvent has done so by now, so we wrap theirs rather than
    -- having ours thrown away.
    WR.InstallChatHook()
  elseif event == "CHAT_MSG_WHISPER" then
    WR.OnWhisper(arg1, arg2)
  elseif event == "CHAT_MSG_SYSTEM" then
    WR.OnSystem(arg1)
  elseif event == "UPDATE_BATTLEFIELD_STATUS" then
    WR.OnBattlefield()
  elseif event == "CHAT_MSG_ADDON" then
    WR.OnAddonMessage(arg1, arg2)
  end
end)

frame:SetScript("OnUpdate", function()
  if not WR.ready then return end
  WR.Settle()
  WR.Beat(arg1 or 0)
  WR.Flush(arg1 or 0)
end)

SLASH_WHISPERRELAY1 = "/wf"
SLASH_WHISPERRELAY2 = "/whisperforward"
SlashCmdList["WHISPERRELAY"] = function(msg) WR.Command(msg) end
