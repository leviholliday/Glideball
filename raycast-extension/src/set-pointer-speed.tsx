import { Action, ActionPanel, Color, Icon, LaunchProps, List } from "@raycast/api";
import { useEffect, useState } from "react";
import { ProblemView } from "./components/ProblemView";
import { useGlideball } from "./components/useGlideball";
import { runControl } from "./lib/control";
import { parsePointerSpeed, POINTER_SPEED_RANGE, problemOf, speedText, statusOf } from "./lib/glideball";
import { showFailure } from "./lib/problems";

const PRESETS: { speed: number; note?: string }[] = [
  { speed: 1, note: "Slow" },
  { speed: 2 },
  { speed: 3, note: "The most System Settings allows" },
  { speed: 4, note: "Where Glideball starts" },
  { speed: 6 },
  { speed: 8 },
  { speed: 12, note: "Fast" },
  { speed: 20, note: "Very fast" },
];

const RANGE_TEXT = `${POINTER_SPEED_RANGE.min} to ${POINTER_SPEED_RANGE.max}`;

function setSpeed(speed: number) {
  return runControl({
    url: { command: "pointer-speed", value: speed },
    skip: (before) => (before.pointerSpeed === speed ? `Pointer speed is already ${speedText(speed)}` : undefined),
    confirmed: (after) => after.pointerSpeed === speed,
    success: (after) => {
      const setup = after?.activeAppSetup?.name;
      return setup
        ? `Pointer speed: ${speedText(speed)}. The ${setup} setup is in use and may have its own.`
        : `Pointer speed: ${speedText(speed)}`;
    },
    unconfirmed: "Asked Glideball to change the speed, but its status didn't change.",
  });
}

export default function Command(props: LaunchProps<{ arguments: Arguments.SetPointerSpeed }>) {
  const glideball = useGlideball();
  const [search, setSearch] = useState("");
  const problem = glideball && problemOf(glideball);
  const status = glideball && statusOf(glideball);

  // A speed typed into the command's argument is used straight away.
  const argument = props.arguments.value?.trim();
  const [argumentUsed, setArgumentUsed] = useState(false);
  useEffect(() => {
    if (!argument || argumentUsed || glideball === undefined) return;
    setArgumentUsed(true);
    if (problemOf(glideball)) return; // the list explains what's wrong
    const speed = parsePointerSpeed(argument);
    if (speed === undefined) {
      showFailure("That isn't a speed", `Use a number from ${RANGE_TEXT}, like 4 or 4.5.`);
    } else {
      setSpeed(speed);
    }
  }, [argument, argumentUsed, glideball]);

  const typed = parsePointerSpeed(search);
  const current = status?.pointerSpeed;

  const action = (speed: number) => (
    <ActionPanel>
      <Action title={`Set Speed to ${speedText(speed)}`} onAction={() => setSpeed(speed)} />
    </ActionPanel>
  );

  return (
    <List
      isLoading={glideball === undefined}
      filtering={false}
      onSearchTextChange={setSearch}
      searchBarPlaceholder={`Type a speed (${RANGE_TEXT}) or pick one`}
    >
      {problem ? (
        <ProblemView problem={problem} />
      ) : (
        <>
          {typed !== undefined && (
            <List.Section title="Typed">
              <List.Item
                icon={Icon.Pencil}
                title={`Set Speed to ${speedText(typed)}`}
                subtitle={String(typed) === search.trim() ? undefined : "Rounded to the nearest half"}
                actions={action(typed)}
              />
            </List.Section>
          )}
          <List.Section title="Presets" subtitle={current === undefined ? undefined : `Now ${speedText(current)}`}>
            {PRESETS.map(({ speed, note }) => {
              const isCurrent = current === speed;
              return (
                <List.Item
                  key={speed}
                  icon={isCurrent ? { source: Icon.CheckCircle, tintColor: Color.Green } : Icon.Circle}
                  title={speedText(speed)}
                  subtitle={note}
                  accessories={isCurrent ? [{ tag: { value: "Current", color: Color.Green } }] : []}
                  actions={action(speed)}
                />
              );
            })}
          </List.Section>
        </>
      )}
    </List>
  );
}
