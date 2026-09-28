# Licensing

Short version: **this project ships no Seedy artwork, because it has no right to.**
The code here is MIT. The artwork is OpenAI's and stays on your machine.

This document records what was actually checked, so the conclusion can be
re-examined rather than taken on trust.

## 1. What licence covers the Codex source?

**Apache License 2.0, Copyright 2025 OpenAI.**

`https://raw.githubusercontent.com/openai/codex/main/LICENSE` is the verbatim
Apache-2.0 text with the appendix filled in as `Copyright 2025 OpenAI`. The
repository README and `docs/license.md` both state Apache-2.0.

Two clauses matter here:

* **§6 Trademarks** — the licence "does not grant permission to use the trade
  names, trademarks, service marks, or product names of the Licensor, except as
  required for reasonable and customary use in describing the origin of the Work".
* The grant applies to **"the Work"**, defined as the work of authorship "made
  available under the License, as indicated by a copyright notice that is included
  in or attached to the work."

That second point is the load-bearing one, and it is why the artwork question is
not answered by "the repo is Apache-2.0".

## 2. Is the Seedy spritesheet in the repository?

**No.** Verified repo-wide, not just in the pets directory:

* `gh api "repos/openai/codex/git/trees/main?recursive=1"` returns 7057 entries
  with `truncated: false`. It contains **zero `.webp` files**.
* Nothing matching `spritesheet` exists outside the ten `.rs` files under
  `codex-rs/tui/src/pets/`.

So the artwork is not part of "the Work" that Apache-2.0 makes available.

## 3. Where does the official implementation get it?

`codex-rs/tui/src/pets/asset_pack.rs` downloads it at first use:

```rust
const PET_PACK_VERSION: &str = "v1";
const PET_PACK_DIR: &str = "cache/tui-pets";
const PET_CDN_BASE_URL: &str = "https://persistent.oaistatic.com/codex/pets/v1";
const PET_MAX_DOWNLOAD_BYTES: u64 = 4 * 1024 * 1024;
```

⇒ `https://persistent.oaistatic.com/codex/pets/v1/seedy-spritesheet-v4.webp`,
installed atomically into `$CODEX_HOME/cache/tui-pets/v1/assets/` after the
decoded dimensions are validated.

The module's own doc comments describe the intent, and the wording is significant:

> Unlike custom pets, built-in pets are not checked into the TUI package as local
> spritesheets. The TUI resolves them from the public Codex pets CDN on first
> use…
> — `asset_pack.rs`

> built-in pets are **versioned application assets** fetched on demand into a
> managed CODEX_HOME cache, while custom pets remain entirely **user-owned data**
> — `pets/mod.rs`

The exclusion from the repository is deliberate, and OpenAI classifies these
sprites as *its application assets* — explicitly not as user content.

### What the CDN actually returns

`curl -sI "https://persistent.oaistatic.com/codex/pets/v1/seedy-spritesheet-v4.webp"`:

```
HTTP/2 200
content-type: application/octet-stream
content-length: 914490
content-md5: fpFJ8oAXgED/HzwC6J7jIg==
last-modified: Mon, 04 May 2026 22:38:51 GMT
access-control-allow-origin: *
server: cloudflare
x-ms-blob-type: BlockBlob
```

Public, unauthenticated, ~893 KiB, Azure Blob Storage behind Cloudflare. No
`Cache-Control`, no `Content-Disposition`, and a generic content type.

Note what this is **not**: `access-control-allow-origin: *` is a browser security
mechanism, not a copyright licence. It says scripts may read the bytes
cross-origin. It says nothing about redistribution rights.

Also note the shape of the URL. `v1` in the path, `v4` in the filename, and raw
`x-ms-*` headers — this is internal plumbing, not a documented public API. It can
change or be locked down without notice.

## 4. Is there a NOTICE or asset-specific notice?

There is a root `NOTICE` file. In full:

```
OpenAI Codex
Copyright 2025 OpenAI

This project includes code derived from [Ratatui](https://github.com/ratatui/ratatui),
licensed under the MIT license.
Copyright (c) 2016-2022 Florian Dehau
Copyright (c) 2023-2025 The Ratatui Developers
```

**It says nothing about pets, sprites, artwork, or trademarks.** Beyond that:

* `docs/` contains no pets documentation at all.
* Grepping every file under `codex-rs/tui/src/pets/` for
  `licen|copyright|trademark|redistribut|personal use|terms` returns **zero
  matches** — no licence header, no attribution requirement, no redistribution
  statement.
* Probing the CDN for adjacent terms — `LICENSE`, `LICENSE.txt`, `NOTICE`,
  `README.txt`, `license.json` in that path, plus a directory listing — returns
  **404 for all of them**. `robots.txt` returns an Azure `BlobNotFound`.
* `gh search issues --repo openai/codex "pets license"` returns `[]`. There is no
  maintainer statement to rely on.

So: no licence is granted anywhere, and none is refused anywhere. Silence.

## 5. OpenAI's general terms

There are no `oaistatic.com`-specific terms. The general documents do apply and
are restrictive:

* **Terms of Use**, "Our IP rights": *"We and our affiliates own all rights,
  title, and interest in and to the Services. You may only use our name and logo
  in accordance with our Brand Guidelines."* The user-ownership provisions cover
  model **Output**; hand-authored artwork shipped as part of the product is not
  Output.
* **Brand Guidelines** state they cover *"our trademarks **and copyrighted
  work**"*, and define "Marks" to include *"our names, logos, **icons, and design
  elements**"*. Permission is *"non-exclusive and non-transferrable (you cannot
  give it to others)"* and *"We may terminate permission … at any time."*
* **App Developer Terms** §4.1 grants a licence to use OpenAI Assets *"solely to
  promote your Apps"* and adds *"You may not otherwise use OpenAI Assets without
  our prior written consent."* (Caveat: those terms govern apps inside OpenAI's
  own ecosystem, so they are cited as evidence of posture, not as a contract this
  project has entered.)

The recurring "non-transferable, non-sublicensable" language is the decisive
pattern: even the most generous reading of OpenAI's permissions does not include
the right to pass permission downstream — which is exactly what shipping the file
in a public repository would require.

## 6. Conclusion

| Option | Verdict |
|---|---|
| **(a)** commit `seedy-spritesheet-v4.webp` to this repository | **Not permitted.** Apache-2.0 does not reach a file deliberately kept out of the Work; no other grant exists; copyright is default-deny. Absence of a prohibition is not permission. |
| **(b)** have this app download it from the CDN at runtime | **Unclear.** Not plainly infringing — the endpoint is public and the app copies to the user's own machine, exactly as Codex does — but undocumented, unsanctioned, uses OpenAI's bandwidth for a non-Codex product, and revocable at any time. |
| **(c)** read a copy already on the user's machine | **Safest.** No distribution by this project, no bytes shipped, no requests to OpenAI infrastructure. The user already lawfully has the file, placed there by OpenAI's own software. |

### Therefore

1. **`assets/pet/*.webp` is gitignored.** The artwork is never committed. This
   is not a policy that can be forgotten — `.gitignore` enforces it.
2. **(c) is the default path.** `scripts/fetch-pet.sh` looks in
   `$CODEX_HOME/cache/tui-pets/v1/assets/` (default `~/.codex`) and links what it
   finds. If Codex is installed but you have never chosen a pet, run `codex`, then
   `/pets`, and pick Seedy — Codex downloads it into your own cache under whatever
   terms you accepted, and the script will then find it.
3. **(b) requires an explicit flag.** `scripts/fetch-pet.sh --from-cdn` prints
   the caveat above and then fetches from the same URL Codex uses. It is never
   the default and never implicit.
4. **The renderer is asset-agnostic.** It takes a path to any 8×9 grid of 192×208
   frames. Any of the eight Codex pets works, as does your own artwork.
5. **No replacement artwork is invented.** With no sheet present the app runs but
   shows nothing, and the menu offers "How to get pet artwork…".

### Attribution in this project

* Code in this repository: **MIT** (see `LICENSE`).
* Behaviour re-implemented from Codex — the animation data table and the
  frame-selection algorithm — is credited in `NOTICE` with the upstream
  Apache-2.0 attribution and the specific files involved. No Codex source was
  copied verbatim; see `docs/codex-pet-analysis.md`.
* Seedy artwork: **OpenAI's, not distributed here, no rights granted.**
* Demo media in `docs/media/` shows Jiji, a community pet by yena from
  codex-pets.net, credited in the README and `NOTICE`. It is used only in the
  README's images and is not bundled with the app. No OpenAI or Anthropic
  character is used in any promotional image.
* No OpenAI or Anthropic logo is used as this application's branding. The menu
  bar uses an SF Symbol.
* "Codex", "Seedy", "OpenAI", "Claude", "Claude Code" are used nominatively to
  describe interoperability. This project is **not** affiliated with, endorsed
  by, or sponsored by either company.

### Honest statement of uncertainty

No OpenAI statement addresses the pet assets specifically — not in the repo, not
on the CDN, not in the policies. §5 applies OpenAI's general IP and brand terms to
a case those terms do not name. It is entirely possible OpenAI would not object to
any of these uses; nothing here predicts enforcement. But "they probably would not
mind" is not a licence, which is why option (a) is off the table and option (b)
needs a deliberate flag.

If you want certainty for (a) or (b), OpenAI lists `partnercomms@openai.com` for
asset permission requests and `legal@openai.com` for legal enquiries.
