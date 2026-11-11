import { runControl } from "./lib/control";

export default async function Command() {
  await runControl({
    url: { command: "precision", state: "toggle" },
    // Glideball ignores Precision while it's paused.
    skip: (before) => (before.paused ? "Glideball is paused, so Precision can't change. Resume it first." : undefined),
    confirmed: (after, before) => before === undefined || after.modes.precision !== before.modes.precision,
    success: (after) =>
      after ? `Precision mode ${after.modes.precision ? "on" : "off"}` : "Sent the Precision toggle to Glideball",
    unconfirmed: "Precision didn't change. It needs a connected trackball.",
  });
}
