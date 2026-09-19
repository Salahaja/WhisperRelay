# Whisper Relay

Dual-boxing on WoW 1.12: when a whisper lands on the character you are *not*
watching, it is forwarded — as a whisper — to the character you are, with the
sender's name attached. It can also answer the sender to tell them which
character you are actually on.

The forwards travel as ordinary whispers, so the relay itself works whether
your other account is a second copy of the client, a second machine, or a
friend covering for you. Working out *which* character to forward to
automatically does need both clients on one machine — see *How it knows*.

## Install

Drop the `WhisperRelay` folder into `Interface\AddOns`.

## Setup

None. Start both clients and each one works out which character the other is
on. Whispers to the window you are not watching arrive in the one you are:

    >> Bobby: you around for Strat tonight?

and Bobby is told, at most once every five minutes:

    Not watching this one right now - I'm on Salabeard, whisper me there.

Switch to a different alt and it follows, with nothing typed.

### How it knows

Two ways, in that order.

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

## Replying

On the window you are playing, a forward is shown with the sender's name
clickable:

    [Bobby] whispers: you around for Strat tonight?  (via Salahaja)

Left-click the name and the whisper box opens to Bobby, from the character you
are on.

The link is built by the addon on the receiving side, not carried in the
forward, because 1.12 strips link escapes out of anything `SendChatMessage`
sends — a `|Hplayer|` link put into the whisper would arrive as mangled text.
Getting it *inside* the line means suppressing the client's own display, which
means standing in front of `ChatFrame_OnEvent`.

That global is one other chat addons replace too. If one of them takes it back
after us, or bypasses it, the rewrite never runs — so nothing depends on it:
whatever is not rewritten falls back to a clickable name on a short line
underneath.

    >> Bobby: you around for Strat tonight?
        reply to [Bobby]  (forwarded by Salahaja)

`/wf inline` chooses between the two deliberately; `/wf link` turns the
fallback line off.

### If the name is not clickable

    /wf demo

That prints a forward without needing anyone to whisper you, says whether the
chat hook is installed, and prints the link a second time with its escapes
visible. Nothing at all means the addon is not loaded — **a newly added addon
folder is only picked up when the client starts, not by `/reload`.** Escapes
showing as text means the chat frame is not turning links into links.

## Commands

| Command | What it does |
| --- | --- |
| `/wf` | Status: who it found, every client it can see, what the auto-answer says |
| `/wf auto` | Find your other character instead of naming one (default on) |
| `/wf to <character>` | Forward to that character, and remember the name |
| `/wf list` | Every character seen on this machine, and which are logged in |
| `/wf forget <character>` | Drop one (or `all`) from that list |
| `/wf on` / `/wf off` | Stop and start forwarding |
| `/wf test` | Send a test forward, so you can check the target without waiting for a real whisper |
| `/wf reply` / `/wf reply on|off` | Turn the auto-answer on or off |
| `/wf reply <text>` | Set what it says. `{char}` is replaced with the target |
| `/wf every <seconds>` | How often one person may be auto-answered (default 300) |
| `/wf inline` | Clickable name inside the message (default) or on a line underneath |
| `/wf link` | The fallback line, when the message could not be rewritten |
| `/wf demo` | Show a forward now, to test whether the name is clickable |
| `/wf alerts` | Tell the other window when a battleground or dungeon pops (default on) |
| `/wf popup` | Show an arriving pop on screen, not only in chat (default on) |
| `/wf testpop` | Show the popup now, without waiting for a queue |
| `/wf echo` | Whether to note each forward in this window too |

Settings are saved per account, so each account is set up once.

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

`tools/test_relay.lua` loads two real copies of the addon, points them at each
other and feeds one client's output into the other, which is the only way to
test this properly.

## Worth knowing

- **The forwards are real whispers.** The text of your private messages
  travels over the wire the same way any whisper does. If that matters, don't
  forward.
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

## Development

    lua tools/vanilla_lint.lua WhisperRelay.lua    # 1.12 / Lua 5.0 compatibility
    lua tools/test_relay.lua                       # two simulated clients
