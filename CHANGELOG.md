# Changelog

Changes to the Cascade Animation Runtime. Plugin editor changes are listed on the store page.

---

### v2.3.3

**Re-install the runtime** (from the plugin, or by replacing the files in `runtime/`) to get these changes!

**New features**

* **Check your animations** — the new `AnimationService.Validate(animation)` returns `ok, errors` and lists every problem in an animation in plain words, such as a keyframe placed after the end, a misspelled easing style or a value of the wrong type. It works with an animation table or a saved animation's name, never changes the animation, and is never called during playback.

**Improvements**

* **Faster runtime** — playing animations now cost less than half as much per frame, finished, paused and held animations cost nothing at all, and the runtime no longer creates garbage every frame. Games with many animated buttons and menus run smoother.
* **Faster Stop and Clear** — `Stop`, `StopBatch` and `ClearInstance` no longer slow down when a game has many animations.

**Changes you may notice**

* **Finished animations let go** — when an animation ends, it writes its final frame once and then stops touching your UI. Your own scripts and tweens can change the property afterwards without the animation snapping it back. A finished track reports `IsFinished = true`.
* **Playing again takes over** — playing the same animation on the same object again restarts it. The signal returned by the earlier `Play` receives `Cancelled` once and nothing after that, so code that waits for it never hangs.
* **Completed fires once** — `Completed` fires when the whole animation is done (after the last loop, never for endless loops). `Looped` fires on every cycle.
* **Reset now restores at the end** — with `Reset = true`, the object goes back to how it looked before that run when the animation finishes, not only when it is cleared.
* **Saved Delay is now used** — an animation saved with a Delay now waits for that Delay when you play it with `Play` or `PlayBatch`. Pass `Delay = 0` to start it right away. `CreateTrack` still uses only the `Delay` you pass to it.
* **Relative animations start from where the object is** — a relative animation now adds its movement on top of the object's current value when you call `Play`, instead of a value remembered from the first time it was animated.
* **Replaying a finished track** — calling `:Play()` on a track that has finished plays it again from the start, like a tween. `Resume` on a finished animation does nothing.

**Bug fixes**

* **Hover in, out and in again** — playing a hover animation again after its reverse now shows it, instead of staying stuck.
* **Events fire correctly** — events now fire in the right order and the right number of times when an animation plays in reverse, loops, or runs as a staggered batch, including events on the very first and last frame.
* **Relative animations stay in place** — repeated or overlapping relative animations no longer drift, also on whole-number properties such as ZIndex and TextSize.
* **PlayBatch errors** — batches no longer throw errors when one of their objects is removed or the batch is cleared, and replaying a batch in a new order follows that order.
* **Pausing during a Delay** — pausing an animation while it waits for its Delay now keeps the rest of the Delay when it resumes.
* **One failed property no longer blocks others** — if writing a property fails once, later animations on that property still play.
* **Editor fixes** — this release also contains many editor fixes (saving, opening, undo, recording); see the store page.
