import { Action, ActionPanel, Color, Icon, List } from "@raycast/api";
import { ProblemView } from "./components/ProblemView";
import { useGlideball } from "./components/useGlideball";
import { runControl } from "./lib/control";
import { problemOf, SCROLL_MODES, ScrollMode, scrollModeTitle, statusOf } from "./lib/glideball";

export default function Command() {
  const glideball = useGlideball();
  const problem = glideball && problemOf(glideball);
  const status = glideball && statusOf(glideball);

  const choose = (id: ScrollMode) =>
    runControl({
      url: { command: "scroll-mode", mode: id },
      skip: (before) => (before.scrollMode === id ? `Scroll mode is already ${scrollModeTitle(id)}` : undefined),
      confirmed: (after) => after.scrollMode === id,
      success: (after) => {
        const setup = after?.activeAppSetup?.name;
        return setup
          ? `Scroll mode: ${scrollModeTitle(id)}. The ${setup} setup is in use and may have its own.`
          : `Scroll mode: ${scrollModeTitle(id)}`;
      },
      unconfirmed: "Asked Glideball to change the scroll mode, but its status didn't change.",
    });

  return (
    <List isLoading={glideball === undefined} searchBarPlaceholder="Pick a scroll mode">
      {problem ? (
        <ProblemView problem={problem} />
      ) : (
        SCROLL_MODES.map((mode) => {
          const current = status?.scrollMode === mode.id;
          return (
            <List.Item
              key={mode.id}
              icon={current ? { source: Icon.CheckCircle, tintColor: Color.Green } : Icon.Circle}
              title={mode.title}
              subtitle={mode.description}
              accessories={current ? [{ tag: { value: "Current", color: Color.Green } }] : []}
              actions={
                <ActionPanel>
                  <Action title={`Use ${mode.title}`} onAction={() => choose(mode.id)} />
                </ActionPanel>
              }
            />
          );
        })
      )}
    </List>
  );
}
