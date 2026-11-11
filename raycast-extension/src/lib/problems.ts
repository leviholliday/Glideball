import { confirmAlert, open, showToast, Toast } from "@raycast/api";
import { launchGlideball, Problem, send, WEBSITE } from "./glideball";

// What to tell someone when Glideball can't be controlled yet, and the one
// thing that helps. Used by every command: an alert for the ones without a
// window, an empty state for the ones with one.

export interface ProblemText {
  title: string;
  message: string;
  actionTitle: string;
  act: () => Promise<void>;
}

export const SWITCH_NAME = "Allow Raycast and scripts";
export const SWITCH_PATH = `Glideball › Settings › General › “${SWITCH_NAME}”`;

export async function showFailure(title: string, message?: string): Promise<void> {
  await showToast({ style: Toast.Style.Failure, title, message });
}

async function openSettingsToGeneral(): Promise<void> {
  try {
    await send({ command: "settings", tab: "general" });
  } catch {
    await showFailure(
      "Couldn't open Glideball's Settings",
      "This Glideball may be older than 2.10. Update it from Glideball's menu.",
    );
  }
}

export function problemText(problem: Problem): ProblemText {
  switch (problem) {
    case "not-installed":
      return {
        title: "Glideball isn't installed",
        message: `This extension controls the Glideball Mac app, which is free. You can get it at ${WEBSITE.replace("https://", "")}.`,
        actionTitle: "Open Glideball Website",
        act: () => open(WEBSITE),
      };
    case "not-running":
      return {
        title: "Glideball isn't running",
        message: "Open Glideball, then try again.",
        actionTitle: "Open Glideball",
        act: async () => {
          try {
            await launchGlideball();
          } catch {
            await showFailure("Couldn't open Glideball");
          }
        },
      };
    case "switch-off":
      return {
        title: "Glideball isn't listening to Raycast yet",
        message: `Turn on “${SWITCH_NAME}” in ${SWITCH_PATH}. It's off until you turn it on. If you can't find it, update Glideball: it needs version 2.10 or later.`,
        actionTitle: "Open Glideball Settings",
        act: openSettingsToGeneral,
      };
    case "unsupported":
      return {
        title: "Can't read Glideball's status",
        message:
          "Glideball's status file is in a format this extension doesn't know. Update the Glideball extension and Glideball, and try again.",
        actionTitle: "Open Glideball Website",
        act: () => open(WEBSITE),
      };
  }
}

/** For a command without a window: say what's wrong, and offer the fix. */
export async function showProblem(problem: Problem): Promise<void> {
  const text = problemText(problem);
  const confirmed = await confirmAlert({
    title: text.title,
    message: text.message,
    primaryAction: { title: text.actionTitle },
    dismissAction: { title: "Close" },
    rememberUserChoice: false,
  });
  if (confirmed) await text.act();
}
