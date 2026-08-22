/**
 * Re-exported from `@drill/shared`, where the logic lives and is tested.
 *
 * Kept as a module rather than rewriting every import site, and kept NARROW: a
 * second implementation of this countdown is a second answer to "how long is
 * left", and the whole point is that the GUI and the watcher give one.
 */
export {
  idleView,
  humanDuration,
  clockDuration,
  type IdleView,
} from "@drill/shared";
