# Glideball

Control [Glideball](https://glideball.netlify.app) from Raycast. Glideball is a free, open-source Mac app for Kensington trackballs: a faster pointer, a scroll ring that feels right, and buttons that do what you want. I'm Levi, a student, and I make it on my own. This extension lets you pause it, switch the scroll feel or change the pointer speed without opening its window.

## What you need

- The Glideball app, **version 2.10 or later**. It's free: [glideball.netlify.app](https://glideball.netlify.app).
- One switch turned on in Glideball: **Settings › General › "Allow Raycast and scripts"**. It's off until you turn it on, so nothing outside the app can control Glideball unless you say so. You can turn it off again any time.

If either is missing, each command tells you what's wrong and offers a button that helps (open the website, open Glideball, or open Glideball's Settings).

## Commands

- **Toggle Glideball** pauses Glideball if it's running and resumes it if it's paused. While it's paused, your trackball is an ordinary mouse.
- **Pause Glideball** and **Resume Glideball** do just one of those, so a hotkey can't get out of step.
- **Toggle Precision Mode** switches Precision on or off. It slows the pointer for fine work, and does nothing while Glideball is paused.
- **Set Scroll Mode** lists Native, Flywheel and Follow, with the current one marked.
- **Set Pointer Speed** lists a few speeds with the current one marked. You can also type any speed from 0.5 to 80 in the search field, or give it as the command's argument. Speeds are rounded to the nearest 0.5, like Glideball's own slider.
- **Glideball Status** shows whether Glideball is running or paused, which trackball it sees, the scroll mode, pointer speed, which modes are on, and today's clicks, ball distance and scroll distance. Its actions open Glideball's tabs.
- **Open Glideball Settings** opens Glideball's Settings window. This one works even with the switch off.
- **Check for Glideball Updates** opens Glideball's update window and checks.

The scroll mode and pointer speed are your main setup's. If an app setup is active (Safari with its own speed, say), it can use its own values, and the confirmation says so.

## How it works

Changes are `glideball://` links, opened in the background with `open -g`, so Glideball doesn't jump in front of what you're doing. What Glideball is doing is read from one small file, `~/Library/Application Support/Glide/status.json`, which exists only while the switch is on. The extension reads that file and nothing else. It makes no network requests, has no analytics and stores nothing.

The links Glideball accepts are the same ones you can use from a script or Shortcuts. The full list is in [docs/DEVELOPING.md](https://github.com/leviholliday/glideball/blob/main/docs/DEVELOPING.md#controlling-glideball-from-other-apps).

## If something doesn't work

- **"Glideball isn't listening to Raycast yet":** turn on "Allow Raycast and scripts" in Glideball › Settings › General. If you can't find it, update Glideball.
- **"Glideball isn't running":** open it and try again.
- **A command says it couldn't reach Glideball:** your Glideball is probably older than 2.10.
- **The confirmation says the status didn't change:** Glideball got the request but didn't change anything. Precision, for instance, needs a connected trackball.

Questions or ideas: [glideball.netlify.app/feedback](https://glideball.netlify.app/feedback/) or the [GitHub issues](https://github.com/leviholliday/glideball/issues). Let me know what you think.
