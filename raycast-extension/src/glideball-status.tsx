import { Action, ActionPanel, closeMainWindow, Color, Icon, List } from "@raycast/api";
import { ProblemView } from "./components/ProblemView";
import { useGlideball } from "./components/useGlideball";
import { runControl } from "./lib/control";
import {
  distanceText,
  GlideStatus,
  GlideURL,
  problemOf,
  scrollModeTitle,
  send,
  speedText,
  statusOf,
} from "./lib/glideball";
import { showFailure } from "./lib/problems";

const TABS: { title: string; tab: "overview" | "pointer" | "scrolling" | "buttons" | "apps" | "sync" }[] = [
  { title: "Overview", tab: "overview" },
  { title: "Pointer", tab: "pointer" },
  { title: "Scrolling", tab: "scrolling" },
  { title: "Buttons", tab: "buttons" },
  { title: "Apps", tab: "apps" },
  { title: "Sync", tab: "sync" },
];

async function openInGlideball(url: GlideURL) {
  await closeMainWindow({ clearRootSearch: true });
  try {
    await send(url);
  } catch {
    await showFailure("Couldn't reach Glideball", "It may be older than 2.10.");
  }
}

function activeModes(s: GlideStatus): string {
  const on = [
    s.modes.precision && "Precision",
    s.modes.ballScroll && "Scroll with ball",
    s.modes.dragLock && "Drag lock",
  ];
  const names = on.filter(Boolean);
  return names.length > 0 ? names.join(", ") : "None";
}

function Row(props: { title: string; value: string; icon: List.Item.Props["icon"]; actions?: React.ReactNode }) {
  return (
    <List.Item
      icon={props.icon}
      title={props.title}
      accessories={[{ text: props.value }]}
      actions={
        <ActionPanel>
          {props.actions}
          <Action.CopyToClipboard title="Copy Value" content={props.value} />
        </ActionPanel>
      }
    />
  );
}

export default function Command() {
  // status.json changes about once a second at most; today's numbers every 5 seconds.
  const glideball = useGlideball(3000);
  const problem = glideball && problemOf(glideball);
  const status = glideball && statusOf(glideball);

  const pauseToggle = status && (
    <Action
      title={status.paused ? "Resume Glideball" : "Pause Glideball"}
      icon={status.paused ? Icon.Play : Icon.Pause}
      onAction={() =>
        runControl({
          url: { command: status.paused ? "resume" : "pause" },
          confirmed: (after) => after.paused !== status.paused,
          success: (after) => (after?.paused ? "Glideball paused" : "Glideball resumed"),
          unconfirmed: "Asked Glideball, but its status didn't change.",
          keepOpen: true,
        })
      }
    />
  );

  const openActions = (
    <>
      <Action title="Open Glideball" icon={Icon.AppWindow} onAction={() => openInGlideball({ command: "open" })} />
      <ActionPanel.Submenu title="Open Tab…" icon={Icon.Window}>
        {TABS.map(({ title, tab }) => (
          <Action key={tab} title={title} onAction={() => openInGlideball({ command: "open", tab })} />
        ))}
      </ActionPanel.Submenu>
      <Action
        title="Open Glideball Settings"
        icon={Icon.Gear}
        onAction={() => openInGlideball({ command: "settings" })}
      />
    </>
  );

  return (
    <List isLoading={glideball === undefined} navigationTitle="Glideball Status">
      {problem || glideball?.kind === "unsupported" ? (
        <ProblemView problem={problem ?? "unsupported"} />
      ) : status ? (
        <>
          <List.Section title="Glideball">
            <Row
              title="State"
              value={status.paused ? "Paused" : "Running"}
              icon={{
                source: status.paused ? Icon.PauseFilled : Icon.CheckCircle,
                tintColor: status.paused ? Color.Orange : Color.Green,
              }}
              actions={
                <>
                  {pauseToggle}
                  {openActions}
                </>
              }
            />
            <Row
              title="Trackball"
              value={status.trackballs.length > 0 ? status.trackballs.join(", ") : "Not connected"}
              icon={Icon.Circle}
              actions={openActions}
            />
            <Row title="Version" value={status.appVersion || "Unknown"} icon={Icon.Info} actions={openActions} />
          </List.Section>
          <List.Section title="Settings">
            <Row
              title="Scroll Mode"
              value={scrollModeTitle(status.scrollMode)}
              icon={Icon.ArrowsContract}
              actions={
                <Action
                  title="Open Scrolling Tab"
                  onAction={() => openInGlideball({ command: "open", tab: "scrolling" })}
                />
              }
            />
            <Row
              title="Pointer Speed"
              value={speedText(status.pointerSpeed)}
              icon={Icon.Gauge}
              actions={
                <Action
                  title="Open Pointer Tab"
                  onAction={() => openInGlideball({ command: "open", tab: "pointer" })}
                />
              }
            />
            <Row title="Modes On" value={activeModes(status)} icon={Icon.Switch} actions={openActions} />
            <Row
              title="App Setup"
              value={
                status.activeAppSetup
                  ? `${status.activeAppSetup.name}${status.activeAppSetup.pinned ? " (chosen)" : ""}`
                  : "Main setup"
              }
              icon={Icon.AppWindowGrid2x2}
              actions={
                <Action title="Open Apps Tab" onAction={() => openInGlideball({ command: "open", tab: "apps" })} />
              }
            />
          </List.Section>
          <List.Section title="Today">
            <Row
              title="Clicks"
              value={status.today.clicks.toLocaleString("en-US")}
              icon={Icon.Mouse}
              actions={openActions}
            />
            <Row
              title="Ball Distance"
              value={distanceText(status.today.ballMeters)}
              icon={Icon.Ruler}
              actions={openActions}
            />
            <Row
              title="Scroll Distance"
              value={distanceText(status.today.scrollMeters)}
              icon={Icon.ArrowDown}
              actions={openActions}
            />
          </List.Section>
        </>
      ) : null}
    </List>
  );
}
