# Glideball handoff

A brief for whoever (person or Claude session) picks this up next. Keep it current.

## What this is

Glideball is a free, open-source Mac app that customizes Kensington trackballs (built around the
wired Expert Mouse) and replaces KensingtonWorks. One developer: Levi Holliday. Contact:
glideball@proton.me. Website: https://glideball.netlify.app. Repo: github.com/leviholliday/glideball.

The plan is to support more trackballs later (Levi owns an ELECOM HUGE), so don't write copy that
says "Expert Mouse only" in titles; say "Kensington" for now.

## Order of work (agreed 2026-11-10)

1. Bug fixes on the Mac app, released to beta testers first.
2. Website, search and README (one publish, with Levi present).
3. Features: opt-in analytics with an admin Usage page, sync that doesn't need iCloud, split Beta
   switch, donation link (Levi's Venmo is on his Gravatar profile).
4. Design: new "Orb" icon (offered as "try the new style?"), app look.
5. Only when the Mac app is in a good place: Windows and Linux (Ubuntu and Debian, including a
   4 GB Raspberry Pi). The current ports are frozen previews.

The full plan and the audit behind it are in `.claude/plans/` (git-ignored).

## Rules for Claude sessions

- Beta releases (`scripts/ship.sh X.Y-beta.N "notes" --beta`) may go out without Levi.
- Website publishes: OK by default; Levi says when he doesn't want one. Full (non-beta) releases: ask first.
- Public posts, emails, GitHub description changes: ask first.
- If blocked for about ten minutes, message Levi on ntfy and stop.
- Use subagents on the cheapest model that can do the job (Sonnet for mechanical work, Opus for
  hard code). One CI fix per push; never let agents poll CI.
- Wording: Levi is a single student developer. Follow `.claude/plans/voice-guide.md` (his voice guide) for every word the public sees.

## Build and release

- `swift build -c release` to compile. `./build.sh` also replaces /Applications/Glideball.app
  and relaunches it.
- Checks before shipping: `scripts/scroll-sim/run.sh`, `scripts/backup-sim/run.sh`,
  `python3 scripts/l10n/check.py` (8 translations must be complete).
- Signing: the self-signed "Glide Local Signing" certificate. Installed copies only accept
  updates signed with it. Levi has a .p12 backup.
- The bundle ID, executable and data folders are still named "Glide" on purpose.

## Hard safety rules for the app

- Never seize the trackball; never write `HIDPointerResolution`.
- The primary button always stays a left click.
- Pause, quit and unplug must undo every mode and held key.
- Other mice and the trackpad are never touched.

## Known traps

- The site's CSP drops inline `style=` and `on*=` attributes.
- Netlify snippets (analytics consent, privacy notice) live in the Netlify dashboard, not the repo.
- Always deploy with `scripts/deploy-site.sh` (it passes the site ID).
- The Mac's disk is nearly full; a build needs a few GB free.
