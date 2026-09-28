# Hookling

A desktop pet for macOS that reacts to what Claude Code is doing. It runs while
tools are running, looks up when Claude needs your input, perks up when a turn
lands, and goes to sleep when you stop working.

It is a menu bar accessory: no Dock icon, no window chrome, and it never takes
focus from the editor or terminal you are actually using.

It is compatible with the spritesheet format used by the terminal pets in
OpenAI's Codex CLI, so it can render a pet you already have in your local Codex
cache, a community pet, or your own pixel art. It is an independent
implementation written from scratch in Swift. It is not a fork of Codex, and it
contains no Codex source code and no Codex artwork.

> **Unofficial.** This is an independent community project. It is not
> affiliated with, endorsed by, or sponsored by OpenAI or Anthropic. "Codex",
> "Seedy" and "OpenAI" are trademarks of OpenAI; "Claude" and "Claude Code" are
> trademarks of Anthropic. They are used here only to describe what this
> software works with. No artwork is included: see [Artwork](#artwork), which is
> the first thing to sort out.

## What it looks like

The pet expresses one of eight states. Four are Codex's own; the rest exist
because Claude Code exposes more lifecycle detail, and they reuse existing
artwork rather than inventing any.

| State       | Label       | Animation | When                                    |
| ----------- | ----------- | --------- | --------------------------------------- |
| `waiting`   | Needs input | waiting   | Blocked on you — a permission prompt     |
| `failed`    | Blocked     | failed    | A turn ended in an error                 |
| `working`   | Running     | running   | Tools are running                        |
| `success`   | Done        | jumping   | A turn just landed                       |
| `review`    | Ready       | review    | Turn finished, waiting on your next move |
| `attentive` | Hello       | idle      | A session just opened                    |
| `idle`      | Idle        | idle      | Nothing happening                        |
| `sleeping`  | Asleep      | idle (frozen) | Quiet for 15 minutes                 |

While `idle` — and only then — he wanders: every 8–20 seconds he sets off on a
150–600pt stroll using the two walk cycles in the spritesheet, turning around at
the edge of the screen. He stops mid-stride the instant Claude does anything, and
wherever he ends up is where he reappears next launch. Turn it off with "Wander
when idle" in the menu bar. Asleep he still costs exactly nothing.

The order matters: it is also the priority order. When several Claude Code
windows disagree, the highest wins — `waiting` beats everything because it is the
only state that means "I am blocked until you do something", and `review` sits
*below* `working` so a finished turn in one terminal never masks a turn still
running in another.

## Install

There are two ways in. **The prebuilt app is quicker** and needs no developer
tools. Building from source gives the same result, if you would rather compile
it yourself.

### 1. Check the requirements

* **macOS 13 (Ventura) or later**, on Apple Silicon or Intel.
* **Claude Code.**
* Only if you build from source: the **Xcode Command Line Tools**. Run
  `xcode-select --install`; it either installs them or says they are already
  there. Full Xcode is not needed.

### 2. Install the app

**Prebuilt (recommended).** Paste this into Terminal:

```sh
curl -fsSL https://raw.githubusercontent.com/matias-mn/hookling/main/scripts/install.sh | bash
```

It downloads the latest release, checks its checksum, puts `Hookling.app` in
`/Applications` (or `~/Applications` if that is not writable, and it never asks
for your password), and starts it. The script is short; [read it
first](scripts/install.sh) if you like.

<details>
<summary>Prefer to download it yourself?</summary>

1. Download `Hookling.zip` from the
   [latest release](https://github.com/matias-mn/hookling/releases/latest) and
   double-click it to unzip.
2. Drag `Hookling.app` into your Applications folder.
3. Open it. **macOS will refuse the first time**, with a message that Apple
   could not verify it. That is because Hookling is not notarized by Apple
   (notarization needs a paid developer account), not because anything is
   wrong with it. To allow it, open **System Settings → Privacy & Security**,
   scroll down to the message about Hookling, and click **Open Anyway**. Or run
   this once in Terminal:
   ```sh
   xattr -dr com.apple.quarantine /Applications/Hookling.app
   ```

</details>

**Or build from source:**

```sh
git clone https://github.com/matias-mn/hookling.git
cd hookling
./scripts/build.sh
./scripts/run.sh
```

The build ends with `Done`. Everything it produces stays in `build/` inside
this folder. Running `./scripts/run.sh` again is always safe: it replaces the
running pet rather than starting a second one.

**Either way**, a paw print appears in the menu bar. That is where every setting
lives, including **Launch at login** if you want the pet back after a restart.
The pet itself appears on your desktop once it has artwork (step 4).

### 3. Connect Claude Code

**Open the app at least once first.** When it starts, it installs the small
hook program that Claude Code runs, so the plugin has something to call.

Then run these two commands inside Claude Code:

```
/plugin marketplace add matias-mn/hookling
/plugin install hookling@hookling
```

Then **quit and reopen Claude Code**. Plugins load at startup, so terminals
that were already open will not talk to the pet until they are restarted.

<details>
<summary>Working on Hookling itself? Install the plugin from your checkout instead.</summary>

Use the full path of your clone (run `pwd` inside it) in place of
`matias-mn/hookling`:

```
/plugin marketplace add /Users/you/hookling
/plugin install hookling@hookling
```

**Type the path without quotes**, even if it contains spaces. The `/plugin`
prompt takes the text literally, so quotes become part of the path and it is
rejected as "not a valid GitHub owner/repo". Run `./scripts/build.sh` before
installing: Claude Code copies the plugin, with the hook you compiled, at the
moment you install it, and that copy takes priority over the app's.

</details>

### 4. Get some pet artwork

**No artwork is included** (see [Artwork](#artwork) for why), so the pet needs
a spritesheet from somewhere. Pick one:

* **You use Codex:** run `codex`, type `/pets`, choose any pet, and quit Codex.
  That is all: Hookling finds it in Codex's cache by itself. If Hookling was
  already running, quit it from the menu bar and open it again.
* **You want a community pet** from [codex-pets.net](https://codex-pets.net):
  install it with `npx codex-pets add <id>`, where the id is the last part of
  the pet's page URL (`codex-pets.net/#/pets/goku` is `goku`). Then choose
  "Choose pet artwork…" from the menu bar and pick
  `~/.codex/pets/<id>/spritesheet.webp` (in the file picker, press
  **⌘⇧G** and paste the path). Only version 1 pets work; see
  [Community pets](#community-pets). From a source checkout,
  `./scripts/fetch-pet.sh --community <id>` does all of this and checks the
  version for you.
* **You have your own artwork:** any 1536×1872 PNG or WebP laid out as an 8×9
  grid of 192×208 frames works. Choose it with "Choose pet artwork…".
* **You just want to see it run first:** generate a numbered test sheet and
  choose that:
  ```sh
  ~/Library/Application\ Support/Hookling/bin/hooklingctl testsheet ~/Desktop/test-sheet.png
  ```

### 5. Check that it works

Ask Claude Code to do anything that uses a tool, such as reading a file. The pet
should switch to its running animation while the tool runs, then celebrate when
the turn finishes.

The app also installs `hooklingctl`, a small command for checking on the pet,
next to the hook. To see what the pet thinks is going on:

```sh
~/Library/Application\ Support/Hookling/bin/hooklingctl status
```

`sessions: 1` or more means Claude Code is reaching it. If it says
`sessions: 0`, see [Troubleshooting](#troubleshooting).

To watch every animation once, with captions:

```sh
~/Library/Application\ Support/Hookling/bin/hooklingctl demo
```

If you will use it often, put it on your `PATH`:

```sh
echo 'export PATH="$HOME/Library/Application Support/Hookling/bin:$PATH"' >> ~/.zshrc
```

## Updating

**Prebuilt:** run the install command from step 2 again. It replaces the app
and restarts it, and the new app updates the hook when it starts.

**From source:**

```sh
cd hookling
git pull
./scripts/build.sh
./scripts/run.sh
```

The plugin itself rarely changes, since the hook comes from the app. When a
release says it did, update it from Terminal and restart Claude Code:

```sh
claude plugin marketplace update hookling
claude plugin update hookling@hookling
```

## Uninstalling

1. In Claude Code:
   ```
   /plugin uninstall hookling@hookling
   /plugin marketplace remove hookling
   ```
2. In the menu bar, turn off "Launch at login" if you turned it on, then choose
   "Quit Hookling".
3. Delete the app (`/Applications/Hookling.app`, or the `hookling` folder if
   you built from source), and the little that lives outside it:
   ```sh
   rm -rf ~/Library/Application\ Support/Hookling
   defaults delete dev.hookling
   ```

Artwork in `~/.codex` belongs to Codex and is left alone.

## Troubleshooting

The commands below use `hooklingctl` from where the app installs it. From a
source checkout, `./build/bin/hooklingctl` is the same program.

**macOS says Hookling "cannot be opened" or that Apple "could not verify" it.**
You downloaded it in a browser. See "Prefer to download it yourself?" in
step 2 for the one-time fix, or use the install command instead, which avoids
the problem.

**The pet does not appear.** Look for the paw print in the menu bar. If it is
there, the pet may be hidden: open the menu and choose "Show Hookling", or
"Reset position" if it has walked off a screen you have since unplugged. If the
menu says the artwork is missing, go back to step 4. If there is no paw print,
the app is not running: open it from Applications (or `./scripts/run.sh` from
source, which logs to `build/hookling.log`).

**The pet does not react to Claude Code.** Work through these in order:

1. `~/Library/Application\ Support/Hookling/bin/hooklingctl status`. If the
   file does not exist, the app has never been opened: open it, then try
   again. If it says the pet is not running, open the app.
2. In Claude Code, run `/plugin` and check that `hookling` is installed and
   enabled.
3. Quit and reopen Claude Code. Every open terminal needs a restart after an
   install or update.
4. Test the hook by itself. Normally it fails silently so it can never get in
   Claude Code's way; with `HOOKLING_HOOK_DEBUG=1` it prints the reason instead.
   No output means the event was delivered:
   ```sh
   HOOKLING_HOOK_DEBUG=1 ~/Library/Application\ Support/Hookling/bin/hookling-hook work_started </dev/null
   ```

**"not a valid GitHub owner/repo" when adding the marketplace.** There is a
typo in `matias-mn/hookling`, or, for a local checkout, the path has quotes
around it. See step 3.

**There seem to be two pets.** Run `ps -ax | grep -i hookling`. Only one
`Hookling` process should be listed. If there are more, run `pkill -x Hookling`
and open the app again.

## Artwork

**This project ships no Seedy artwork, because it has no right to.** The code is
MIT; the artwork is OpenAI's and stays on your machine.

The spritesheet is not in the Codex repository either — Codex downloads it at
first use into your own `CODEX_HOME` cache. So the safest path, and the default,
is to read the copy that is already there. The app does this by itself, and
neither the app nor the release download contains any artwork.

The rest of this section uses `scripts/fetch-pet.sh`, which is in a source
checkout (`git clone https://github.com/matias-mn/hookling.git`). It works the
same with the prebuilt app. Run with no arguments, it looks for the artwork:

```sh
./scripts/fetch-pet.sh
```

If it is not found, the script says exactly where it looked and lists your
options: let Codex fetch it (`codex`, then `/pets`, then pick Seedy), point at
artwork you already have, or fetch from the same public CDN Codex uses — which is
deliberately behind an explicit `--from-cdn` flag, with the caveat printed first.

The renderer is asset-agnostic: **any 8×9 grid of 192×208 frames works**
(1536×1872 total). Any of the Codex pets will do, as will your own pixel art.
Point at it with `HOOKLING_SPRITESHEET=/path/to/sheet.png`, or pick it from the menu
bar with "Choose pet artwork…".

Choosing a pet in Codex downloads **all eight**, so you can swap freely:

```sh
./scripts/fetch-pet.sh --list-pets       # what is in your Codex cache
./scripts/fetch-pet.sh --pet fireball    # render as Fireball instead
./scripts/fetch-pet.sh --pet none        # back to normal discovery
```

They are read in place from the Codex cache — nothing is copied, and the choice
persists as the same preference the menu writes.

`assets/pet/*.webp` is gitignored, so the artwork can never be committed by
accident. The full analysis — what was checked, what it concluded, and where it
is uncertain — is in [docs/licensing.md](docs/licensing.md).

### Community pets

[codex-pets.net](https://codex-pets.net) is a community gallery of shared pets.
Grab one by the id in its page URL:

```sh
./scripts/fetch-pet.sh --community goku     # codex-pets.net/#/pets/goku
./scripts/run.sh
```

It installs into `~/.codex/pets/<id>/`, the same place `npx codex-pets add <id>`
uses, so the two are interchangeable and neither puts artwork in this repo.
`--list-pets` shows both sources; `--pet <name>` switches between them.

**Most of that gallery will not work here.** The site hosts two sprite formats:
version 1 is the 1536x1872 grid Codex and this app speak, and version 2 is a
taller 1536x2288 sheet with extra rows we have no states for. Roughly a fifth of
the pets are v1. `--community` reads the version from the API and refuses a v2
sheet before downloading it, rather than letting the app fail to decode one you
have already waited for.

That artwork belongs to whoever uploaded it. This project neither ships nor
vouches for any of it.

## Privacy

Nothing about your work leaves the machine, and almost none of it is even read.

* The pet listens on a **Unix domain socket**, not a TCP port. It cannot be
  reached from another machine even by accident.
* The hook sends **one line of JSON per event**:
  `{"event":"work_started","session":"369ee3f3c2e67286"}`. The event name is a
  literal from `hooks.json`, never derived from the payload.
* The session field is an **FNV-1a hash** of `session_id`, so the pet can tell two
  windows apart while holding nothing that maps back to a transcript.
* Prompts, tool arguments, file contents and tool output are **never read into
  memory in full, never written anywhere, and never sent**. The hook scans stdin
  through a small sliding window that is overwritten as it goes and wiped before
  it returns.
* The hook **always exits 0**, including when the pet is not running, and gives up
  on the socket after ~150 ms. A desktop pet is never a reason for a tool call to
  fail.

## How it works

```
Claude Code ──hooks──> hookling-hook (C) ──unix socket──> Hookling.app
                                            ▲
                                       hooklingctl (debug)
```

| Component                | What it is                                                |
| ------------------------ | --------------------------------------------------------- |
| `app/Sources/HooklingCore`  | The engine: state machine, session merge, animation timing, wire codec. No AppKit, fully tested. |
| `app/Sources/Hookling`| The app: window, menu bar, sprite rendering, socket server. |
| `app/Sources/hooklingctl`   | CLI for driving and inspecting the pet without Claude Code. |
| `adapters/claude-code`   | The hook and plugin manifest. The only part that knows Claude Code exists. |

The split is the point. `HooklingCore` speaks a **generic event vocabulary**
(`work_started`, `attention_needed`, `session_ended`…), and each adapter
translates its own tool's lifecycle into those names. Supporting another editor or
agent means writing a new `hooks.json`, not touching the app. It also means the
whole end-to-end behaviour is testable without AppKit, without sockets, and
without Claude Code — which is why there are over 100 tests and no UI test harness.

The hook is C rather than Swift for one reason: `PreToolUse` and `PostToolUse`
fire on **every single tool call**, so process startup dominates. C starts in
about a millisecond against ten or more for a Swift equivalent.

States decay on a timer rather than needing a matching "stop" event, so a
terminal that crashes mid-turn resolves itself instead of leaving the pet running
forever. `working` expires after 3 minutes, `review` after 90 seconds, `failed`
after 60, and `waiting` only after 30 minutes — being blocked on you is not
something that should quietly time out. The pet sleeps after 15 minutes of quiet.

See [adapters/claude-code/README.md](adapters/claude-code/README.md) for the full
hook-to-event mapping.

## hooklingctl

```
hooklingctl status             report state, sessions and artwork
hooklingctl snapshot           write a PNG of the frame on screen right now
hooklingctl demo               walk every animation, captioned on screen
hooklingctl list               list the animations in animations.json
hooklingctl <state>            force a state (waiting, working, failed…)
hooklingctl <animation>        play an animation once over the current state
hooklingctl emit <event>       send a generic adapter event
hooklingctl testsheet <path>   write a numbered diagnostic spritesheet
hooklingctl pause | resume     stop or resume reacting to adapter events
hooklingctl wander on | off    let him stroll about while idle
hooklingctl reset              forget all sessions and return to idle
hooklingctl quit               send him home
```

It exits 0 when the pet is not running, so it is safe to call from a hook.

## Development

```sh
./scripts/test.sh           # build everything and run the test suite
./scripts/package.sh        # build the universal release zip into dist/
```

`scripts/package.sh` builds for both Apple Silicon and Intel, never copies
artwork into the bundle (and fails if it finds any), and writes
`dist/Hookling.zip` plus its SHA-256. To publish a release, bump `version` in
`adapters/claude-code/plugin/.claude-plugin/plugin.json`, then:

```sh
./scripts/package.sh
gh release create v<version> dist/Hookling.zip dist/Hookling.zip.sha256
```

The asset names never change, so the install command always fetches the newest
release.

`HOOKLING_SOCKET` overrides the socket path, so you can run a second pet side by
side without the two fighting over it. `HOOKLING_HOOK_DEBUG=1` makes the hook
explain itself on stderr instead of failing silently.

## Licence

Code in this repository is **MIT** — see [LICENSE](LICENSE).

Behaviour re-implemented from Codex (the animation data table and the
frame-selection algorithm) is credited in [NOTICE](NOTICE) with the upstream
Apache-2.0 attribution and the specific files involved. No Codex source was
copied verbatim; the teardown is in
[docs/codex-pet-analysis.md](docs/codex-pet-analysis.md).

Seedy artwork: **OpenAI's, not distributed here, no rights granted.**
