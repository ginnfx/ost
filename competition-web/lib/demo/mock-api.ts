import type { CompetitionData, DemoState } from "../domain";
import { createDemoState } from "./data";

const KEY = "ost-competition-demo-v2";

/** Browser-only mock. Deliberately has no import or network path to the real API. */
export class SessionDemoData implements CompetitionData {
  async read(): Promise<DemoState> {
    const value = sessionStorage.getItem(KEY);
    if (!value) return this.reset();
    try {
      return JSON.parse(value) as DemoState;
    } catch {
      return this.reset();
    }
  }
  async write(state: DemoState): Promise<void> {
    sessionStorage.setItem(KEY, JSON.stringify(state));
  }
  async reset(): Promise<DemoState> {
    const state = createDemoState();
    await this.write(state);
    return state;
  }
}

export const demoData = new SessionDemoData();
