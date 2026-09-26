# Whisper Relay

Multi-boxing on WoW 1.12. A whisper landing on one of your windows is
forwarded to **every other one running on this machine**. Four accounts means
three windows you are not looking at, and whichever one you happen to be in
front of has the message, with the sender's name clickable so you can answer
from there.

It does the same for party and raid chat, and for battleground and dungeon
queue pops, which expire on a timer while you are looking somewhere else.

Your windows pass all of this to each other through a folder they share, not
by whispering, so none of the back and forth between your own characters shows
up in chat — see [The quiet channel](#the-quiet-channel).

## Install

Drop the `WhisperRelay` folder into `Interface\AddOns`, then **restart the
client** — 1.12 only scans for new addon folders at launch, so `/reload` will
not find a folder that was not there when it started.

## Setup

None. Start both clients and each works out which character the other is on.
Switch to a different alt and it follows, with nothing typed.

Everything else is optional. **`/wf` on its own prints the whole command list,
with the current state above it.**

## The relay window

    /wf chat

Everything relayed lands here — whispers, party and raid chat, queue pops —
and the box at the bottom sends your answer back.

Every line leads with **which of your characters it reached**, in one colour
nothing else uses, so several windows talking at once stay apart at a glance:

    Salahaja  from [Bobby]: you around?
    Salahaja  Party [Charlie]: pull in 10
    Salahaja  ! Warsong Gulch is ready to join
    Salahaja  to Bobby: five minutes

The last of those is something you sent — shown as the character that actually
said it, not as whoever typed it, that being the whole point of sending it
through. Sender names stay clickable.

### Tabs

**All**, **Whispers**, **Party**. Whispers and party chat arrive at different
rates about different things, and the one you are watching is rarely the one
filling the window. A tab you are not on turns amber when something lands on
it.

**The tab decides where Enter goes.** On Whispers you are answering the
whisper; on Party you are talking to the group. On All it follows whatever
arrived last, and **switch** overrides that — switch is hidden on the tabs
where it would only contradict them. A tab with nothing to answer says so and
refuses rather than quietly answering the other thing. Your replies land on
the tab they answer.

Drag the window to move it, the grip at the bottom-right to resize it, the
mouse wheel to scroll. The size is remembered, and the last 60 lines are kept
while it is closed.

## Answering the sender automatically

**Off by default.** It is a bot reply appearing in someone else's window, which
should be a decision:

    /wf reply on
    /wf reply Busy on {char} right now

`{char}` becomes the character you are on. Setting the wording does **not**
switch answering on — deciding what it would say is not the same as asking for
it to be said, and it tells you so. `/wf reply default` goes back to the stock
wording without discarding yours, and `/wf every <seconds>` sets how often one
person may be answered (300 by default, so it reads as an away message rather
than as spam).

`/wf config` has the same settings in a window, including a box to type the
wording with a preview of the finished sentence.
## How it knows which character to forward to



Both clients are the same installation, so they share `CustomData/`, and
Nampower's file API lets Lua read and write in it. Each client leaves a line
there once a minute saying which character is logged in, and reads the others.
A character counts as live if its last line is under three minutes old.

SavedVariables cannot do this — they are per account and written at logout, so
the account you are playing has no way to see the other one's. A folder both
processes already share is the only thing on this client that crosses that
line.

Every character that logs in on this machine writes a line, across every
account you run -- two, or six -- so the list builds itself with nothing typed,
ever. `/wf list` shows what it has seen and which of them is logged in now.

This is per installation, which is the point: give the addon to a friend and
his copy keeps his own list, built from his own characters on his own
accounts. Nothing is shared between your machine and his, and nothing needs to
be. You each relay your own windows.

What the list is NOT is a way to pick a target on a hunch. Forwards follow the
shared folder, and a name is only ever used because you typed it with
`/wf to <character>`. Guessing from anywhere else would mean sending private
messages to whoever happened to be online.

One caveat:
- **With three or more clients running** it forwards to whichever spoke most
  recently, not to all of them.

When nothing else is logged in, nothing is forwarded and the sender is not
auto-answered — telling someone to go whisper a character who is offline would
be worse than saying nothing. `/wf` lists every character the shared file has
heard from and how long ago, so a client that is not joining in is obvious.

## The quiet channel

Everything your windows tell each other — forwards, `/wr` and `/wp`, party
chat, queue pops — used to be a whisper, and a whisper shows up twice:
`To Salahaja: >> Bobby: you around?` in the window sending it, and the whisper
itself in the window getting it. With two or three windows relaying, that was
most of what the chat frame said.

Now your windows on this machine leave each other messages in the same shared
folder instead, and nothing crosses the server at all. A forward still arrives
in the window you are looking at, with the whisper sound and the name
clickable:

    [Bobby] whispers: you around?  (via Salahaja)

— and there is no `To ...` line in the window that passed it on, or anywhere
else.

Why not an addon channel, which is how addons usually talk out of sight? On
1.12 an addon message only travels over a party, raid, battleground or guild
channel, so your windows would have to be grouped or guilded together to hear
each other at all. And it goes to *everyone* in that channel, which is no
place for somebody's private whisper. The folder needs neither, and nothing in
it leaves your PC.

Each window writes one file of its own, its outbox, and nothing else ever
writes it. The others read it a few times a second and take what is addressed
to them, once each. A `/reload` on either side shows you nothing twice, and
anything that was waiting is still picked up afterwards.

**What is still a whisper:**

- anyone who is not one of your windows on this machine — a friend you
  forward to with `/wf to`, a second PC, and the auto-answer;
- the reply `/wr` sends to the person who wrote to you, because that one is
  the conversation;
- a window running an older copy of Whisper Relay, or with quiet switched off
  — it never says it reads the folder, so nothing is left there for it;
- a window that has logged out, or has stopped answering for half a minute.

`/wf quiet off`, or the switch in `/wf config`, goes back to whispers for
everything, and tells your other windows at once so they stop leaving this one
mail. It needs Nampower's file API, the same as automatic mode, and without it
everything is a whisper as before. `/wf status` names the windows it reaches
without whispering.

## Answering

Clicking a forwarded name opens a whisper to that person **from the character
you are on**. When you would rather answer as the character they actually
wrote to:

    /wr yes, five minutes

The window the whisper arrived on says it, so from their side it is simply a
conversation with the character they started one with.

For party and raid chat, the same idea:

    /wp I'll tank

The window that **is** in the group says it. Party or raid is decided by that
window, which knows which it is in and can have changed since you read the
line. If it has left the group, it says so rather than shouting into nothing.

Both are only ever honoured **from one of your own windows**. From anyone else,
a request like that is a way to make you whisper arbitrary text to arbitrary
people, or talk in a group you are in, under your own name.

The relay window does both without you choosing, which is why it exists.
### If the name is not clickable

    /wf demo

That prints a forward without needing anyone to whisper you, says whether the
chat hook is installed, and prints the link a second time with its escapes
visible. Nothing at all means the addon is not loaded — **a newly added addon
folder is only picked up when the client starts, not by `/reload`.** Escapes
showing as text means the chat frame is not turning links into links.



## Party and raid chat

When one character is in a group and another window is not, that window hears
nothing. `/wf group` forwards the chat to it:

    [Salahaja Party] Bobby pull in 10

The speaker's name is clickable, since they are not in a channel you can
answer from there. Party, raid, raid leader and raid warnings all come through,
colour-coded by which.

It only goes to windows that are **not in that group** — a character standing
in the same party already has every line in its own chat, and sending it again
would be an echo, one per window.

## When something pops

A battleground invite and a dungeon group both expire on a timer, and both
land on whichever client is queued -- routinely the one nobody is watching.
So when one pops here, the other window is told:

    [Salahaja]  Warsong Gulch is ready to join

Battlegrounds use the standard queue API. Dungeons use this server's own LFT
system, which announces an offer over an addon channel; a client without that
system simply never sees one. `/wf alerts` turns both off.

On the window you are playing it arrives as a box in the middle of the screen
with a sound, not only a chat line -- a chat line is exactly what you miss
while looking at the other window. Click it to dismiss, or leave it and it
clears itself after a minute. `/wf testpop` shows one now; `/wf popup` turns
it off and leaves the chat line alone.

It is a frame of its own rather than a StaticPopup, because a battleground
invite lands at exactly the moments the default popup slots are busy -- a loot
roll, a resurrect, a group invite -- and a dialog that queues behind those is
one that appears after the thing it was warning about expired.

A standing invite makes the queue event fire repeatedly, so an alert is sent
when a queue becomes ready and not again until it does so afresh.

## Loops

Automatic mode points both clients at each other, which is the obvious setup
and also the obvious way to bounce one whisper between them until the server
disconnects both for spam. Out of the box is therefore exactly the arrangement
that has to be safe, so three things are never forwarded and never
auto-answered:

- anything from the character you forward *to*
- anything already carrying the `>>` marker, or the `>!` one alerts use
- anything from yourself

Mail left through the quiet channel never gets that far: it is shown, or
acted on when it is a `/wr` or `/wp`, and is never forwarded again.

`tools/test_relay.lua` loads two real copies of the addon, points them at each
other and feeds one client's output into the other, which is the only way to
test this properly.

## Worth knowing

- **Between your own windows nothing is whispered**, so the text of your
  private messages stays on your PC. A forward to anyone else — a friend, a
  second PC — is a real whisper, and travels over the wire the same way any
  whisper does. If that matters, don't forward to them.
- **Whispers over 255 characters are split** into up to three parts, marked
  `1)`, `2)`. An item link that lands on a split will not survive as a link.
- **A target that is not online stops it rather than being shouted at.** One
  forward that goes nowhere is a message lost; the next twenty are the same
  message lost twenty times, one server error each, while you carry on
  believing you are covered. The first refusal drops whatever is still queued
  for them and says how many. With a named target, forwarding switches off
  (`/wf on` or naming someone else resumes it). In automatic mode there is
  nothing to switch off -- it moves to whoever else is logged in, and comes
  back to that character when they next say they are here.
- **The auto-answer is a bot reply.** Five minutes per person is the default
  so that it reads as an away message rather than as spam.
- **Nothing in a marker may contain `%`.** WoW expands `%t` in outgoing chat as
  your current target, so a marker ending in `%` turns the next letter into a
  substitution token -- which is exactly what made every `/wp` message
  beginning with *t* fail with "no target" in 1.5.0. There is a test asserting
  it of all the markers rather than of the one that bit.


## Commands

`/wf` on its own prints all of this in game, with the current state above it.

| Command | What it does |
| --- | --- |
| `/wf chat` | The relay window: read it all here and answer from it |
| `/wr <message>` | Answer a whisper AS the character they wrote to |
| `/wp <message>` | Talk in the party your other window is in |
| `/wf` | The command list, with the current state above it |
| `/wf status` | The state on its own |
| `/wf config` | Every switch in one window |
| `/wf auto` | Find your other character rather than naming one |
| `/wf to <char>` | Forward to that character instead, and remember the name |
| `/wf list` | Characters it has seen on this machine, and who is logged in |
| `/wf forget <char>` | Drop one, or `all` |
| `/wf on` / `/wf off` | Forwarding, as a whole |
| `/wf reply on\|off` | Answer whoever whispered you (off by default) |
| `/wf reply <text>` | The wording. `{char}` becomes the live character |
| `/wf reply default` | Back to the stock wording, keeping yours |
| `/wf every <secs>` | How often one person may be answered |
| `/wf group` | Forward party and raid chat to windows outside it |
| `/wf alerts` | Pass on battleground and dungeon queue pops |
| `/wf popup` | Show an arriving pop on screen, not only in chat |
| `/wf inline` | Clickable name in the message, or on a line under it |
| `/wf link` | That fallback line, when the message cannot be rewritten |
| `/wf echo` | Note each forward in this window too |
| `/wf quiet [on\|off]` | Your windows on this PC talk through the shared folder, not whispers (on) |
| `/wf demo` | Show what a forward looks like, to test clicking |
| `/wf testpop` | Show the popup now |
| `/wf test` | Send a test forward to the other window |

Settings are saved per account, so each account is set up once.

## Development

    lua tools/vanilla_lint.lua WhisperRelay.lua   # 1.12 / Lua 5.0 compatibility
    lua tools/test_relay.lua                      # several clients, one machine
