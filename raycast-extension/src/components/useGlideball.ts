import { useEffect, useState } from "react";
import { Glideball, readGlideball } from "../lib/glideball";

/** Where Glideball stands, undefined until the first look. Looks again every `pollMs` if given. */
export function useGlideball(pollMs?: number): Glideball | undefined {
  const [state, setState] = useState<Glideball>();

  useEffect(() => {
    let alive = true;
    const look = async () => {
      const next = await readGlideball();
      if (alive) setState(next);
    };
    look();
    const timer = pollMs ? setInterval(look, pollMs) : undefined;
    return () => {
      alive = false;
      if (timer) clearInterval(timer);
    };
  }, [pollMs]);

  return state;
}
