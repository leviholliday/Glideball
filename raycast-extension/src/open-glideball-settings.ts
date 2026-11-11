import { closeMainWindow, showHUD } from "@raycast/api";
import { isInstalled, send } from "./lib/glideball";
import { showProblem } from "./lib/problems";

// Opening Settings works with "Allow Raycast and scripts" off, so unlike the
// other commands this only needs Glideball to be installed.
export default async function Command() {
  if (!(await isInstalled())) return showProblem("not-installed");
  await closeMainWindow({ clearRootSearch: true });
  try {
    await send({ command: "settings" });
  } catch {
    await showHUD("Couldn't reach Glideball. It may be older than 2.10.");
  }
}
