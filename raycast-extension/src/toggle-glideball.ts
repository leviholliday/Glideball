import { runControl } from "./lib/control";

export default async function Command() {
  await runControl({
    url: { command: "toggle" },
    // Pausing and resuming are a flip: it worked if the file now says the opposite of before.
    confirmed: (after, before) => before === undefined || after.paused !== before.paused,
    success: (after) =>
      after ? (after.paused ? "Glideball paused" : "Glideball resumed") : "Sent the toggle to Glideball",
    unconfirmed: "Sent the toggle, but Glideball's status didn't change. Check Glideball's menu.",
  });
}
