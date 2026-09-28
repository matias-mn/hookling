# Codex pet analysis

Everything in this document was read from `openai/codex@main` while building
hookling. It is the specification the renderer implements. Where a value
appears in code here, it came from a line cited below — nothing was guessed.

Upstream files consulted (all under `codex-rs/tui/src/`):

| file | what it told us |
|---|---|
| `pets/catalog.rs` | frame geometry, sheet geometry, Seedy's filename |
| `pets/model.rs` | the animation table, per-frame durations, track composition, validation rules |
| `pets/ambient.rs` | the frame-selection algorithm, state→animation mapping, state lifetimes, reduced-motion behaviour, display sizing |
| `pets/frames.rs` | sprite index → rectangle arithmetic |
| `pets/asset_pack.rs` | where the spritesheet comes from, how it is validated |
| `chatwidget/turn_runtime.rs` | which agent lifecycle events set which pet state |
| `chatwidget/tool_requests.rs` | which approval/permission events set the waiting state |
| `chatwidget/pets.rs` | how the ambient pet is loaded and notified |

## 1. Geometry

`pets/catalog.rs:3-8`

```rust
pub(super) const DEFAULT_FRAME_WIDTH: u32 = 192;
pub(super) const DEFAULT_FRAME_HEIGHT: u32 = 208;
pub(super) const DEFAULT_FRAME_COLUMNS: u32 = 8;
pub(super) const DEFAULT_FRAME_ROWS: u32 = 9;
pub(super) const SPRITESHEET_WIDTH: u32 = DEFAULT_FRAME_WIDTH * DEFAULT_FRAME_COLUMNS;
pub(super) const SPRITESHEET_HEIGHT: u32 = DEFAULT_FRAME_HEIGHT * DEFAULT_FRAME_ROWS;
```

* Frame: **192 × 208** px
* Grid: **8 columns × 9 rows** ⇒ **72 frames**
* Sheet: **1536 × 1872** px

Sprite indices are **row-major** — `pets/frames.rs:29-45` iterates
`for row in 0..rows { for column in 0..columns { index = row * columns + column } }`
and slices at `x = column * frame_width`, `y = row * frame_height`.

So for sprite index `i`:

```
x = (i % 8) * 192
y = (i / 8) * 208
```

`SpriteSheet.swift` implements exactly this. Note that `frames.rs` writes 72
individual PNG files to disk; that is only because terminal image protocols
(sixel / iTerm2 / kitty) need a file path per frame. We render from the sheet
directly and keep the disk clean.

Sheet dimensions are validated on load — `asset_pack.rs:validate_cached_spritesheet`
rejects anything that is not exactly `SPRITESHEET_WIDTH × SPRITESHEET_HEIGHT`.
`SpriteSheet.load` does the same, which is what makes a wrong-sized user-supplied
sheet fail loudly instead of rendering garbage.

## 2. Seedy's identity

`pets/catalog.rs`, `BUILTIN_PETS`:

```rust
BuiltinPet {
    id: "seedy",
    display_name: "Seedy",
    description: "Small green shoots for new ideas",
    spritesheet_file: "seedy-spritesheet-v4.webp",
},
```

Eight built-ins exist: `codex`, `dewey`, `fireball`, `rocky`, `seedy`, `stacky`,
`bsod`, `null-signal`. They all share the geometry above and the animation table
below, so pointing this app at any of those sheets works — see
the Artwork section of the README.

## 3. Transparency and rendering

The sheet is a `.webp` with an alpha channel. Codex does nothing special with
transparency: it slices frames and hands them to a terminal image protocol.

There is **no scaling, cropping or padding of the artwork**. `ambient.rs:37,334-345`
only computes a display size:

```rust
const PET_TARGET_HEIGHT_PX: u16 = 75;
```

…then derives terminal rows/columns from that height with the frame's aspect
ratio (times `0.52` to account for character cell aspect). The full 192×208 frame
is always drawn, anchored to the bottom-right, above the composer
(`ambient.rs:221-249`, `chatwidget/pets.rs` `ambient_pet_draw`).

Nearest-neighbour is not something Codex chooses explicitly — the terminal image
protocol scales the PNG. For a desktop pet we must choose, and we choose
nearest-neighbour, because anything else destroys pixel art. `1×` in this app is
96 × 104 pt, which on a 2× Retina display is exactly 192 × 208 device pixels:
one sprite pixel per screen pixel.

**Reduced motion:** `ambient.rs:202-212` returns no delay when `animations_enabled`
is false, and the upstream test
`reduced_motion_uses_stable_first_frame_and_schedules_no_follow_up` asserts the
pet then shows frame 0 and schedules nothing. We honour macOS's
"Reduce motion" accessibility setting the same way.

## 4. The animation table

`pets/model.rs:484-582` builds the table. `idle` is hand-written
(`model.rs:584-596`), everything else comes from a helper.

### idle — row 0

```rust
frames: [(0, 1680), (1, 660), (2, 660), (3, 840), (4, 840), (5, 1920)]
loop_start: Some(0)
```

Six frames, explicit per-frame durations in milliseconds, loops forever from the
start. Total cycle 6.6 s. Note row 0 has 8 columns but only 6 are used.

### Everything else — `app_state_animation`

`model.rs:598-627`:

```rust
fn app_state_animation(
    row_index: usize,
    frame_count: usize,
    frame_duration_ms: u64,
    final_frame_duration_ms: u64,
) -> Animation {
    let primary_frames = (0..frame_count)
        .map(|column_index| AnimationFrame {
            sprite_index: row_index * DEFAULT_FRAME_COLUMNS as usize + column_index,
            duration: Duration::from_millis(if column_index == frame_count - 1 {
                final_frame_duration_ms
            } else {
                frame_duration_ms
            }),
        })
        .collect::<Vec<_>>();
    let primary_frame_count = primary_frames.len() * 3;
    let frames = primary_frames
        .iter().chain(primary_frames.iter()).chain(primary_frames.iter())
        .cloned()
        .chain(idle_animation().frames)
        .collect();
    Animation { frames, loop_start: Some(primary_frame_count), fallback: "idle".to_string() }
}
```

Two things matter here and both are easy to miss:

1. **The last frame of each track is held longer** than the others. That trailing
   beat is what makes the animations feel deliberate rather than looped.
2. **The emitted track is the primary row repeated three times, followed by the
   six idle frames**, with `loop_start` pointing at the *idle tail*. So upstream
   plays an action three times and then settles into idle forever — even though
   the state that triggered it may stay active for minutes. See §6.

The calls (`model.rs:486-577`):

| name | row | frames | frame ms | final ms |
|---|---|---|---|---|
| `idle` | 0 | 6 | (per-frame, see above) | — |
| `running-right` | 1 | 8 | 120 | 220 |
| `running-left` | 2 | 8 | 120 | 220 |
| `waving` | 3 | 4 | 140 | 280 |
| `jumping` | 4 | 5 | 140 | 280 |
| `failed` | 5 | 8 | 140 | 240 |
| `waiting` | 6 | 6 | 150 | 260 |
| `running` | 7 | 6 | 120 | 220 |
| `review` | 8 | 6 | 150 | 280 |
| `move_right` | 1 | 8 | 120 | 220 | *(alias of `running-right`)* |
| `move_left` | 2 | 8 | 120 | 220 | *(alias of `running-left`)* |
| `wave` | 3 | 4 | 140 | 280 | *(alias of `waving`)* |
| `bounce` | 4 | 5 | 140 | 280 | *(alias of `jumping`)* |
| `sad` | 5 | 8 | 140 | 240 | *(alias of `failed`)* |

Thirteen names, eight distinct tracks. The aliases exist because the table was
"ported from the Codex App avatar catalog" (`catalog.rs:1`) and both vocabularies
were kept. `assets/pet/animations.json` keeps the aliases so `hooklingctl bounce`
and `hooklingctl jump` both work.

Rows use 4–8 of their 8 columns; the unused tail columns of each row are simply
never referenced.

### Custom-pet defaults

For user-supplied `pet.json` manifests (`model.rs:410-428`) the defaults are
`fps = 8.0` (⇒ 125 ms per frame), `loop = true`, `fallback = "idle"`, and
`MAX_ANIMATION_FPS = 60`. Animations must be non-empty and every sprite index
must be `< frame_count` (`model.rs:395-408`, `454-478`), and every `fallback` must
name an animation that exists. We enforce the same rules when loading
`animations.json`.

## 5. The frame-selection algorithm

`ambient.rs:376-431`. This is the part worth reproducing precisely, because it is
what makes timing match.

```rust
fn current_animation_frame(animation: &Animation, elapsed: Duration) -> Option<AnimationFrameTick> {
    if animation.frames.len() <= 1 {
        return Some(AnimationFrameTick { sprite_index: animation.frames.first()?.sprite_index, delay: None });
    }
    let elapsed_nanos = elapsed.as_nanos();
    if let Some(loop_start) = animation.loop_start.filter(|idx| *idx < animation.frames.len()) {
        let total_nanos  = animation.total_duration().as_nanos();
        let prefix_nanos = animation.frames[..loop_start].iter().map(|f| f.duration.as_nanos()).sum::<u128>();
        let loop_nanos   = animation.frames[loop_start..].iter().map(|f| f.duration.as_nanos()).sum::<u128>();
        let effective_elapsed = if elapsed_nanos >= total_nanos && loop_nanos > 0 {
            prefix_nanos + elapsed_nanos.saturating_sub(prefix_nanos) % loop_nanos
        } else {
            elapsed_nanos
        };
        frame_at_elapsed(animation, effective_elapsed)
    } else if elapsed_nanos >= animation.total_duration().as_nanos() {
        Some(AnimationFrameTick { sprite_index: animation.frames.last()?.sprite_index, delay: None })
    } else {
        frame_at_elapsed(animation, elapsed_nanos)
    }
}
```

and the walk:

```rust
fn frame_at_elapsed(animation: &Animation, elapsed_nanos: u128) -> Option<AnimationFrameTick> {
    let mut remaining_elapsed = elapsed_nanos;
    for frame in &animation.frames {
        let frame_nanos = frame.duration.as_nanos().max(1);
        if remaining_elapsed < frame_nanos {
            return Some(AnimationFrameTick {
                sprite_index: frame.sprite_index,
                delay: Some(nanos_to_duration(frame_nanos - remaining_elapsed)),
            });
        }
        remaining_elapsed = remaining_elapsed.saturating_sub(frame_nanos);
    }
    Some(AnimationFrameTick { sprite_index: animation.frames.last()?.sprite_index, delay: None })
}
```

Properties worth calling out, all of which `AnimationPlayer.swift` preserves and
`AnimationPlayerTests.swift` asserts:

* Returns **both** the sprite to show and the delay until the next change, so the
  renderer schedules one timer per frame rather than polling. `ambient.rs:196-212`
  feeds that delay straight into `schedule_frame_in`.
* A `delay` of `None` means "this is terminal, schedule nothing" — a single-frame
  animation, or a non-looping animation that has finished. That is how the pet
  reaches genuinely zero CPU.
* A zero-duration frame is clamped to 1 ns, so a malformed manifest cannot cause
  an infinite loop.
* The wrap arithmetic is not `elapsed % total`; the prefix is played once and then
  only the suffix from `loop_start` repeats.

## 6. State → animation mapping

`ambient.rs:46-90` — there are only four states, and each expires:

```rust
const RUNNING_LIFETIME: Duration = Duration::from_secs(3 * 60);
const FAILED_LIFETIME:  Duration = Duration::from_secs(60 * 60);
const WAITING_LIFETIME: Duration = Duration::from_secs(24 * 60 * 60);
const REVIEW_LIFETIME:  Duration = Duration::from_secs(7 * 24 * 60 * 60);
```

| kind | animation | label | body | lifetime |
|---|---|---|---|---|
| `Running` | `running` | "Running" | "Thinking" | 3 min |
| `Waiting` | `waiting` | "Needs input" | "Needs input" | 24 h |
| `Review` | `review` | "Ready" | "Ready" | 7 days |
| `Failed` | `failed` | "Blocked" | "Blocked" | 1 h |

With no live notification, `current_animation` falls back to `"idle"`
(`ambient.rs:283-291`). Expiry is checked lazily on draw via
`visible_notification` / `is_expired` (`ambient.rs:108-109, 277`).

Who sets what:

| upstream call site | state |
|---|---|
| `turn_runtime.rs:98` — task started | `Running` |
| `turn_runtime.rs:192` — task complete | `Review` |
| `turn_runtime.rs:367` — `on_error` | `Failed` |
| `tool_requests.rs:287` — exec approval | `Waiting` |
| `tool_requests.rs:308` — apply-patch approval | `Waiting` |
| `tool_requests.rs:372,382` — approval request pushed | `Waiting` |
| `tool_requests.rs:395` — MCP server elicitation | `Waiting` |
| `tool_requests.rs:413` — request user input | `Waiting` |
| `tool_requests.rs:432` — request permissions | `Waiting` |

**`wave`, `jumping`, `running-left`, `running-right` are never played by the
ambient pet.** They exist in the catalog (the Codex app avatar uses them) but the
terminal pet only ever shows idle / running / waiting / review / failed. This app
uses them as one-shot transients, which is additive — it never replaces an
authentic mapping with an invented one.

## 7. Randomness and transitions

There is **none**. `grep -rn "rand" codex-rs/tui/src/pets/` returns nothing. The
displayed animation is a pure function of the current notification kind, and
there is no ambient idle-fidget picker, no random wander, no probability table.

Likewise there are **no transition rules** — no blending, no "must finish current
loop before switching". `set_notification` (`ambient.rs:178-181`) replaces the
notification and resets `animation_started_at`, so the new animation starts at
frame 0 immediately.

The only sequencing that exists is the one baked into the frame list by
`app_state_animation`: action ×3, then idle. We deliberately diverge from that
one behaviour — see below.

## 8. Where this project deliberately differs

Everything above is reproduced faithfully except one thing, which was a stated
requirement.

Upstream, a `Running` notification lives for up to 3 minutes but its *animation*
runs the 6-frame running cycle three times (≈2.4 s) and then loops idle. If Claude
works for 90 seconds, an upstream-faithful pet would look idle for 87 of them.

So `AnimationPlayer` supports three composition modes over the same authentic
data:

| mode | frame list | `loopStart` | used for |
|---|---|---|---|
| `codexTriple` | primary ×3 + idle tail | `count*3` | exact upstream parity — toggleable from the menu |
| `loopPrimary` | primary | `0` | **default** for persistent states |
| `once` | primary | `nil` (holds last frame, then hands back) | transients: wave, jump, failure reaction |

The artwork and the per-frame durations are identical in all three modes; only
the repeat policy differs. "Codex-faithful animation loops" in the menu bar
switches persistent states to `codexTriple` so the two can be compared directly.

The second difference is additive rather than divergent: upstream has four states,
this app has eight (`SLEEPING`, `IDLE`, `ATTENTIVE`, `WORKING`, `WAITING`,
`SUCCESS`, `FAILED`, `REVIEW`), because Claude Code exposes more lifecycle detail
than the four Codex notification kinds. The four upstream states map 1:1
(`WORKING`→`running`, `WAITING`→`waiting`, `REVIEW`→`review`, `FAILED`→`failed`)
and the extra four reuse existing artwork: `IDLE`/`ATTENTIVE` use `idle`,
`SLEEPING` freezes `idle` on frame 0, and `SUCCESS` is a `jumping` transient that
resolves to `REVIEW`. No artwork was invented.
