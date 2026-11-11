import { runControl } from "./lib/control";

export default async function Command() {
  await runControl({
    url: { command: "resume" },
    skip: (before) => (before.paused ? undefined : "Glideball is already running"),
    confirmed: (after) => !after.paused,
    success: () => "Glideball resumed",
    unconfirmed: "Asked Glideball to resume, but its status didn't change. Check Glideball's menu.",
  });
}
