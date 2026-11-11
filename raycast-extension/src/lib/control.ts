import { closeMainWindow, showHUD, showToast, Toast } from "@raycast/api";
import { GlideStatus, GlideURL, problemOf, readGlideball, send, statusOf, waitForStatus } from "./glideball";
import { showProblem } from "./problems";

// The shape of every command that changes something: check that Glideball is
// there and listening, say so if it isn't, otherwise send the URL, wait for
// status.json to show the change, and say what happened.

export interface Control {
  url: GlideURL;
  /** Return a message if there's nothing to do (already that way). */
  skip?: (before: GlideStatus) => string | undefined;
  /** Has status.json caught up? Leave out for things that don't show up there. */
  confirmed?: (after: GlideStatus, before: GlideStatus | undefined) => boolean;
  success: (after: GlideStatus | undefined) => string;
  /** Said when status.json didn't change in time. */
  unconfirmed: string;
  /** Keep Raycast's window open and use a toast, for commands that have a list on screen. */
  keepOpen?: boolean;
}

async function say(message: string, keepOpen: boolean | undefined, style = Toast.Style.Success): Promise<void> {
  if (keepOpen) await showToast({ style, title: message });
  else await showHUD(message);
}

export async function runControl(c: Control): Promise<void> {
  const g = await readGlideball();
  const problem = problemOf(g);
  if (problem) return showProblem(problem);

  const before = statusOf(g);
  const nothingToDo = before && c.skip?.(before);
  if (nothingToDo) return say(nothingToDo, c.keepOpen);

  if (!c.keepOpen) await closeMainWindow({ clearRootSearch: true });
  try {
    await send(c.url);
  } catch {
    return say("Couldn't reach Glideball. It may be older than 2.10.", c.keepOpen, Toast.Style.Failure);
  }

  const confirmed = c.confirmed;
  if (!confirmed) return say(c.success(undefined), c.keepOpen);
  const after = await waitForStatus((s) => confirmed(s, before));
  return after ? say(c.success(after), c.keepOpen) : say(c.unconfirmed, c.keepOpen, Toast.Style.Failure);
}
