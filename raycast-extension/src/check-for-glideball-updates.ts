import { runControl } from "./lib/control";

export default async function Command() {
  await runControl({
    url: { command: "check-for-updates" },
    success: () => "Checking for Glideball updates",
    unconfirmed: "",
  });
}
