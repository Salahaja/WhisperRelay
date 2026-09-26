--[[ Whisper Relay

A whisper arriving on one of your windows is forwarded to every other one
running on this machine. Four accounts means three windows you are not looking
at, and whichever one you happen to be in front of has the message. The
forward carries who it came from, with the name clickable, so you can answer
from there.

It can also answer the sender for you, telling them which character you are on
so they stop whispering the one nobody is watching. Off by default: that is a
bot reply appearing in someone else's window, which should be a decision.

Between your windows nothing is whispered at all: they send each other addon
messages (the quiet channel, below), which no chat frame shows, so none of the
back and forth clutters chat - and they need no party or guild in common.
A window running an older copy, or with quiet off, gets an ordinary whisper,
and so does the sender's auto-answer, which is for a person. Working out WHO
to forward to on its own needs the shared folder, and naming a character by
hand replaces that.

Loops are the danger here. Every client forwarding to every other is the
arrangement out of the box, and it is also the obvious way to bounce one
message around the ring until the server disconnects all of them for spam. So
three things are never forwarded: anything from ANY of the windows we forward
to, anything already carrying a relay marker, and ourselves.
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

--[[ Group chat gets a third marker, for the same reason alerts got a second:
     it is a different kind of thing arriving and reads differently. A whisper
     was addressed to you and wants an answer; a line of party chat was said to
     a room you are not standing in. ]]
local GROUP = ">#"

--[[ "Say this for me."

     Clicking a forwarded name answers from the window you are sitting in, so
     the person who wrote to Salahaja gets a reply from Salabeard -- a
     different character, and usually a confusing one. This marker asks the
     window they actually wrote to to say it instead, so the conversation
     stays where they started it.

     Only ever honoured from one of our own windows. A line like this from a
     stranger would be an instruction to whisper arbitrary text to an
     arbitrary person, in your name. ]]
local RELAY = ">@"

--[[ "Say this in your group."

     The other half of forwarding party chat. Reading what the group said from
     a window that is not in it leaves you able to hear and not answer, which
     is worse than not hearing: you know a decision is being made and have to
     alt-tab to join in.

     The window that IS in the group says it, so to everyone there it is
     simply the character they are grouped with talking. It carries no channel
     of its own -- that window knows whether it is in a party or a raid far
     better than this one does.

     Same rule as RELAY: honoured only from one of our own windows. ]]
--[[ NOT "%" as the second character, whatever else changes here.

     WoW expands substitution tokens in outgoing chat, and %t is the one for
     your current target. A marker of ">%" turns "/wp tanything" into the
     whisper ">%tanything", the client reads the "%t", finds nothing selected
     and refuses the whole message with "no target" -- so every sentence
     beginning with t failed and nothing else did.

     None of the other markers contain a %, and none of them should. ]]
local SAY = ">+"

--[[ "Say this in your guild." SAY's twin: a party and a guild are different
     rooms, and the window in one need not be in the other, so each request
     names its own. Honoured only from one of our own windows, like both of
     the others. ]]
local GUILD_SAY = ">$"

--[[ Party chat is not one message an hour like a whisper -- a busy run is a
     line every few seconds, and every forwarded line is a whisper of its own.
     Left ungoverned that is a flood, and the client's own protection answers
     a flood by silently dropping what you send.

     So there is a ceiling. Past it the forwarding stops and says so once,
     rather than quietly sending half of everything. ]]
local GROUP_MAX_PER_MIN = 25
local GROUP_MUTE_FOR = 120

--[[ The stock answer. Kept as a constant so "use the default" is always the
     same thing, however many times it has been switched away from. ]]
local DEFAULT_REPLY = "Not watching this one right now - I'm on {char}, whisper me there."

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
  -- Off by default: answering someone who whispered you is a bot reply in
  -- their window, and that should be a decision, not a surprise.
  autoReply = false,
  -- {char} is filled in with the target. Kept as a token so the text stays
  -- correct after the target changes.
  --[[ Two fields rather than one, so switching back to the default does not
       throw away what you had typed. Coming back to Custom finds it again. ]]
  replyDefault = true,
  replyText = "Busy on another character - whisper {char} instead.",
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
  --[[ Off by default. A busy group is a line every few seconds and every one
       becomes a whisper, which is a lot of traffic to turn on for somebody
       without asking. ]]
  groupChat = false,
  -- Off by default for the same reason: a guild talks all day.
  guildChat = false,
  --[[ Your windows send each other addon messages rather than whispers, so
       the relay's own traffic stays out of chat. Off goes back to whispers
       for everything. ]]
  quiet = true,
  -- Open the relay window on the window a whisper is forwarded to.
  openChat = true,
  -- The minimap button, and where round the edge it sits: degrees, 0 is east.
  minimap = true,
  minimapAngle = 225,
}

----------------------------------------------------------------------

local function Print(msg)
  DEFAULT_CHAT_FRAME:AddMessage("|cff8fd0ffWhisperRelay|r " .. msg)
end
WR.Print = Print

----------------------------------------------------------------------
-- sending
----------------------------------------------------------------------

--- `person` for someone who is not one of your windows: always a whisper.
function WR.Queue(text, target, person)
  table.insert(WR.queue, { text = text, target = target, person = person })
end

--[[ Each message goes the way WR.Route says, decided as it leaves rather than
     as it is queued, because a window's answer can arrive in between.
     Addon messages go at once, every piece: the server does not count them
     as chat for flooding, and the inspect window sends dozens back to back.
     Whispers still go one at a time, SEND_GAP apart. A window yet to answer
     holds up its own messages and nobody else's. ]]
function WR.Flush(step)
  WR.sinceSend = WR.sinceSend + (step or 0)
  local i = 1
  while i <= table.getn(WR.queue) do
    local job = WR.queue[i]
    local route = WR.Route(job)
    if route == "addon" then
      table.remove(WR.queue, i)
      WR.SendQuiet(job)
    elseif route == "whisper" and WR.sinceSend >= SEND_GAP then
      table.remove(WR.queue, i)
      WR.sinceSend = 0
      SendChatMessage(job.text, "WHISPER", nil, job.target)
    else
      i = i + 1
    end
  end
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

----------------------------------------------------------------------
-- the quiet channel: your windows, without whispers
----------------------------------------------------------------------

--[[ Every forward, answer, pop and line of party chat between your own
     windows used to be a whisper, and a whisper shows up twice: "To Salahaja:
     >> Bobby: ..." in the window sending it, and the whisper itself in the
     window getting it. With two or three windows relaying, that was most of
     what the chat frame said.

     So they travel as addon messages, which no chat frame shows. On 1.12 an
     addon message only goes over a party, raid, battleground or guild
     channel, and to everyone on it -- but this server adds a way to send one
     to a single player by name, grouped, guilded or not: a GUILD message
     whose prefix is "TW_CHAT_MSG_WHISPER<Name>" is taken out of the guild
     traffic and handed to Name alone. The inspect window's talent tab runs on
     it. It arrives with the prefix "TW_CHAT_MSG_WHISPER", a tab in front of
     the text and the real sender's name, and when Name is not online the
     server answers "Error:CantFindPlayer:Name" the same way.

     The server cuts the name out of the prefix at EVERY ">" and refuses the
     message if there is more than one, so what we send never contains one --
     nor anything another of its handlers would take for its own. WR.Encode.

     Nothing goes to a window until it has answered a hello. A window running
     an older copy, one with quiet switched off, a server without this, or a
     person rather than one of your windows would swallow an addon message
     without a trace -- so a window's messages wait for its answer (a moment,
     the first time), and one that never answers is whispered, as before. ]]
local TW_WHISPER = "TW_CHAT_MSG_WHISPER"
local QUIET_TAG = "WRq"
local QUIET_MAX = 244      -- one addon message, prefix and all; the client stops at 254
local QUIET_ASK = 3        -- seconds a first message waits for the answer
local QUIET_RETRY = 60     -- a window that did not answer is asked again after this
local QUIET_PIECES = 2400  -- more than a whisper cut in three; beyond it, not ours

WR.peers = {}              -- lower-case name -> what we know of that window
WR.partial = {}            -- lower-case sender -> a long message so far
WR.uptime = 0              -- seconds of OnUpdate: the clock every wait here runs on

--[[ Escaped: ">" (the server's separator), "|" (so a link travels intact
     whatever the client makes of it), "_" (so no "TW_..." handler of the
     server's takes the text for its own), "&" (the escape itself), and line
     breaks. A hardcore character's addon message is dropped outright if it
     says "LFT" anywhere, so that is broken up too. ]]
local QUIET_ESCAPE = { ["&"] = "&a", [">"] = "&g", ["|"] = "&p", ["_"] = "&u" }
local QUIET_UNESCAPE = { a = "&", g = ">", p = "|", u = "_", t = "T" }

function WR.Encode(text)
  text = string.gsub(text or "", "[\r\n\t]", " ")
  text = string.gsub(text, "[&>|_]", function(c) return QUIET_ESCAPE[c] end)
  text = string.gsub(text, "LFT", "LF&t")
  return text
end

function WR.Decode(text)
  -- Always a string back: in the client's Lua, a nil here would become "".
  return (string.gsub(text or "", "&(.)", function(c)
    return QUIET_UNESCAPE[c] or c
  end))
end

function WR.QuietAPI()
  return type(SendAddonMessage) == "function"
end

function WR.QuietOn()
  if not WR.config or not WR.config.quiet then return false end
  return WR.QuietAPI()
end

--- What we know of one of your windows, made on first mention.
function WR.Peer(name)
  local key = string.lower(name)
  local p = WR.peers[key]
  if not p then
    p = { name = name }
    WR.peers[key] = p
  end
  return p
end

--- One addon message to one character, through the server.
function WR.QuietSend(target, kind, text)
  pcall(SendAddonMessage, TW_WHISPER .. "<" .. target .. ">",
    QUIET_TAG .. kind .. (text or ""), "GUILD")
end

--- Ask a window whether it takes addon messages; WR.OnQuiet hears the answer.
function WR.Hello(target)
  if not WR.QuietOn() or not target or target == WR.me then return end
  WR.Peer(target).asked = WR.uptime
  WR.QuietSend(target, "h")
end

--[[ Hello to ourselves. The server handing it straight back is the proof it
     passes these at all, whoever else is logged in. ]]
function WR.Ping()
  if not WR.QuietOn() then return end
  WR.quietWorks, WR.pingAt = nil, WR.uptime
  WR.QuietSend(WR.me, "p")
end

--[[ How one message goes: "addon", "whisper", or "wait" for its window to
     answer a hello. A message for a person -- the sender's auto-answer -- is
     always a whisper: they are not one of your windows, and an addon message
     would reach them as nothing at all. ]]
function WR.Route(job)
  if job.person or not WR.QuietOn() then return "whisper" end
  local p = WR.Peer(job.target)
  if p.state == "yes" then return "addon" end
  if p.state == "no" then
    -- Asked again now and then, without holding anything up for it.
    if WR.uptime - (p.asked or 0) >= QUIET_RETRY then WR.Hello(job.target) end
    return "whisper"
  end
  if p.state == "offline" then
    --[[ What was waiting when the server said so goes as a whisper, and is
         refused like one. After that, it may well have logged in. ]]
    if WR.uptime - p.at < QUIET_ASK then return "whisper" end
    p.state, p.asked = nil, nil
  end
  if not p.asked then
    WR.Hello(job.target)
    return "wait"
  end
  if WR.uptime - p.asked < QUIET_ASK then return "wait" end
  p.state = "no"
  return "whisper"
end

--- One message as addon messages, in pieces when it will not fit in one.
function WR.SendQuiet(job)
  local rest = WR.Encode(job.text)
  local room = QUIET_MAX - string.len(TW_WHISPER .. "<" .. job.target .. ">")
    - string.len(QUIET_TAG) - 1
  while string.len(rest) > room do
    -- Never between the bytes of one letter.
    local cut = room
    while cut > 1 do
      local b = string.byte(rest, cut + 1)
      if not b or b < 128 or b >= 192 then break end
      cut = cut - 1
    end
    WR.QuietSend(job.target, "c", string.sub(rest, 1, cut))
    rest = string.sub(rest, cut + 1)
  end
  WR.QuietSend(job.target, "m", rest)
  WR.Peer(job.target).sent = WR.uptime
end

--[[ An addon message on the server's whisper prefix. The inspect window and
     other addons use the prefix too, each with words of its own; they ignore
     ours as we ignore theirs.

     h  hello: do you take these?      a  yes          o  no, quiet is off
     b  logging out, or a /reload      p  our own hello, back from the server
     c  a piece of a long message      m  a message, or the last piece of one ]]
function WR.OnQuiet(message, sender)
  if not WR.ready or type(message) ~= "string" then return end

  local _, _, missing = string.find(message, "^Error:CantFindPlayer:(.+)$")
  if missing then
    WR.QuietMissing(missing)
    return
  end

  local _, _, kind, text = string.find(message, "^\t?" .. QUIET_TAG .. "(%a)(.*)$")
  if not kind or type(sender) ~= "string" or sender == "" then return end

  if sender == WR.me then
    if kind == "p" then WR.quietWorks = true end
    return
  end

  local key = string.lower(sender)
  local p = WR.Peer(sender)
  if kind == "b" then
    p.state, p.asked, WR.partial[key] = nil, nil, nil
    return
  elseif kind == "o" then
    p.state, p.asked, WR.partial[key] = "no", WR.uptime, nil
    return
  end

  p.state = "yes"
  if kind == "h" then
    WR.QuietSend(sender, WR.QuietOn() and "a" or "o")
  elseif not WR.QuietOn() and WR.uptime - (p.toldOff or -QUIET_ASK) >= QUIET_ASK then
    --[[ Quiet is off here, but they think otherwise -- they answered a hello
         sent before it was switched off. Say so, once in a while; what they
         sent is still shown below. ]]
    p.toldOff = WR.uptime
    WR.QuietSend(sender, "o")
  end
  if kind == "c" then
    local sofar = (WR.partial[key] or "") .. text
    if string.len(sofar) > QUIET_PIECES then sofar = nil end
    WR.partial[key] = sofar
  elseif kind == "m" then
    local whole = (WR.partial[key] or "") .. text
    WR.partial[key] = nil
    WR.FromWindow(WR.Decode(whole), sender)
  end
end

--[[ The server could not find a character we sent to. If a message went to
     it just now, that message is lost -- as a whisper to someone offline
     would be -- and is handled the same way. After nothing but a hello it
     simply has not logged in yet, which is not news. ]]
function WR.QuietMissing(name)
  local key = string.lower(name)
  local p = WR.peers[key]
  if not p then return end
  WR.partial[key] = nil
  local lost = p.sent and (WR.uptime - p.sent) < 10
  p.state, p.at, p.sent = "offline", WR.uptime, nil
  if lost and not WR.Refused(name) then
    Print(WARN .. name .. " is not online|r -- a message for it was not delivered.")
  end
end

--[[ A message from one of your windows over the quiet channel: the same
     kinds of thing a whisper from one could be, handled by the same code.
     The one difference is that the chat frame showed nothing for it on the
     way in, so a forward is shown here -- as the chat hook shows one that
     arrives as a whisper, sound included. ]]
function WR.FromWindow(message, from)
  if WR.ShowAlert(message, from) then return end
  if WR.ShowGroupChat(message, from) then return end
  if WR.OnRelayRequest(message, from) then return end
  if WR.OnSayRequest(message, from) then return end
  if WR.OnGuildSayRequest(message, from) then return end
  local name, body = WR.ParseForward(message)
  if not name then return end
  WR.lastForward = { from = name, via = from }
  DEFAULT_CHAT_FRAME:AddMessage(WR.InlineText(name, body, from))
  WR.ChatAdd(WR.WindowLine(from, "whisper", name, body), "whisper")
  WR.PopChat()
  if PlaySound then pcall(PlaySound, "TellMessage") end
end

--[[ At every loading screen, hello to the windows we forward to that have
     not answered yet, so the first whisper to arrive is not the one kept
     waiting -- and once a login, prove the server passes these at all. ]]
function WR.QuietStart()
  if not WR.ready or not WR.QuietOn() then return end
  if not WR.pingAt then WR.Ping() end
  local targets = WR.Targets()
  for i = 1, table.getn(targets) do
    if WR.Peer(targets[i]).state ~= "yes" then WR.Hello(targets[i]) end
  end
  --[[ Not cached: at login the other windows may not have said they are
       here yet, and a remembered "nobody" would outlast them. ]]
  WR.others, WR.othersAt = nil, nil
end

--- Quiet switched on or off: tell your other windows now.
function WR.QuietChanged()
  WR.partial = {}
  if WR.config.quiet then
    WR.peers, WR.pingAt, WR.quietWorks = {}, nil, nil
    WR.QuietStart()
  else
    for _, p in pairs(WR.peers) do
      if p.state == "yes" then WR.QuietSend(p.name, "o") end
    end
    WR.peers = {}
  end
end

--- Logging out, or a /reload: the windows we talk to go back to asking.
function WR.QuietLogout()
  if not WR.QuietOn() then return end
  for _, p in pairs(WR.peers) do
    if p.state == "yes" then WR.QuietSend(p.name, "b") end
  end
end

--- The quiet channel's line in /wf status.
function WR.QuietStatus()
  if not WR.config.quiet then
    return "quiet: off -- your windows whisper each other"
  end
  if not WR.QuietAPI() then
    return "quiet: on, " .. WARN .. "but this client has no addon messages|r" ..
      " -- whispering instead"
  end
  if not WR.quietWorks and WR.pingAt and (WR.uptime - WR.pingAt) >= QUIET_ASK then
    return "quiet: on, " .. WARN .. "but the server did not pass a test message " ..
      "back|r -- whispering instead"
  end
  local yes, no, waiting = {}, {}, {}
  local targets = WR.Targets()
  for i = 1, table.getn(targets) do
    local p = WR.peers[string.lower(targets[i])]
    if p and p.state == "yes" then table.insert(yes, targets[i])
    elseif p and p.state == "no" then table.insert(no, targets[i])
    else table.insert(waiting, targets[i]) end
  end
  local parts = {}
  if table.getn(yes) > 0 then
    table.insert(parts, "no whispers to " .. table.concat(yes, ", "))
  end
  if table.getn(no) > 0 then
    table.insert(parts, table.concat(no, ", ") .. " did not answer (an older " ..
      "copy, or quiet off there), so it is whispered")
  end
  if table.getn(waiting) > 0 then
    table.insert(parts, "waiting to hear from " .. table.concat(waiting, ", "))
  end
  if table.getn(parts) == 0 then
    table.insert(parts, DIM .. "no other window to talk to yet|r")
  end
  return "quiet: " .. OK .. "on|r -- " .. table.concat(parts, "; ")
end

--- The other character logged in right now, or nil if there isn't one.
--[[ EVERY other client on this machine, newest heartbeat first.

     All of them, not the likeliest one: running four accounts means three
     windows you are not looking at, and picking one leaves two that can still
     hide a whisper. Whichever window you happen to be in front of has it.

     Ordered by heartbeat because the first name is used wherever exactly one
     is needed -- the sender's auto-answer names a character to go to, and the
     most recently active one is the best guess at where you are. ]]
function WR.LiveOthers()
  local now = time()
  if WR.others and WR.othersAt and (now - WR.othersAt) < LOOKUP_CACHE then
    return WR.others
  end

  local found = {}
  for name, stamp in pairs(WR.ReadPresence()) do
    -- Every character that logs in beside this one is remembered, so the list
    -- builds itself across however many accounts are running.
    WR.Remember(name, false)

    --[[ Skip anyone the server has since refused, unless they have said they
         are here again SINCE that refusal. Without the second half this
         picks the logged-out character straight back up: their last
         heartbeat is still recent, and stays recent for three more minutes. ]]
    local refused = WR.offline[name]
    local gone = refused and stamp <= refused
    if name ~= WR.me and not gone and (now - stamp) < LIVE then
      table.insert(found, { name = name, at = stamp })
    end
  end

  table.sort(found, function(a, b) return a.at > b.at end)

  local names = {}
  for i = 1, table.getn(found) do names[i] = found[i].name end
  WR.others, WR.othersAt = names, now
  return names
end

--- The single most recently active other client, or nil.
function WR.AutoTarget()
  local live = WR.LiveOthers()
  return live[1]
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
--[[ A character name the way the server writes it: a capital, then small
     letters. A name typed "salahaja" still reaches Salahaja -- the server
     fixes it up -- but everything that comes back is "Salahaja", and a
     comparison against what was typed then fails. Only A-Z is touched, so
     the bytes of an accented letter are never bent out of shape. ]]
function WR.Canonical(name)
  local first = string.sub(name, 1, 1)
  if string.find(first, "^[a-z]$") then first = string.upper(first) end
  local rest = string.gsub(string.sub(name, 2), "[A-Z]", function(c)
    return string.lower(c)
  end)
  return first .. rest
end

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

--[[ Everywhere a forward should go.

     In automatic mode that is every other client on this machine. A name you
     typed by hand is one name, because you said one name. ]]
function WR.Targets()
  if WR.config.auto then
    local live = WR.LiveOthers()
    if table.getn(live) > 0 then return live end
    -- Auto mode with nobody else logged in means exactly that: nowhere.
    if WR.FileAPI() then return {} end
  end

  local named = WR.config.target
  if not named or WR.offline[named] then return {} end
  return { named }
end

--[[ Where a forward goes when exactly one name is needed: the auto-answer
     has to name one character for the sender to go to, and the most recently
     active window is the best guess at where you are.

     The shared folder decides, and only it. Deliberately nothing clever here:
     this machine's own clients are the only thing that can be known for
     certain, and guessing from anywhere else -- a guild roster, a name typed
     once -- risks forwarding private messages to somebody who merely happens
     to be online. ]]
function WR.Target()
  return WR.Targets()[1]
end

----------------------------------------------------------------------

--- Is this a message we must leave alone to avoid a loop?
function WR.IsLoop(sender, message, targets)
  if not sender or sender == "" then return true end
  if sender == WR.me then return true end

  --[[ Every one of them, not just the first. With four accounts running, a
       message from C is a message from one of our own windows however far
       down the list C happens to sit. ]]
  for i = 1, table.getn(targets or {}) do
    if sender == targets[i] then return true end
  end

  -- Already relayed once: someone else's relay, or ours coming back.
  local head = string.sub(message or "", 1, 2)
  if head == MARK or head == ALERT or head == GROUP or head == RELAY
     or head == SAY or head == GUILD_SAY then
    return true
  end
  return false
end

----------------------------------------------------------------------
-- group chat, to the window that is not in the group
----------------------------------------------------------------------

--[[ Who is in the party or raid with this character, by name.

     The whole point is to reach the windows that are NOT here. A character
     sitting in the same group already sees every line in its own chat, so
     forwarding to it would be an echo of something already on screen -- and
     with two of your characters in one group, an echo each way. ]]
function WR.GroupMembers()
  local here = {}
  local raid = (GetNumRaidMembers and GetNumRaidMembers()) or 0

  if raid > 0 then
    for i = 1, raid do
      local name = GetRaidRosterInfo and GetRaidRosterInfo(i)
      if name then here[name] = true end
    end
  else
    local party = (GetNumPartyMembers and GetNumPartyMembers()) or 0
    for i = 1, party do
      local name = UnitName("party" .. i)
      if name then here[name] = true end
    end
  end

  return here
end

--- The windows that would not otherwise hear this.
function WR.TargetsOutsideGroup()
  local here, out = WR.GroupMembers(), {}
  local targets = WR.Targets()
  for i = 1, table.getn(targets) do
    if not here[targets[i]] then table.insert(out, targets[i]) end
  end
  return out
end

--[[ Who is in the guild with this character, as far as the client's roster
     knows -- which is nothing until it has been asked for (WR.AskRoster).
     Until then nobody is known to be in it and every window gets the line,
     so one in the same guild sees it twice for a moment. Never not at all. ]]
function WR.GuildMembers()
  local here = {}
  if not GetNumGuildMembers or not GetGuildRosterInfo then return here end
  for i = 1, (GetNumGuildMembers() or 0) do
    local name = GetGuildRosterInfo(i)
    if name then here[name] = true end
  end
  return here
end

--- The windows that would not otherwise hear guild chat.
function WR.TargetsOutsideGuild()
  local here, out = WR.GuildMembers(), {}
  local targets = WR.Targets()
  for i = 1, table.getn(targets) do
    if not here[targets[i]] then table.insert(out, targets[i]) end
  end
  return out
end

--- Ask the server for the guild roster, if there is a guild to ask about.
function WR.AskRoster()
  if WR.config.guildChat and IsInGuild and IsInGuild() and GuildRoster then
    GuildRoster()
  end
end

--[[ Has this run away with itself? Counted over a rolling minute rather than
     per message, because the thing that trips flood protection is the rate,
     not any one line. Party and guild are counted apart: a busy guild must
     not silence the party you are standing in. ]]
local FLOW_WORDS = {
  group = "that group is talking faster than this can forward|r - group chat",
  guild = "the guild is talking faster than this can forward|r - guild chat",
}
WR.flow = {}

function WR.GroupAllowed(stream)
  stream = stream or "group"
  local now = time()
  local f = WR.flow[stream] or {}
  WR.flow[stream] = f

  if f.mutedUntil then
    if now < f.mutedUntil then return false end
    f.mutedUntil = nil
    f.count, f.window = 0, now
  end

  if not f.window or (now - f.window) >= 60 then
    f.window, f.count = now, 0
  end

  f.count = (f.count or 0) + 1
  if f.count > GROUP_MAX_PER_MIN then
    f.mutedUntil = now + GROUP_MUTE_FOR
    Print(WARN .. FLOW_WORDS[stream] .. " paused for " .. (GROUP_MUTE_FOR / 60) ..
      " minutes so the client does not start dropping what you send.")
    return false
  end

  return true
end

--- kind is one character: P party, R raid, W raid warning, G guild.
function WR.OnGroupChat(kind, message, sender)
  if not WR.ready or not WR.config.enabled then return end
  local guild = (kind == "G")
  if guild then
    if not WR.config.guildChat then return end
  elseif not WR.config.groupChat then
    return
  end
  if not sender or sender == WR.me then return end
  if not message or message == "" then return end

  local targets
  if guild then targets = WR.TargetsOutsideGuild() else targets = WR.TargetsOutsideGroup() end
  if table.getn(targets) == 0 then return end
  if not WR.GroupAllowed(guild and "guild" or "group") then return end

  --[[ Two separators then the rest, so a line containing one survives. Only
       the kind and the speaker's name are fielded, and a name cannot hold a
       separator. ]]
  local line = GROUP .. kind .. "~" .. sender .. "~" ..
    string.gsub(message, "%s+", " ")

  for i = 1, table.getn(targets) do
    WR.Queue(string.sub(line, 1, 250), targets[i])
  end
end

local KIND_LABEL = { P = "Party", R = "Raid", W = "Raid Warning" }
local KIND_COLOUR = { P = "|cffaaaaff", R = "|cffff7f00", W = "|cffff4444" }

--- A line of group chat arriving from a window that IS in one.
function WR.ShowGroupChat(message, via)
  local text = message or ""
  if string.sub(text, 1, string.len(GROUP)) ~= GROUP then return false end

  local body = string.sub(text, string.len(GROUP) + 1)
  local kind = string.sub(body, 1, 1)
  local rest = string.sub(body, 3)          -- skip the kind and its separator
  local sep = string.find(rest, "~", 1, true)
  if not sep then return true end

  local speaker = string.sub(rest, 1, sep - 1)
  local said = string.sub(rest, sep + 1)

  --[[ Guild chat goes to the relay window alone, on a tab of its own. A
       guild talks all day; the chat frame is for what is said to you. ]]
  if kind == "G" then
    WR.lastGuildFrom = via
    WR.ChatAdd(WR.WindowLine(via, "Guild", speaker, said), "guild")
    return true
  end

  --[[ Remembered so /wp can answer into that group. It is the window that
       forwarded the line, not the person who said it: they are in the group,
       we are talking to the window that can reach it. ]]
  WR.lastGroupFrom = via

  --[[ The speaker's name is clickable for the same reason a forwarded
       whisper's is: answering is the next thing you want to do, and they are
       not in a channel you can talk back to from here. ]]
  DEFAULT_CHAT_FRAME:AddMessage(
    (KIND_COLOUR[kind] or DIM) .. "[" .. tostring(via) .. " " ..
    (KIND_LABEL[kind] or "Group") .. "]|r " ..
    WR.NameLink(speaker) .. " " .. said)
  WR.ChatAdd(WR.WindowLine(via, KIND_LABEL[kind] or "Group", speaker, said),
    "group")
  return true
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
  local targets = WR.Targets()
  if table.getn(targets) == 0 then return end

  -- A line break would split this into two whispers, the second of which
  -- carries no marker and would be forwarded straight back.
  local body = string.gsub(tostring(text or ""), "%s+", " ")
  for i = 1, table.getn(targets) do
    WR.Queue(ALERT .. " " .. body, targets[i])
  end

  if WR.config.announce then
    DEFAULT_CHAT_FRAME:AddMessage(DIM .. "told " ..
      table.concat(targets, ", ") .. ": " .. text .. "|r")
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

function WR.OnAddonMessage(prefix, message, sender)
  if not WR.ready then return end
  if prefix == TW_WHISPER then
    WR.OnQuiet(message, sender)
    return
  end
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
  local text = WR.config.replyDefault and DEFAULT_REPLY
    or (WR.config.replyText or DEFAULT_REPLY)
  if text == "" then text = DEFAULT_REPLY end
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
  WR.ChatAdd(WR.WindowLine(arg2, "whisper", name, body), "whisper")
  WR.PopChat()
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

----------------------------------------------------------------------
-- answering as the character they actually wrote to
----------------------------------------------------------------------

--[[ Ask the window that received a whisper to answer it.

     The reply goes out from the character the person wrote to, so from their
     side it is simply a conversation. Clicking the name is still there and
     still answers as whoever you are sitting on -- the two are different
     things, and which you want depends on whether they know your alts. ]]
function WR.ReplyThrough(text)
  if not WR.ready then return end
  if not text or text == "" then
    Print("nothing to say. " .. DIM .. "/wr <message>|r")
    return
  end

  local last = WR.lastForward
  if not last then
    Print("no forwarded whisper to answer yet.")
    return
  end

  if last.via == WR.me then
    -- It arrived here in the first place; no need to go round the houses.
    SendChatMessage(text, "WHISPER", nil, last.from)
    return
  end

  WR.Queue(RELAY .. last.from .. "~" .. string.gsub(text, "%s+", " "), last.via)
  DEFAULT_CHAT_FRAME:AddMessage("|cffff80ff[" .. last.via .. "] to " ..
    last.from .. ":|r " .. text)
  -- Shown as the character that will actually say it, not as whoever typed it.
  -- Tagged with where it went, so your reply sits beside the whisper it
  -- answers rather than only on All.
  WR.ChatAdd(WR.WindowLine(last.via, "sent", last.from, text), "whisper")
end

--- One of our own windows: a character we forward to. The requests to speak
--- -- whisper, group, guild -- are honoured from these alone.
function WR.IsMine(name)
  local targets = WR.Targets()
  for i = 1, table.getn(targets) do
    if targets[i] == name then return true end
  end
  return false
end

--[[ Someone asked us to say something. Honoured only from our own windows.

     Without that check this is a remote mouth: anyone who worked out the
     marker could have you whisper anything to anyone, under your name, and
     the first you would know is the reply. ]]
function WR.OnRelayRequest(message, sender)
  local text = message or ""
  if string.sub(text, 1, string.len(RELAY)) ~= RELAY then return false end

  local body = string.sub(text, string.len(RELAY) + 1)
  local sep = string.find(body, "~", 1, true)
  if not sep then return true end
  local target = string.sub(body, 1, sep - 1)
  local said = string.sub(body, sep + 1)

  if not WR.IsMine(sender) then
    Print(WARN .. sender .. " asked this character to whisper somebody|r, and " ..
      "is not one of your windows. Ignored.")
    return true
  end

  if target == "" or said == "" then return true end
  SendChatMessage(said, "WHISPER", nil, target)
  if WR.config.announce then
    DEFAULT_CHAT_FRAME:AddMessage(DIM .. "said to " .. target ..
      " for " .. sender .. ": " .. said .. "|r")
  end
  return true
end

----------------------------------------------------------------------
-- a window to read it in, and answer from
----------------------------------------------------------------------

--[[ Everything relayed lands here as well as in the default chat, and the box
     at the bottom sends it back.

     The point is not decoration. Answering meant knowing which of two
     commands to reach for -- /wr goes back as the character they whispered,
     /wp talks to the group your other window is in -- and deciding that per
     message, mid-raid, is a worse question than it looks. Here the reply goes
     wherever the last thing came from, and the line above the box says where
     that is before you press Enter. ]]
local CHAT_W, CHAT_H = 420, 260
local CHAT_BUFFER = 60

WR.chatLog = {}

--[[ One shape for every line in the window, and the character it arrived on
     always first.

     In the normal chat frame a forward reads like a whisper with "(via
     Salahaja)" trailing off the end, which is fine when one thing arrives at
     a time and useless when four windows are talking: the one fact you need
     first is WHICH of your characters this reached, and it was last and dim.

     So: who it reached, then what kind of thing it was, then who said it. The
     character is in one colour and nothing else uses it. ]]
local WHO_COLOUR = "|cff8fd0ff"

function WR.WindowLine(onChar, kind, who, said)
  local head = WHO_COLOUR .. tostring(onChar) .. "|r "
  if kind == "whisper" then
    return head .. DIM .. "from|r " .. WR.NameLink(who) .. ": " .. said
  elseif kind == "sent" then
    return head .. DIM .. "to " .. tostring(who) .. ":|r " .. said
  elseif kind == "alert" then
    return head .. "|cffff8000! " .. said .. "|r"
  end
  -- Party, Raid, Raid Warning: the kind IS the label.
  return head .. DIM .. tostring(kind) .. "|r " ..
    WR.NameLink(who) .. ": " .. said
end

----------------------------------------------------------------------
-- the keyboard
----------------------------------------------------------------------

--[[ A box here has the keyboard only while you are typing in it. A click
     puts it there; sending, Escape, a click anywhere else -- in the world or
     on the window around the box -- or closing its window gives it back.
     Held any longer, the next keybind lands in the box as text.

     Whether a box has it is tracked from its own OnEditFocusGained and
     OnEditFocusLost, not asked with HasFocus, which not every 1.12 client
     has. A focus script the box already had still runs. ]]
WR.boxes = {}

function WR.TrackFocus(box)
  local gained = box:GetScript("OnEditFocusGained")
  local lost = box:GetScript("OnEditFocusLost")
  box:SetScript("OnEditFocusGained", function()
    box.typing = true
    if gained then gained() end
  end)
  box:SetScript("OnEditFocusLost", function()
    box.typing = false
    if lost then lost() end
  end)
  table.insert(WR.boxes, box)
end

--- Take the keyboard back from whichever of our boxes has it -- only ours.
function WR.ReleaseKeyboard()
  for i = 1, table.getn(WR.boxes) do
    local box = WR.boxes[i]
    if box.typing then box:ClearFocus() end
  end
end

--[[ A click in the world -- a mob, the ground, anything that is not a window
     -- arrives at WorldFrame's OnMouseDown, whichever button. Chained the way
     Dewdrop chains it: the script already there runs first, as before. ]]
function WR.HookWorldClicks()
  if WR.worldHooked or not WorldFrame then return end
  WR.worldHooked = true
  local previous = WorldFrame:GetScript("OnMouseDown")
  WorldFrame:SetScript("OnMouseDown", function()
    if previous then previous() end
    WR.ReleaseKeyboard()
  end)
end

--- Keep a little history, so opening the window is not opening an empty one.
--[[ Tabs by KIND rather than by conversation.

     Whispers scrolling party chat away is the actual complaint: they arrive
     at different rates about different things, and the one you are watching
     is rarely the one filling the window. Splitting them fixes that with
     fixed tabs. A tab per person would multiply without limit in a raid, and
     the thing being separated here is not who is talking. ]]
WR.TABS = {
  { key = "all",     label = "All" },
  { key = "whisper", label = "Whispers" },
  { key = "group",   label = "Party" },
  { key = "guild",   label = "Guild" },
}

--- Does this line belong on that tab? Alerts live on All alone.
local function onTab(entry, tab)
  if tab == "all" then return true end
  return entry.kind == tab
end

function WR.ChatAdd(text, kind)
  local entry = { text = text, kind = kind }
  table.insert(WR.chatLog, entry)
  --[[ The last CHAT_BUFFER lines of each kind, not of everything: a guild in
       full flow would otherwise push the whispers out of the window. ]]
  local count = 0
  for i = table.getn(WR.chatLog), 1, -1 do
    if WR.chatLog[i].kind == kind then
      count = count + 1
      if count > CHAT_BUFFER then table.remove(WR.chatLog, i) end
    end
  end

  --[[ Where a reply would go, remembered from whatever arrived last. This is
       what lets one input box work instead of asking every time. ]]
  if kind == "whisper" or kind == "group" then WR.chatContext = kind end

  local f = WR.chatFrame
  if f and f:IsShown() then
    if onTab(entry, WR.chatTab or "all") then
      f.log:AddMessage(text)
    elseif kind then
      -- Arrived somewhere you are not looking; the tab says so.
      WR.chatUnread = WR.chatUnread or {}
      WR.chatUnread[kind] = true
    end
    WR.RefreshChatTabs()
    WR.RefreshChatTarget()
  end
end

--[[ Where the next line typed goes.

     The tab decides when you are on one, which is the point of having them:
     on Whispers, Enter answers the whisper. On All it follows whatever
     arrived last, and switch overrides that. ]]
function WR.ChatDestination()
  local tab = WR.chatTab or "all"

  if tab == "whisper" then
    if WR.lastForward then
      return "whisper", WR.lastForward.from .. ", as " .. WR.lastForward.via
    end
    return nil, "no whisper has been forwarded here yet"
  end

  if tab == "group" then
    if WR.lastGroupFrom then
      return "group", "the group " .. WR.lastGroupFrom .. " is in"
    end
    return nil, "no group chat has been forwarded here yet"
  end

  if tab == "guild" then
    if WR.lastGuildFrom then
      return "guild", "the guild " .. WR.lastGuildFrom .. " is in"
    end
    return nil, "no guild chat has been forwarded here yet"
  end

  --[[ All never answers the guild, however recently it spoke: a guild talks
       all day, and a reply meant for a whisper must not land in front of
       everyone in it. The Guild tab is for that. ]]
  if WR.chatContext == "group" and WR.lastGroupFrom then
    return "group", "the group " .. WR.lastGroupFrom .. " is in"
  end
  if WR.lastForward then
    return "whisper", WR.lastForward.from .. ", as " .. WR.lastForward.via
  end
  if WR.lastGroupFrom then
    return "group", "the group " .. WR.lastGroupFrom .. " is in"
  end
  if WR.lastGuildFrom then
    return nil, "to talk to the guild, use the Guild tab"
  end
  return nil, "nothing has come through yet"
end

function WR.RefreshChatTarget()
  local f = WR.chatFrame
  if not f then return end
  local kind, description = WR.ChatDestination()
  if kind then
    f.target:SetTextColor(0.4, 0.85, 0.47)
    f.target:SetText("Replying to " .. description)
  else
    f.target:SetTextColor(0.62, 0.65, 0.72)
    f.target:SetText(description)
  end
  -- Switching by hand only means anything where the tab is not deciding.
  if f.swap then
    if (WR.chatTab or "all") == "all" then f.swap:Show() else f.swap:Hide() end
  end
end

function WR.ToggleChatDestination()
  if WR.chatContext == "group" then WR.chatContext = "whisper"
  else WR.chatContext = "group" end
  WR.RefreshChatTarget()
end

--- Repaint the log for whichever tab is showing.
function WR.ShowChatTab(key)
  WR.chatTab = key
  WR.chatUnread = WR.chatUnread or {}
  WR.chatUnread[key] = nil

  local f = WR.chatFrame
  if not f then return end
  f.log:Clear()
  for i = 1, table.getn(WR.chatLog) do
    local entry = WR.chatLog[i]
    if onTab(entry, key) then f.log:AddMessage(entry.text) end
  end
  WR.RefreshChatTabs()
  WR.RefreshChatTarget()
end

function WR.RefreshChatTabs()
  local f = WR.chatFrame
  if not f or not f.tabs then return end
  local active = WR.chatTab or "all"
  WR.chatUnread = WR.chatUnread or {}

  for i = 1, table.getn(f.tabs) do
    local t = f.tabs[i]
    if t.key == active then
      t.fill:SetVertexColor(0.16, 0.26, 0.34, 1)
      t.label:SetTextColor(0.56, 0.82, 1)
    elseif WR.chatUnread[t.key] then
      -- Something arrived on a tab you are not watching.
      t.fill:SetVertexColor(0.1, 0.1, 0.12, 1)
      t.label:SetTextColor(1, 0.75, 0.3)
    else
      t.fill:SetVertexColor(0.1, 0.1, 0.12, 1)
      t.label:SetTextColor(0.55, 0.55, 0.58)
    end
  end
end

function WR.SendFromChat(text)
  if not text or text == "" then return end
  local kind, description = WR.ChatDestination()
  if kind == "group" then
    WR.SayInGroup(text)
  elseif kind == "guild" then
    WR.SayInGuild(text)
  elseif kind == "whisper" then
    WR.ReplyThrough(text)
  else
    -- Refused, with the reason the line above the box already gives.
    Print("not sent: " .. description .. ".")
  end
end

--[[ Remembered across sessions, because a window you have to drag and resize
     every login is one you stop opening. ]]
function WR.SaveChatGeometry()
  local f = WR.chatFrame
  if not f then return end
  WR.config.chatW = f:GetWidth()
  WR.config.chatH = f:GetHeight()
end

function WR.BuildChat()
  if WR.chatFrame then return WR.chatFrame end

  local f = CreateFrame("Frame", "WhisperRelayChat", UIParent)
  f:SetWidth(WR.config.chatW or CHAT_W)
  f:SetHeight(WR.config.chatH or CHAT_H)
  f:SetPoint("CENTER", UIParent, "CENTER", 0, -80)
  f:SetFrameStrata("MEDIUM")
  f:EnableMouse(true)
  f:SetMovable(true)
  f:SetResizable(true)
  -- Below this the tab strip and the input box stop fitting.
  f:SetMinResize(280, 160)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", function() f:StartMoving() end)
  f:SetScript("OnDragStop", function() f:StopMovingOrSizing() end)
  f:Hide()

  local bg = f:CreateTexture(nil, "BACKGROUND")
  bg:SetTexture("Interface\\Buttons\\WHITE8X8")
  bg:SetVertexColor(0.03, 0.03, 0.04, 0.88)
  bg:SetAllPoints(f)

  local edges = {}
  for i = 1, 4 do
    local t = f:CreateTexture(nil, "BORDER")
    t:SetTexture("Interface\\Buttons\\WHITE8X8")
    t:SetVertexColor(0.56, 0.82, 1, 0.7)
    edges[i] = t
  end
  edges[1]:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
  edges[1]:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, 0)
  edges[1]:SetHeight(1)
  edges[2]:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 0, 0)
  edges[2]:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0)
  edges[2]:SetHeight(1)
  edges[3]:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
  edges[3]:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 0, 0)
  edges[3]:SetWidth(1)
  edges[4]:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, 0)
  edges[4]:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0)
  edges[4]:SetWidth(1)

  local close = CreateFrame("Button", nil, f)
  close:SetWidth(18)
  close:SetHeight(18)
  close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -4)
  close:EnableMouse(true)
  local x = close:CreateFontString(nil, "OVERLAY")
  x:SetFont("Fonts\\FRIZQT__.TTF", 12)
  x:SetTextColor(0.7, 0.7, 0.7)
  x:SetPoint("CENTER", close, "CENTER", 0, 0)
  x:SetText("x")
  close:SetScript("OnClick", function() f:Hide() end)

  ------------------------------------------------------------------
  -- tabs
  ------------------------------------------------------------------
  f.tabs = {}
  local tabX = 6
  for i = 1, table.getn(WR.TABS) do
    local def = WR.TABS[i]
    local width = 4 + string.len(def.label) * 7

    local t = CreateFrame("Button", nil, f)
    t:SetWidth(width)
    t:SetHeight(18)
    t:SetPoint("TOPLEFT", f, "TOPLEFT", tabX, -5)
    t:EnableMouse(true)

    t.fill = t:CreateTexture(nil, "ARTWORK")
    t.fill:SetTexture("Interface\\Buttons\\WHITE8X8")
    t.fill:SetAllPoints(t)

    t.label = t:CreateFontString(nil, "OVERLAY")
    t.label:SetFont("Fonts\\FRIZQT__.TTF", 10)
    t.label:SetPoint("CENTER", t, "CENTER", 0, 0)
    t.label:SetText(def.label)

    t.key = def.key
    --[[ The key is read off the button rather than captured from the loop:
         in 5.0 the loop variable is one slot for the whole loop and holds nil
         once it ends, so a closure over `def` would break on the first
         click. ]]
    t:SetScript("OnClick", function()
      local btn = this or t
      WR.ShowChatTab(btn.key)
    end)

    f.tabs[i] = t
    tabX = tabX + width + 3
  end

  local log = CreateFrame("ScrollingMessageFrame", nil, f)
  log:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -28)
  log:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -10, 52)
  log:SetFont("Fonts\\FRIZQT__.TTF", 11)
  log:SetJustifyH("LEFT")
  log:SetFading(false)
  log:SetMaxLines(CHAT_BUFFER)
  f.log = log

  f:EnableMouseWheel(true)
  f:SetScript("OnMouseWheel", function()
    if arg1 > 0 then log:ScrollUp() else log:ScrollDown() end
  end)

  f.target = f:CreateFontString(nil, "OVERLAY")
  f.target:SetFont("Fonts\\FRIZQT__.TTF", 10)
  f.target:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 10, 34)
  f.target:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -60, 34)
  f.target:SetJustifyH("LEFT")

  local swap = CreateFrame("Button", nil, f)
  swap:SetWidth(50)
  swap:SetHeight(14)
  swap:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -10, 32)
  swap:EnableMouse(true)
  local swapFill = swap:CreateTexture(nil, "ARTWORK")
  swapFill:SetTexture("Interface\\Buttons\\WHITE8X8")
  swapFill:SetVertexColor(0.16, 0.16, 0.18, 1)
  swapFill:SetAllPoints(swap)
  local swapText = swap:CreateFontString(nil, "OVERLAY")
  swapText:SetFont("Fonts\\FRIZQT__.TTF", 10)
  swapText:SetTextColor(0.8, 0.8, 0.8)
  swapText:SetPoint("CENTER", swap, "CENTER", 0, 0)
  swapText:SetText("switch")
  swap:SetScript("OnClick", function() WR.ToggleChatDestination() end)
  f.swap = swap

  local boxFrame = CreateFrame("Frame", nil, f)
  boxFrame:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 10, 8)
  boxFrame:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -22, 8)
  boxFrame:SetHeight(22)
  local boxBg = boxFrame:CreateTexture(nil, "BACKGROUND")
  boxBg:SetTexture("Interface\\Buttons\\WHITE8X8")
  boxBg:SetVertexColor(0.12, 0.12, 0.14, 1)
  boxBg:SetAllPoints(boxFrame)

  local edit = CreateFrame("EditBox", "WhisperRelayChatBox", boxFrame)
  edit:SetPoint("TOPLEFT", boxFrame, "TOPLEFT", 5, -2)
  edit:SetPoint("BOTTOMRIGHT", boxFrame, "BOTTOMRIGHT", -5, 2)
  edit:SetFont("Fonts\\FRIZQT__.TTF", 11)
  edit:SetTextColor(1, 1, 1)
  edit:SetAutoFocus(false)
  edit:SetMaxLetters(240)
  edit:SetScript("OnEnterPressed", function()
    local said = edit:GetText() or ""
    edit:SetText("")
    -- Sent: the keyboard goes back to the game. Another line is a click away.
    edit:ClearFocus()
    WR.SendFromChat(said)
  end)
  edit:SetScript("OnEscapePressed", function()
    edit:SetText("")
    edit:ClearFocus()
  end)
  WR.TrackFocus(edit)
  f.edit = edit

  -- A click on the window around the box, or closing it, hands it back too.
  f:SetScript("OnMouseDown", function() WR.ReleaseKeyboard() end)
  f:SetScript("OnHide", function() WR.ReleaseKeyboard() end)

  --[[ The grip. Everything inside is anchored to the frame's edges rather
       than sized in pixels, so dragging this reflows the lot without a
       single layout calculation of our own. ]]
  local grip = CreateFrame("Button", nil, f)
  grip:SetWidth(14)
  grip:SetHeight(14)
  grip:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -2, 2)
  grip:EnableMouse(true)
  local gripArt = grip:CreateFontString(nil, "OVERLAY")
  gripArt:SetFont("Fonts\\FRIZQT__.TTF", 12)
  gripArt:SetTextColor(0.5, 0.5, 0.55)
  gripArt:SetPoint("CENTER", grip, "CENTER", 0, 0)
  gripArt:SetText("//")
  grip:RegisterForDrag("LeftButton")
  grip:SetScript("OnDragStart", function() f:StartSizing("BOTTOMRIGHT") end)
  grip:SetScript("OnDragStop", function()
    f:StopMovingOrSizing()
    WR.SaveChatGeometry()
  end)
  f.grip = grip

  WR.chatFrame = f
  return f
end

function WR.ToggleChat()
  local f = WR.BuildChat()
  if f:IsShown() then
    f:Hide()
    return
  end

  f:Show()
  -- Opening it shows what has already been said, not an empty box.
  WR.ShowChatTab(WR.chatTab or "all")
end

--[[ A forwarded whisper has just landed here, on the window you are looking
     at: open the relay window, where it can be answered. Left on the Party
     tab, Enter would talk to the group instead, so that gives way to All --
     which follows whatever arrived last, this whisper. It never takes the
     keyboard: this can land mid-fight, and a box that grabbed focus would
     swallow every key pressed after it. ]]
function WR.PopChat()
  if not WR.config.openChat then return end
  local f = WR.BuildChat()
  if f:IsShown() then return end
  f:Show()
  local tab = WR.chatTab or "all"
  if tab == "group" then tab = "all" end
  WR.ShowChatTab(tab)
end

--- Say something in the group, through the window that is in it.
function WR.SayInGroup(text)
  if not WR.ready then return end
  if not text or text == "" then
    Print("nothing to say. " .. DIM .. "/wp <message>|r")
    return
  end

  local via = WR.lastGroupFrom
  if not via then
    Print("no group chat has been forwarded here yet, so there is no group " ..
      "to answer.")
    return
  end

  if via == WR.me then
    -- We are in it ourselves; no round trip needed.
    local raid = (GetNumRaidMembers and GetNumRaidMembers()) or 0
    SendChatMessage(text, raid > 0 and "RAID" or "PARTY")
    return
  end

  WR.Queue(SAY .. string.gsub(text, "%s+", " "), via)
  DEFAULT_CHAT_FRAME:AddMessage("|cffaaaaff[" .. via .. " Group] " ..
    tostring(WR.me) .. ":|r " .. text)
  WR.ChatAdd(WR.WindowLine(via, "sent", "the group", text), "group")
end

--[[ Someone asked us to say something to the group we are in.

     The channel is decided HERE rather than carried, because this window is
     the one that knows whether it is in a raid or a party -- and it can have
     changed between the line being read and the answer being written. ]]
function WR.OnSayRequest(message, sender)
  local text = message or ""
  if string.sub(text, 1, string.len(SAY)) ~= SAY then return false end

  local said = string.sub(text, string.len(SAY) + 1)
  if said == "" then return true end

  if not WR.IsMine(sender) then
    Print(WARN .. sender .. " asked this character to speak to its group|r, " ..
      "and is not one of your windows. Ignored.")
    return true
  end

  local raid = (GetNumRaidMembers and GetNumRaidMembers()) or 0
  local party = (GetNumPartyMembers and GetNumPartyMembers()) or 0
  if raid == 0 and party == 0 then
    Print(DIM .. sender .. " asked this character to say something to its " ..
      "group, but it is not in one any more.|r")
    return true
  end

  SendChatMessage(said, raid > 0 and "RAID" or "PARTY")
  if WR.config.announce then
    DEFAULT_CHAT_FRAME:AddMessage(DIM .. "said to the group for " .. sender ..
      ": " .. said .. "|r")
  end
  return true
end

--- Say something in guild chat, through the window that is in the guild.
function WR.SayInGuild(text)
  if not WR.ready then return end
  if not text or text == "" then
    Print("nothing to say. " .. DIM .. "/wg <message>|r")
    return
  end

  local via = WR.lastGuildFrom
  if not via then
    Print("no guild chat has been forwarded here yet, so there is no guild " ..
      "to answer.")
    return
  end

  if via == WR.me then
    SendChatMessage(text, "GUILD")
    return
  end

  WR.Queue(GUILD_SAY .. string.gsub(text, "%s+", " "), via)
  WR.ChatAdd(WR.WindowLine(via, "sent", "the guild", text), "guild")
  -- Shown where you are looking: the relay window, or chat when it is shut.
  if not (WR.chatFrame and WR.chatFrame:IsShown()) then
    DEFAULT_CHAT_FRAME:AddMessage("|cff40ff40[" .. via .. " Guild] " ..
      tostring(WR.me) .. ":|r " .. text)
  end
end

--[[ Someone asked us to say something in our guild. Whether we are still in
     one is decided here, where it is known, as with the group. ]]
function WR.OnGuildSayRequest(message, sender)
  local text = message or ""
  if string.sub(text, 1, string.len(GUILD_SAY)) ~= GUILD_SAY then return false end

  local said = string.sub(text, string.len(GUILD_SAY) + 1)
  if said == "" then return true end

  if not WR.IsMine(sender) then
    Print(WARN .. sender .. " asked this character to speak in its guild|r, " ..
      "and is not one of your windows. Ignored.")
    return true
  end

  if not (IsInGuild and IsInGuild()) then
    Print(DIM .. sender .. " asked this character to say something in guild " ..
      "chat, but it is not in a guild any more.|r")
    return true
  end

  SendChatMessage(said, "GUILD")
  if WR.config.announce then
    DEFAULT_CHAT_FRAME:AddMessage(DIM .. "said to the guild for " .. sender ..
      ": " .. said .. "|r")
  end
  return true
end

--- The fallback: a short clickable line under a forward we could not rewrite.
function WR.ShowHandle(name, sender)
  if not WR.config.replyLink then return end

  -- A split forward is one conversation, so it gets one handle.
  if WR.handleFor == name and WR.handleAt and (time() - WR.handleAt) < 15 then
    return
  end
  WR.handleFor, WR.handleAt = name, time()

  DEFAULT_CHAT_FRAME:AddMessage(DIM .. "    reply to |r" .. WR.NameLink(name) ..
    DIM .. "  (forwarded by " .. tostring(sender) .. ")|r")
  -- The window shows the whole line; the fallback in chat is only a handle.
  WR.ChatAdd(WR.WindowLine(sender, "whisper", name, ""), "whisper")
  WR.PopChat()
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

----------------------------------------------------------------------
-- the settings window
----------------------------------------------------------------------

--[[ Every switch in one place, because there are now eight of them and
     remembering eight slash commands to find out what a thing is currently
     set to is not a settings system.

     The commands all still work -- they are what a macro can use, and what
     this window is written in terms of -- but the window is how you see the
     whole state at once, including the one thing no command can show you as
     clearly: which windows it is actually forwarding to right now. ]]
local PANEL_W = 300
local ROW_H = 22

--[[ Field, label, and what it means. Order is the order they appear. The
     `note` is the reason, not a restatement of the label: a switch you can
     see but not understand is a switch you leave alone. ]]
local SWITCHES = {
  { key = "enabled",   label = "Forward whispers",
    note = "the whole thing, on or off" },
  { key = "quiet",     label = "Quiet: no whispers between my windows",
    note = "they send addon messages, which chat never shows" },
  { key = "openChat",  label = "Open the relay window for a whisper",
    note = "on the window it is forwarded to, without taking the keyboard" },
  { key = "alerts",    label = "Pass on queue pops",
    note = "battleground and dungeon invites expire on a timer" },
  { key = "popup",     label = "Popup for a pop",
    note = "a box on screen, not only a line in chat" },
  { key = "inline",    label = "Clickable name in the message",
    note = "off puts it on a line underneath instead" },
  { key = "replyLink", label = "  ...or a reply line if that fails",
    note = "a chat addon can take the rewrite away" },
  { key = "autoReply", label = "Answer whoever whispered me",
    note = "a bot reply in their window; off by default" },
  { key = "groupChat", label = "Forward party and raid chat",
    note = "only to windows that are not in that group" },
  { key = "guildChat", label = "Forward guild chat",
    note = "to the relay window of those not in that guild" },
  { key = "announce",  label = "Note each forward here",
    note = "so you can see it happening" },
}

--[[ Flip one switch, and whatever else that takes. The settings window and
     the minimap menu both come through here, so neither can forget a part. ]]
function WR.Toggle(key)
  WR.config[key] = not WR.config[key]
  -- Turning the popup off should take down one already on screen.
  if key == "popup" and not WR.config.popup then WR.HidePopup() end
  if key == "quiet" then WR.QuietChanged() end
  --[[ Back on means "try them again", as /wf on does. The refusal that
       switched it off would otherwise leave a named target unreachable, and
       forwarding "on" that forwards nowhere. ]]
  if key == "enabled" and WR.config.enabled then
    WR.offline = {}
    WR.others, WR.othersAt = nil, nil
  end
  -- Who is in the guild decides where guild chat goes; ask now, not later.
  if key == "guildChat" then WR.AskRoster() end
  WR.RefreshPanel()
end

local function checkbox(parent, index, switch)
  local b = CreateFrame("Button", nil, parent)
  b:SetWidth(PANEL_W - 24)
  b:SetHeight(ROW_H)
  b:SetPoint("TOPLEFT", parent, "TOPLEFT", 12, -(40 + (index - 1) * ROW_H))
  b:EnableMouse(true)

  local box = b:CreateTexture(nil, "ARTWORK")
  box:SetTexture("Interface\\Buttons\\WHITE8X8")
  box:SetVertexColor(0.35, 0.35, 0.38, 1)
  box:SetWidth(12)
  box:SetHeight(12)
  box:SetPoint("LEFT", b, "LEFT", 0, 0)

  local tick = b:CreateTexture(nil, "OVERLAY")
  tick:SetTexture("Interface\\Buttons\\WHITE8X8")
  tick:SetVertexColor(0.4, 0.85, 0.47, 1)
  tick:SetWidth(6)
  tick:SetHeight(6)
  tick:SetPoint("LEFT", b, "LEFT", 3, 0)

  local text = b:CreateFontString(nil, "OVERLAY")
  text:SetFont("Fonts\\FRIZQT__.TTF", 11)
  text:SetTextColor(0.9, 0.9, 0.9)
  text:SetPoint("LEFT", b, "LEFT", 20, 0)
  text:SetText(switch.label)

  b.tick, b.key, b.note = tick, switch.key, switch.note
  b:SetScript("OnClick", function() WR.Toggle(switch.key) end)
  return b
end

function WR.BuildPanel()
  if WR.panel then return WR.panel end

  local f = CreateFrame("Button", "WhisperRelaySettings", UIParent)
  f:SetWidth(PANEL_W)
  -- Switches, then the reply section (label, two buttons, box, preview),
  -- then the state line and the hint at the bottom.
  f:SetHeight(50 + table.getn(SWITCHES) * ROW_H + 96 + 52)
  f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
  f:SetFrameStrata("DIALOG")
  f:EnableMouse(true)
  f:Hide()

  local bg = f:CreateTexture(nil, "BACKGROUND")
  bg:SetTexture("Interface\\Buttons\\WHITE8X8")
  bg:SetVertexColor(0.04, 0.04, 0.05, 0.94)
  bg:SetAllPoints(f)

  local edges = {}
  for i = 1, 4 do
    local t = f:CreateTexture(nil, "BORDER")
    t:SetTexture("Interface\\Buttons\\WHITE8X8")
    t:SetVertexColor(0.56, 0.82, 1, 0.8)
    edges[i] = t
  end
  edges[1]:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
  edges[1]:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, 0)
  edges[1]:SetHeight(1)
  edges[2]:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 0, 0)
  edges[2]:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0)
  edges[2]:SetHeight(1)
  edges[3]:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
  edges[3]:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 0, 0)
  edges[3]:SetWidth(1)
  edges[4]:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, 0)
  edges[4]:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0)
  edges[4]:SetWidth(1)

  f.title = f:CreateFontString(nil, "OVERLAY")
  f.title:SetFont("Fonts\\FRIZQT__.TTF", 13)
  f.title:SetTextColor(0.56, 0.82, 1)
  f.title:SetPoint("TOP", f, "TOP", 0, -12)
  f.title:SetText("Whisper Relay")

  f.boxes = {}
  for i = 1, table.getn(SWITCHES) do
    f.boxes[i] = checkbox(f, i, SWITCHES[i])
  end

  ------------------------------------------------------------------
  -- what to say back
  ------------------------------------------------------------------

  local top = -(40 + table.getn(SWITCHES) * ROW_H + 10)

  f.replyLabel = f:CreateFontString(nil, "OVERLAY")
  f.replyLabel:SetFont("Fonts\\FRIZQT__.TTF", 11)
  f.replyLabel:SetTextColor(0.9, 0.9, 0.9)
  f.replyLabel:SetPoint("TOPLEFT", f, "TOPLEFT", 12, top)
  f.replyLabel:SetText("What to tell them:")

  --[[ Default and Custom are a pair of buttons rather than a single toggle,
       because "which of these am I using" has to be answerable at a glance --
       a toggle only tells you that once you have worked out which way round
       it is. ]]
  local function modeButton(label, wantDefault, x)
    local b = CreateFrame("Button", nil, f)
    b:SetWidth(70)
    b:SetHeight(18)
    b:SetPoint("TOPLEFT", f, "TOPLEFT", x, top - 18)
    b:EnableMouse(true)

    local fill = b:CreateTexture(nil, "ARTWORK")
    fill:SetTexture("Interface\\Buttons\\WHITE8X8")
    fill:SetAllPoints(b)

    local text = b:CreateFontString(nil, "OVERLAY")
    text:SetFont("Fonts\\FRIZQT__.TTF", 11)
    text:SetPoint("CENTER", b, "CENTER", 0, 0)
    text:SetText(label)

    b.fill, b.label, b.wantDefault = fill, text, wantDefault
    b:SetScript("OnClick", function()
      WR.config.replyDefault = wantDefault
      if not wantDefault and (WR.config.replyText or "") == "" then
        -- Somewhere to start from, rather than an empty box.
        WR.config.replyText = DEFAULT_REPLY
      end
      WR.RefreshPanel()
    end)
    return b
  end

  f.useDefault = modeButton("Default", true, 12)
  f.useCustom = modeButton("Custom", false, 88)

  --[[ An EditBox needs its font set or it draws nothing at all, and needs
       autofocus off or opening this window swallows your keyboard. ]]
  local boxFrame = CreateFrame("Frame", nil, f)
  boxFrame:SetWidth(PANEL_W - 24)
  boxFrame:SetHeight(24)
  boxFrame:SetPoint("TOPLEFT", f, "TOPLEFT", 12, top - 40)

  local boxBg = boxFrame:CreateTexture(nil, "BACKGROUND")
  boxBg:SetTexture("Interface\\Buttons\\WHITE8X8")
  boxBg:SetVertexColor(0.12, 0.12, 0.14, 1)
  boxBg:SetAllPoints(boxFrame)

  local edit = CreateFrame("EditBox", "WhisperRelayReplyBox", boxFrame)
  edit:SetPoint("TOPLEFT", boxFrame, "TOPLEFT", 5, -3)
  edit:SetPoint("BOTTOMRIGHT", boxFrame, "BOTTOMRIGHT", -5, 3)
  edit:SetFont("Fonts\\FRIZQT__.TTF", 11)
  edit:SetTextColor(1, 1, 1)
  edit:SetAutoFocus(false)
  -- A whisper is 255; leave room for a long character name in {char}.
  edit:SetMaxLetters(180)

  local function commit()
    local typed = edit:GetText() or ""
    WR.config.replyText = typed
    -- Typing IS choosing custom. Making you click Custom first, then type,
    -- then wonder why nothing changed, is not a setting.
    if typed ~= "" then WR.config.replyDefault = false end
    WR.RefreshPanel()
  end

  edit:SetScript("OnEnterPressed", function()
    commit()
    edit:ClearFocus()
  end)
  edit:SetScript("OnEditFocusLost", function() commit() end)
  edit:SetScript("OnEscapePressed", function()
    -- Abandon the edit: put back whatever is actually saved.
    edit:SetText(WR.config.replyText or DEFAULT_REPLY)
    edit:ClearFocus()
  end)

  f.edit, f.editFrame = edit, boxFrame
  WR.TrackFocus(edit)
  -- A click on the window around the box closes it, and closing hands it back.
  f:SetScript("OnHide", function() WR.ReleaseKeyboard() end)

  --[[ What the other person actually receives, {char} filled in. The token is
       the one part of this nobody can be expected to picture. ]]
  f.preview = f:CreateFontString(nil, "OVERLAY")
  f.preview:SetFont("Fonts\\FRIZQT__.TTF", 10)
  f.preview:SetWidth(PANEL_W - 24)
  f.preview:SetPoint("TOPLEFT", f, "TOPLEFT", 12, top - 68)

  --[[ The one thing no slash command shows as plainly: where forwards are
       going at this moment, and therefore whether it is doing anything. ]]
  f.state = f:CreateFontString(nil, "OVERLAY")
  f.state:SetFont("Fonts\\FRIZQT__.TTF", 11)
  f.state:SetWidth(PANEL_W - 24)
  f.state:SetPoint("BOTTOM", f, "BOTTOM", 0, 26)

  f.hint = f:CreateFontString(nil, "OVERLAY")
  f.hint:SetFont("Fonts\\FRIZQT__.TTF", 10)
  f.hint:SetTextColor(0.6, 0.6, 0.6)
  f.hint:SetPoint("BOTTOM", f, "BOTTOM", 0, 10)
  f.hint:SetText("click outside the switches to close")

  f:SetScript("OnClick", function() WR.HidePanel() end)

  WR.panel = f
  return f
end

function WR.RefreshPanel()
  local f = WR.panel
  if not f then return end

  for i = 1, table.getn(f.boxes) do
    local b = f.boxes[i]
    if WR.config[b.key] then b.tick:Show() else b.tick:Hide() end
  end

  -- Which of the two is in use, lit rather than merely labelled.
  local usingDefault = WR.config.replyDefault and true or false
  for _, b in ipairs({ f.useDefault, f.useCustom }) do
    local on = (b.wantDefault == usingDefault)
    if on then
      b.fill:SetVertexColor(0.22, 0.42, 0.24, 1)
      b.label:SetTextColor(1, 1, 1)
    else
      b.fill:SetVertexColor(0.16, 0.16, 0.18, 1)
      b.label:SetTextColor(0.6, 0.6, 0.6)
    end
  end

  --[[ Never overwrite what is being typed. Refresh runs on every click in
       this window, and replacing the text under the cursor mid-sentence is
       the kind of thing that makes a settings window feel broken. ]]
  if not f.edit.typing then
    f.edit:SetText(usingDefault and DEFAULT_REPLY or (WR.config.replyText or ""))
  end
  if usingDefault then
    f.edit:SetTextColor(0.6, 0.6, 0.6)
  else
    f.edit:SetTextColor(1, 1, 1)
  end

  local sample = WR.Target() or "your other character"
  f.preview:SetTextColor(0.62, 0.65, 0.72)
  f.preview:SetText("They receive: \"" ..
    (string.gsub(usingDefault and DEFAULT_REPLY or (WR.config.replyText or ""),
                 "{char}", sample)) .. "\"")

  local targets = WR.Targets()
  local n = table.getn(targets)
  if not WR.config.enabled then
    f.state:SetTextColor(0.83, 0.31, 0.33)
    f.state:SetText("Forwarding is off.")
  elseif n > 0 then
    f.state:SetTextColor(0.4, 0.85, 0.47)
    f.state:SetText("Forwarding to " .. table.concat(targets, ", "))
  elseif WR.config.auto then
    --[[ Not a fault, and worded so it does not read as one: with nothing
         else logged in there is nowhere to forward to, and it starts again
         by itself the moment another window appears. ]]
    f.state:SetTextColor(0.62, 0.65, 0.72)
    f.state:SetText("No other character logged in, so nothing is being " ..
      "forwarded. It starts again on its own.")
  else
    f.state:SetTextColor(0.83, 0.31, 0.33)
    f.state:SetText("No target. /wf to <character>, or /wf auto")
  end
end

function WR.HidePanel()
  if WR.panel then WR.panel:Hide() end
end

function WR.TogglePanel()
  local f = WR.BuildPanel()
  if f:IsShown() then
    f:Hide()
  else
    WR.RefreshPanel()
    f:Show()
  end
end

--- Open, never close: for a menu line that says "open".
function WR.OpenPanel()
  if not WR.BuildPanel():IsShown() then WR.TogglePanel() end
end

function WR.OpenChat()
  if not WR.BuildChat():IsShown() then WR.ToggleChat() end
end

----------------------------------------------------------------------
-- the minimap button
----------------------------------------------------------------------

--[[ Left-click for the settings window, right-click for a menu of the
     switches you reach for mid-game, drag to move it round the edge.

     The menu is the client's own dropdown, like every right-click menu in
     the game. Each line carries its setting as data, not in a function made
     for it: on this client a function made inside a loop does not keep the
     loop's values. ]]
local MINIMAP_RADIUS = 80
local MENU_SWITCHES = { "enabled", "quiet", "openChat", "groupChat", "guildChat",
                        "alerts", "popup" }

--- A switch's words, the same as the settings window's.
function WR.SwitchLabel(key)
  for i = 1, table.getn(SWITCHES) do
    if SWITCHES[i].key == key then return SWITCHES[i].label end
  end
  return key
end

--- Round the rim at the saved angle: 0 is east, 90 north.
function WR.PlaceMinimapButton()
  local b = WR.minimapButton
  if not b then return end
  local a = math.rad(WR.config.minimapAngle or 225)
  b:ClearAllPoints()
  b:SetPoint("CENTER", Minimap, "CENTER",
    MINIMAP_RADIUS * math.cos(a), MINIMAP_RADIUS * math.sin(a))
end

--- Following the cursor round the rim, every frame of a drag.
function WR.DragMinimapButton()
  local mx, my = Minimap:GetCenter()
  local px, py = GetCursorPosition()
  local scale = Minimap:GetEffectiveScale()
  WR.config.minimapAngle = math.deg(math.atan2(py / scale - my, px / scale - mx))
  WR.PlaceMinimapButton()
end

--- Built the way the client builds its own tracking button beside the map.
function WR.BuildMinimapButton()
  if WR.minimapButton then return WR.minimapButton end
  if not Minimap then return nil end

  local b = CreateFrame("Button", "WhisperRelayMinimapButton", Minimap)
  b:SetWidth(32)
  b:SetHeight(32)
  b:SetFrameStrata("MEDIUM")
  b:SetFrameLevel(8)
  b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

  local icon = b:CreateTexture(nil, "BACKGROUND")
  icon:SetTexture("Interface\\Icons\\INV_Letter_15")
  icon:SetWidth(20)
  icon:SetHeight(20)
  icon:SetPoint("TOPLEFT", b, "TOPLEFT", 6, -6)

  local border = b:CreateTexture(nil, "OVERLAY")
  border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
  border:SetWidth(52)
  border:SetHeight(52)
  border:SetPoint("TOPLEFT", b, "TOPLEFT", 0, 0)

  b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  b:RegisterForDrag("LeftButton")
  b:SetScript("OnClick", function() WR.MinimapClick(arg1) end)
  b:SetScript("OnDragStart", function()
    this:SetScript("OnUpdate", WR.DragMinimapButton)
  end)
  b:SetScript("OnDragStop", function()
    this:SetScript("OnUpdate", nil)
  end)
  b:SetScript("OnEnter", function() WR.MinimapTooltip(this) end)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)

  WR.minimapButton = b
  WR.PlaceMinimapButton()
  return b
end

--- Shown or not, as the setting says; built the first time it is wanted.
function WR.ShowMinimapButton()
  if WR.config.minimap then
    local b = WR.BuildMinimapButton()
    if b then b:Show() end
  elseif WR.minimapButton then
    WR.minimapButton:Hide()
  end
end

function WR.HideMinimapButton()
  WR.config.minimap = false
  WR.ShowMinimapButton()
  Print("minimap button hidden. |cffe0a22c/wf minimap|r brings it back.")
end

function WR.MinimapClick(button)
  if button == "RightButton" then
    WR.ShowMinimapMenu()
  else
    CloseDropDownMenus()
    WR.TogglePanel()
  end
end

function WR.MinimapTooltip(owner)
  GameTooltip:SetOwner(owner, "ANCHOR_LEFT")
  GameTooltip:SetText("Whisper Relay")
  local targets = WR.Targets()
  local state
  if not WR.config.enabled then
    state = "Forwarding is off"
  elseif table.getn(targets) > 0 then
    state = "Forwarding to " .. table.concat(targets, ", ")
  else
    state = "Nobody to forward to yet"
  end
  GameTooltip:AddLine(state, 1, 1, 1)
  GameTooltip:AddLine("Left-click: settings", 0.7, 0.7, 0.7)
  GameTooltip:AddLine("Right-click: quick switches", 0.7, 0.7, 0.7)
  GameTooltip:AddLine("Drag: move it round the minimap", 0.7, 0.7, 0.7)
  GameTooltip:Show()
end

--[[ A switch picked in the menu. The client hands over the line's arg1; an
     older one only the line itself, as `this`, with the setting as its
     value. ]]
function WR.MenuPick(key)
  if type(key) ~= "string" then key = this and this.value end
  if type(key) == "string" then WR.Toggle(key) end
end

function WR.MinimapMenuInit()
  UIDropDownMenu_AddButton({ text = "Whisper Relay", isTitle = 1, notCheckable = 1 })
  for i = 1, table.getn(MENU_SWITCHES) do
    local key = MENU_SWITCHES[i]
    UIDropDownMenu_AddButton({
      text = WR.SwitchLabel(key),
      value = key,
      arg1 = key,
      checked = WR.config[key] and 1 or nil,
      keepShownOnClick = 1,
      func = WR.MenuPick,
    })
  end
  UIDropDownMenu_AddButton({ text = "Open the relay window", notCheckable = 1,
    func = WR.OpenChat })
  UIDropDownMenu_AddButton({ text = "All settings...", notCheckable = 1,
    func = WR.OpenPanel })
  UIDropDownMenu_AddButton({ text = "Hide this button", notCheckable = 1,
    func = WR.HideMinimapButton })
end

--- Opened at the cursor; a second right-click closes it again.
function WR.ShowMinimapMenu()
  local menu = WR.minimapMenu
  if not menu then
    menu = CreateFrame("Frame", "WhisperRelayMinimapMenu", UIParent,
      "UIDropDownMenuTemplate")
    UIDropDownMenu_Initialize(menu, WR.MinimapMenuInit, "MENU")
    WR.minimapMenu = menu
  end
  ToggleDropDownMenu(1, nil, menu, "cursor")
end

--- An alert arriving from the other client. Loud, and nobody to reply to.
function WR.ShowAlert(message, sender)
  local text = message or ""
  if string.sub(text, 1, string.len(ALERT)) ~= ALERT then return false end
  local body = string.gsub(string.sub(text, string.len(ALERT) + 1), "^%s+", "")

  DEFAULT_CHAT_FRAME:AddMessage("|cffff8000[" .. tostring(sender) .. "]  " ..
    body .. "|r")
  WR.ChatAdd(WR.WindowLine(sender, "alert", nil, body))
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
  if WR.ShowGroupChat(message, sender) then return end
  if WR.OnRelayRequest(message, sender) then return end
  if WR.OnSayRequest(message, sender) then return end
  if WR.OnGuildSayRequest(message, sender) then return end

  --[[ Before anything else, and before the target check: the character you
       are PLAYING is usually the one with no target of its own, and it is the
       one that needs the clickable name. ]]
  local fwd = WR.ParseForward(message)
  if fwd then
    --[[ Remembered so /wr can answer through the window it arrived on,
         rather than from whichever character happens to be in front of you. ]]
    WR.lastForward = { from = fwd, via = sender }
    WR.pending = { name = fwd, sender = sender, message = message }
    return
  end

  if not WR.config.enabled then return end

  --[[ Resolved once per whisper. Empty whenever no other client is running,
       and that is the right answer: with nobody at the other end there is
       nothing to forward to, and telling the sender to go whisper a
       character who is offline would be worse than saying nothing. ]]
  local targets = WR.Targets()
  local count = table.getn(targets)
  if count == 0 then return end
  if WR.IsLoop(sender, message, targets) then return end

  local parts = WR.Parts(sender, message or "")
  for t = 1, count do
    for p = 1, table.getn(parts) do
      WR.Queue(parts[p], targets[t])
    end
  end

  if WR.config.announce then
    DEFAULT_CHAT_FRAME:AddMessage(DIM .. "forwarded " .. sender .. " to " ..
      table.concat(targets, ", ") .. "|r")
  end

  local target = targets[1]
  if WR.ShouldReply(sender, target) then
    WR.replied[sender] = time()
    WR.Queue(WR.ReplyBody(target), sender, true)
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
  WR.others, WR.othersAt = nil, nil

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

--[[ A character we sent to is not online: a whisper refused, or an addon
     message the server could not deliver. True when it is the one we
     forward to, which is the case that stops things. ]]
function WR.Refused(name)
  local target = WR.Target()
  if not target or string.lower(name) ~= string.lower(target) then return false end

  -- The server repeats this for every forward still in flight; the first one
  -- has already stopped everything, so the rest are noise.
  if WR.offline[target] and (time() - WR.offline[target]) < 60 then return true end
  WR.TargetGone(target)
  return true
end

function WR.OnSystem(msg)
  if not WR.ready then return end
  local name = WR.NotFoundName(msg)
  if name then WR.Refused(name) end
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
  Print(WR.QuietStatus())
  Print("relay window for a whisper: " ..
    (WR.config.openChat and "opens by itself" or "stays shut until /wf chat"))
  local n = table.getn(WR.queue)
  if n > 0 then Print(n .. " message(s) still going out") end
end

--[[ Every command, grouped by what you would be trying to do.

     Printed in full by a bare /wf, because a command list you have to already
     know the name of is not discovery. It is long; that is the honest size of
     the thing, and the alternative was leaving half of it undocumented, which
     is what had happened -- the chat window and the reply commands were
     reachable and unmentioned. ]]
local function Usage()
  Print("commands:")
  local function line(cmd, what)
    DEFAULT_CHAT_FRAME:AddMessage("   |cffe0a22c" .. cmd .. "|r  " ..
      DIM .. what .. "|r")
  end

  line("/wf chat", "the relay window: read it all here and answer from it")
  line("/wr <message>", "answer a whisper AS the character they wrote to")
  line("/wp <message>", "talk in the party your other window is in")
  line("/wg <message>", "talk in the guild your other window is in")

  line("/wf", "this list, with the current state above it")
  line("/wf status", "the state on its own")
  line("/wf config", "every switch in one window")

  line("/wf auto", "find your other character rather than naming one")
  line("/wf to <char>", "forward to that character instead")
  line("/wf list", "characters it has seen on this machine")
  line("/wf forget <char>", "drop one, or 'all'")
  line("/wf on", "start forwarding again")
  line("/wf off", "stop forwarding entirely")

  line("/wf reply on|off", "answer whoever whispered you (off by default)")
  line("/wf reply <text>", "the wording. {char} becomes the live character")
  line("/wf reply default", "back to the stock wording, keeping yours")
  line("/wf every <secs>", "how often one person may be answered")

  line("/wf group", "forward party and raid chat to windows outside it")
  line("/wf guild", "forward guild chat to the relay window of those outside it")
  line("/wf alerts", "pass on battleground and dungeon queue pops")
  line("/wf popup", "show an arriving pop on screen, not only in chat")

  line("/wf inline", "clickable name in the message, or on a line under it")
  line("/wf link", "that fallback line, when the message cannot be rewritten")
  line("/wf echo", "note each forward in this window too")
  line("/wf quiet", "your windows talk in addon messages, not whispers (on)")
  line("/wf autoopen", "open the relay window when a whisper is forwarded here (on)")
  line("/wf minimap", "show or hide the minimap button")

  line("/wf demo", "show what a forward looks like, to test clicking")
  line("/wf testpop", "show the popup now")
  line("/wf test", "send a test forward to the other window")
end

function WR.Command(input)
  local msg = input or ""
  local cmd = string.lower((string.gsub(msg, "%s.*$", "")))
  local rest = string.gsub(msg, "^%S*%s*", "")

  if cmd == "" then
    Status()
    Usage()

  elseif cmd == "status" then
    Status()

  elseif cmd == "to" then
    local name = WR.Canonical((string.gsub(rest, "%s.*$", "")))
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
      -- Asked now, so the answer is in before the first whisper is.
      WR.Hello(name)
      Print("forwarding whispers to " .. OK .. name .. "|r.")
    end

  elseif cmd == "on" then
    WR.config.enabled = true
    -- Turning it back on means "try them again", so forget the refusal.
    WR.offline = {}
    WR.others, WR.othersAt = nil, nil
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
    elseif word == "default" then
      WR.config.replyDefault = true
      Print("auto-answer, back to the stock wording: " ..
        DIM .. WR.ReplyBody() .. "|r")
    elseif rest == "" then
      WR.config.autoReply = not WR.config.autoReply
      Print("auto-answer: " .. (WR.config.autoReply and "on" or "off"))
    else
      --[[ Sets the wording and nothing else. It used to switch the answering
           ON as well, so trying out a message quietly started sending it to
           people -- deciding what it WOULD say is not the same as asking for
           it to be said. ]]
      WR.config.replyText = rest
      WR.config.replyDefault = false
      Print("auto-answer wording: " .. DIM .. WR.ReplyBody() .. "|r")
      if not WR.config.autoReply then
        Print(DIM .. "answering is still off -- " ..
          "|cffe0a22c/wf reply on|r" .. DIM .. " to use it.|r")
      end
    end
    WR.RefreshPanel()

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
    WR.others, WR.othersAt = nil, nil
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

  elseif cmd == "config" or cmd == "options" or cmd == "settings" then
    WR.TogglePanel()

  elseif cmd == "quiet" then
    --[[ On its own it means "be quiet", never the opposite. As a toggle,
         typing it to make sure it was on switched it off. ]]
    WR.config.quiet = (string.lower(rest) ~= "off")
    WR.QuietChanged()
    if not WR.config.quiet then
      Print("quiet: off -- your windows whisper each other again.")
    elseif WR.QuietAPI() then
      Print("quiet: " .. OK .. "on|r -- your windows send each other addon " ..
        "messages instead of whispering. |cffe0a22c/wf status|r shows which " ..
        "have answered.")
    else
      Print("quiet: on, but this client has no addon messages -- your windows " ..
        "whisper each other as before.")
    end

  elseif cmd == "minimap" then
    WR.config.minimap = not WR.config.minimap
    WR.ShowMinimapButton()
    Print("minimap button: " .. (WR.config.minimap and (OK .. "shown|r.") or
      "hidden. |cffe0a22c/wf minimap|r brings it back."))

  elseif cmd == "autoopen" then
    WR.config.openChat = not WR.config.openChat
    Print("the relay window " .. (WR.config.openChat
      and (OK .. "opens|r when a whisper is forwarded here.")
      or "stays shut until |cffe0a22c/wf chat|r."))

  elseif cmd == "group" then
    WR.config.groupChat = not WR.config.groupChat
    Print("forwarding party and raid chat: " ..
      (WR.config.groupChat and "on" or "off"))

  elseif cmd == "guild" then
    WR.Toggle("guildChat")
    Print("forwarding guild chat: " .. (WR.config.guildChat and
      ("on -- it goes to the Guild tab of the relay window, and you answer " ..
       "from there or with |cffe0a22c/wg|r.") or "off."))

  elseif cmd == "chat" or cmd == "window" then
    WR.ToggleChat()

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
frame:RegisterEvent("CHAT_MSG_PARTY")
frame:RegisterEvent("CHAT_MSG_RAID")
frame:RegisterEvent("CHAT_MSG_RAID_LEADER")
frame:RegisterEvent("CHAT_MSG_RAID_WARNING")
frame:RegisterEvent("CHAT_MSG_GUILD")
frame:RegisterEvent("PLAYER_LOGOUT")

function WR.Init()
  if WR.ready then return end

  WhisperRelayDB = WhisperRelayDB or {}
  for k, v in pairs(defaults) do
    if WhisperRelayDB[k] == nil then WhisperRelayDB[k] = v end
  end
  WR.config = WhisperRelayDB
  WR.me = UnitName("player") or "Unknown"
  WR.ready = true

  -- Saved by an older copy exactly as it was typed.
  if WR.config.target then WR.config.target = WR.Canonical(WR.config.target) end
  -- Left by a test build that passed messages through the shared folder.
  WR.config.seen = nil

  if WR.config.target == WR.me then
    -- Saved per account, so logging in on the target itself is normal.
    WR.config.target = nil
  end

  WR.ShowMinimapButton()

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
    WR.HookWorldClicks()
    WR.QuietStart()
    WR.AskRoster()
  elseif event == "CHAT_MSG_WHISPER" then
    WR.OnWhisper(arg1, arg2)
  elseif event == "CHAT_MSG_SYSTEM" then
    WR.OnSystem(arg1)
  elseif event == "UPDATE_BATTLEFIELD_STATUS" then
    WR.OnBattlefield()
  elseif event == "CHAT_MSG_ADDON" then
    WR.OnAddonMessage(arg1, arg2, arg4)

  elseif event == "CHAT_MSG_PARTY" then
    WR.OnGroupChat("P", arg1, arg2)
  elseif event == "CHAT_MSG_RAID" or event == "CHAT_MSG_RAID_LEADER" then
    WR.OnGroupChat("R", arg1, arg2)
  elseif event == "CHAT_MSG_RAID_WARNING" then
    WR.OnGroupChat("W", arg1, arg2)
  elseif event == "CHAT_MSG_GUILD" then
    WR.OnGroupChat("G", arg1, arg2)
  elseif event == "PLAYER_LOGOUT" then
    -- So the other windows stop sending here, and ask again once we are back.
    if WR.ready then WR.QuietLogout() end
  end
end)

frame:SetScript("OnUpdate", function()
  if not WR.ready then return end
  WR.uptime = WR.uptime + (arg1 or 0)
  WR.Settle()
  WR.Beat(arg1 or 0)
  WR.Flush(arg1 or 0)
end)

SLASH_WHISPERRELAY1 = "/wf"
SLASH_WHISPERRELAY2 = "/whisperforward"
SLASH_WHISPERRELAYREPLY1 = "/wr"
SlashCmdList["WHISPERRELAYREPLY"] = function(msg) WR.ReplyThrough(msg) end

SLASH_WHISPERRELAYPARTY1 = "/wp"
SlashCmdList["WHISPERRELAYPARTY"] = function(msg) WR.SayInGroup(msg) end

SLASH_WHISPERRELAYGUILD1 = "/wg"
SlashCmdList["WHISPERRELAYGUILD"] = function(msg) WR.SayInGuild(msg) end
SlashCmdList["WHISPERRELAY"] = function(msg) WR.Command(msg) end
