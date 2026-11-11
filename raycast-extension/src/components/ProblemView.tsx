import { Action, ActionPanel, Icon, List } from "@raycast/api";
import { Problem } from "../lib/glideball";
import { problemText } from "../lib/problems";

/** The empty state for a list command when Glideball can't be controlled yet. */
export function ProblemView({ problem }: { problem: Problem }) {
  const text = problemText(problem);
  return (
    <List.EmptyView
      icon={Icon.ExclamationMark}
      title={text.title}
      description={text.message}
      actions={
        <ActionPanel>
          <Action title={text.actionTitle} onAction={text.act} />
        </ActionPanel>
      }
    />
  );
}
