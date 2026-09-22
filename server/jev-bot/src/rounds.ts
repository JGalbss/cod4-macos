/** What happened in earlier rounds of an objective match, so Jev can vary its plan instead of repeating it. */
export interface RoundRecord {
  readonly number: number;
  readonly sites: readonly string[];
  readonly planted: boolean;
  readonly won: boolean | undefined;
}

export interface RoundEndEvent {
  readonly planted: boolean;
  readonly team: string;
  readonly scores: Readonly<Record<string, number>>;
}

export class RoundLog {
  readonly #rounds: RoundRecord[] = [];
  #sites = new Set<string>();
  #lastScores: Record<string, number> = {};

  /** A bot headed for a bomb site this round. */
  noteSite(label: string): void {
    this.#sites.add(label);
  }

  roundEnded(event: RoundEndEvent): void {
    const ours = event.scores[event.team];
    const before = this.#lastScores[event.team] ?? 0;
    const won = ours === undefined ? undefined : ours > before;
    this.#rounds.push({ number: this.#rounds.length + 1, sites: [...this.#sites].sort(), planted: event.planted, won });
    this.#lastScores = { ...event.scores };
    this.#sites = new Set();
  }

  get roundNumber(): number {
    return this.#rounds.length + 1;
  }

  get records(): readonly RoundRecord[] {
    return this.#rounds;
  }

  /** One line per past round, newest last: "round 2: went B, bomb planted, won". */
  summary(role: string): readonly string[] {
    return this.#rounds.map(round => {
      const went = round.sites.length === 0 ? "never reached a site" : `went ${round.sites.join(" then ")}`;
      const plant = round.planted ? "bomb planted" : "no plant";
      const result = round.won === undefined ? "" : round.won ? ", won" : ", lost";
      const actor = role === "defend" ? "the attackers " : "";
      return `round ${round.number}: ${actor}${went}, ${plant}${result}`;
    });
  }
}
