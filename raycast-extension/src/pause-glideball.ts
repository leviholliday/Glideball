import { runControl } from "./lib/control";

export default async function Command() {
  await runControl({
    url: { command: "pause" },
    skip: (before) => (before.paused ? "Glideball is already paused" : undefined),
    confirmed: (after) => after.paused,
    success: () => "Glideball paused",
    unconfirmed: "Asked Glideball to pause, but its status didn't change. Check Glideball's menu.",
  });
}
