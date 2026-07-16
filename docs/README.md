# docs/ — maintainer notes

This folder is the GitHub Pages site. It is **not** shipped with the app and is
excluded from the built site itself (see `_config.yml`).

`index.html` is one self-contained file: inline CSS, no JavaScript, no web fonts,
no external requests of any kind. That is deliberate — it is what makes the page
fast by construction, and it means the only things that can break it are the four
missing screenshots listed below.

---

## 1. What is NOT done yet — do these in order

### Step 1 — Add the four screenshots (blocking; do this first)

The page currently renders **styled placeholders**, not broken images. That is
intentional and safe to deploy, but the whole pitch of this project is a visual
claim ("it looks exactly like the Windows Task Manager"), and text cannot make
that claim. Until these exist, the page is not launch-ready.

Each placeholder in `index.html` has a `TODO(maintainer)` comment directly above
it saying exactly what to capture. All four are **1600×1000**, dark mode:

| File | Capture |
|:--|:--|
| `screenshot-processes.png` | Processes tab, sorted by CPU desc, heatmap showing yellow/orange/red cells, sidebar expanded. **This is the hero shot.** |
| `screenshot-performance.png` | Performance tab, CPU pane, graph mid-scroll with real activity (run a build first so the line isn't flat) |
| `screenshot-details.png` | Details tab with the right-click menu open over a row (End task / End process tree / Suspend / Resume) |
| `screenshot-startup.png` | Startup apps tab with real login items listed |

To swap one in, replace the `<div class="ph">…</div>` with the `<img>` tag written
out in the comment above it. The placeholder reserves the **same 16:10 box** as the
image, so swapping causes **zero layout shift** — do not drop the `width`/`height`
attributes.

### Step 2 — Ship a release, then flip the CTA

Right now the hero button says **"Star to follow development"** because there is no
published release. Do not change this until a signed, notarised DMG actually exists
at the URL — a Download button that 404s costs more trust than it earns.

There is a `TaskManager.dmg` in the repo root, but it is **local and unsigned**. It
is not a release.

When the first release is published, follow the comment in the `<div class="cta">`
block: swap the button for the `releases/latest/download/TaskManager.dmg` permalink
(it always resolves to the newest release, so the page never needs editing again per
release) and delete the `<p class="note">` that says "No release yet".

### Step 3 — Enable GitHub Pages

Repo **Settings → Pages → Source: "Deploy from a branch" → Branch: `main`, Folder:
`/docs` → Save.** First build takes ~1 minute. It will publish at:

```
https://yatindma.github.io/task-manager-for-mac/
```

⚠️ **If that is not your final URL, it is hardcoded in five places** — see §2 below.

### Step 4 — Set the repo About + topics

Per GitHub's own docs: when you search GitHub without an `in:` qualifier, **only the
repo name, description, and topics are searched** — *not* the README. Those three
fields are your entire default GitHub search surface, which makes this the highest-
leverage, lowest-cost item on this list.

**About description** (front-load the terms people actually type):

> A pixel-exact Windows 11 Task Manager for macOS. Native Swift 6 + SwiftUI, zero dependencies.

**Website field**: the Pages URL from step 3.

**Topics** (max 20; lowercase letters/numbers/hyphens only; ≤50 chars each). All
nouns, no adjectives:

```
macos  task-manager  windows-11  swift  swiftui  system-monitor
activity-monitor  cpu  memory  processes  launchd  performance
native  macos-app
```

### Step 5 — Set the social preview image

**Settings → General → Social preview → Upload.** Use `docs/og-image.png` (already
here, 2400×1260). This controls how the repo link renders on HN, Reddit, X and Slack.
Do it for rendering control — there is no evidence it earns stars by itself.

### Step 6 — Submit to Google Search Console

1. <https://search.google.com/search-console> → Add property → **URL prefix** → the Pages URL.
2. Verify. **HTML file upload will not work** — Jekyll may not serve the token file
   reliably. Use the **HTML tag** method: paste the `<meta name="google-site-verification" …>`
   into `<head>` in `index.html`, deploy, verify, then you may remove it.
3. **Sitemaps** → submit `sitemap.xml`.
4. **URL Inspection** → paste the URL → **Request Indexing**.

Set expectations honestly: Request Indexing is a *request*, not a command. Indexing
typically takes hours to days and is **not guaranteed at all**. A brand-new page with
no backlinks will not rank for a head term like "task manager mac" — that is Apple's
and the tech press's. Realistic targets are long-tail: *"windows task manager for
mac"*, *"activity monitor alternative windows-like"*, *"task manager mac ctrl shift
esc"*. Assume GitHub + HN/Reddit deliver essentially all of your first-year traffic;
SEO is a 6–18 month compounding play.

**Do not bother with IndexNow** for Google — Bing supports it fully, Google's adoption
is partial at best.

### Step 7 — Promote `limitations.md` to a real HTML page (recommended)

`docs/limitations.md` currently has **no Jekyll front matter**, so Pages serves it as
raw text rather than rendering it. For that reason the page links to the
GitHub-rendered copy instead, and its `sitemap.xml` entry is commented out.

This is worth fixing properly, because that document is plausibly your single most
valuable SEO/GEO asset: nobody has written the definitive "what macOS does and does
not expose about process resource usage" page. It answers questions that have nothing
to do with your app, which is exactly the kind of page that earns links and gets
quoted by AI assistants — and it exists *because* you were honest.

To fix: add front matter to `docs/limitations.md`

```yaml
---
title: What macOS does and doesn't expose about process resource usage
description: The real constraints behind per-process GPU, root-owned processes, handles, and startup impact on macOS.
---
```

then in `index.html` change the limitations link `href` to `limitations.html`, and
uncomment the `<url>` block in `sitemap.xml`. Doing the last two **before** the first
creates a 404 in your sitemap — order matters.

---

## 2. Hardcoded URLs — check these if the repo moves

The placeholder tokens were resolved to `yatindma/task-manager-for-mac` (matching the
root `README.md`). **If the final repo owner or name differs, these must all change:**

| Token that was resolved | Value now | Where |
|:--|:--|:--|
| Site URL | `https://yatindma.github.io/task-manager-for-mac/` | `index.html` (canonical, `og:url`, JSON-LD `url`, og/twitter image), `robots.txt`, `sitemap.xml` |
| Repo URL | `https://github.com/yatindma/task-manager-for-mac` | `index.html` — nav, hero CTA, footer, clone command, JSON-LD `codeRepository` |
| Licence URL | `https://github.com/yatindma/task-manager-for-mac/blob/main/LICENSE` | `index.html` — both JSON-LD blocks |
| Author | `Yatin Arora` | `index.html` — `SoftwareSourceCode.author` |

One command to find every one of them:

```bash
grep -rn "yatindma" docs/
```

⚠️ **`LICENSE` does not exist in the repo root yet.** The root `README.md` claims MIT
and the JSON-LD links to a `LICENSE` file. Until you add one, both are pointing at a
404 and the "free and open source" claim is unbacked. Add the file, or change the
claim.

---

## 3. Things that are deliberate — please don't "fix" them

- **No `aggregateRating` in the JSON-LD.** Google's `SoftwareApplication` rich result
  requires `aggregateRating` *or* `review`. There are no users and no reviews, so
  there is no rating. Inventing one violates Google's structured data policy and is
  dishonest. **Expect no rich result until real reviews exist.** The schema is still
  worth shipping for entity comprehension.
- **No `FAQPage` schema.** Google's own docs: the FAQ rich result was retired for
  general sites on **7 May 2026** and now appears only for well-known government and
  health sites. Adding it would produce nothing. The FAQ section itself stays — it is
  there for humans and for AI-answer citation, which is why the answers are short,
  self-contained and quotable, with the real numbers (116 of ~620) in them.
- **No `BreadcrumbList`.** A one-page site has no hierarchy to describe.
- **No Download button.** See step 2.
- **The limitations section is not spun as features.** Please keep it that way. A
  visitor who learns about the GPU column after installing feels lied to; one who
  reads it upfront trusts the rest of the page.
- **The demo table is CSS, not a screenshot.** It uses the real heat stops from
  `WinTheme.heat()`. Its caption says it is an illustration and not live data —
  keep that caption.
- **No `style.css`.** Inlining is what keeps this a single request. Don't split it
  out unless it genuinely gets unmaintainable.

---

## 4. Colours

Every colour in `index.html` is lifted from
`Sources/TaskManager/Theme/WinTheme.swift`, which is the source of truth — light
values in `:root`, dark values in the `prefers-color-scheme: dark` block, matching
`WinTheme.Duo`. If the app's palette changes, update both.

---

## 5. Before you post to HN or Reddit — read this

The evidence on launches is that they are a **one-shot ~48-hour step function**: for
a median successful Show HN, roughly 92% of the stars you will ever get from it
arrive inside 48 hours, and days 8–30 contribute approximately zero. **It fires once.**

That is not a reason to rush. It is the reason to be *completely finished* first:

- [ ] Screenshots in (step 1)
- [ ] Signed, notarised DMG published (step 2)
- [ ] `LICENSE` file exists (§2)
- [ ] Root `README.md` stands alone — most visitors never see this site
- [ ] About + topics set (step 4)
- [ ] Social preview set (step 5)

On timing: the 48-hour window is well-supported. The commonly-repeated "post Monday
00:00 UTC" is a single blog analysis and timing effects are exactly where p-hacking
lives — treat it as folklore, not a plan.

On Reddit: honest, non-promotional participation in r/MacOS, r/apple and r/swift is
plausibly worth more than any on-page schema here, partly because Reddit is
disproportionately cited by AI assistants. It is also the easiest channel to get
wrong — it only works as genuine participation, and it backfires as marketing.
