# Guidelines to commiting code

## Who can commit code
Only official maintainers can commit code, 3rd party pull reuqests maybe accepted
ONLY if they follow the plans in PLANS.md (that's if they're even disclosed there)
and follow the UI, code and architecture guidelines. Pull requests will not be accepted
from 3rd party developers past a certain scale

## Code guidelines
Code should always be zig fmted before doing a commited.

Code comment groups (aka comments on one line, multiple lines or as docs) cannot
exceed 4 sentences, they should never ocur twice in a function and they should
never ocur more than twice per 50 lines. The ratio of code to comment should be
roughly 90:1, equally distributed (to a reasonable extent obviously). Comments
should never explain what the code does, comments should either document over
signatures or explain weird or quircky parts of the codebase.

Commits should never have TODOs, FIXMEs, etc.., you have no execuse to push TODOs, it's very much
recommended to use them in staging and letting AI to complete missing pieces if the
code is not very critical or if you're in time trouble.

## Memory allocation
Heap allocations should be avioded as much as possible and long living, global
or pseudo-global (pseudo-global means the buffer storing it is just in a global var
that it's being allocated on using an fba) is encouraged.

## Global state and multi-threading
Global state should be more like a buffer, meaning that it's not supposed to be accessed
by many pieces of code even if guaranteed to not intersect with each other. Global state
should be an alternative for allocating objects on the heap when you know there can
only be one. For example, the snapshot system, some systems in the backend worker are
snapshotted for each frame to display that snapshotted version of the information preventing
mutex lock frame stutters and unsafety, there can only be one snapshot of something, so instead
of having it allocate a new snapshot each time one is requested, instead it syncs the snapshot every
time a modification happens and when a snapshot is requested it just sends it by value. So, if a bug
ocurs in that system the bug will be a visible de-sync instead of being a memory bug that takes alot more hunting.

Multi-threading should be a core functionality of this as the GUI, wayland compositor,
worker thread (for dbus communication and other miscellaneous blocking functionalities that might
slow down the high-demand event loops of both. multi-threading should be based on a snapshot system
where the snapshot is taken every time they are released or change ocurs so that the changes will be
applied on the backing data structure (the real source of truth) and every time the application
releases a snapshot the worker serving it will replace the snapshot with it's current state, if
there are modifications and the snapshot is not being used (that should usually be tracked by
some mutex that locks whenever one is requested and unlocks whenever that's not the case).

## Testing and architecture
A good flow to use (not always) is CTI (Complementarily Test Interface based design)
to have some interface that your backend like structure, like the renderer or the
compositor or the dbus listener or the wayland layer (the layer responsible for
actually bringing the requests) should be designed and programed first, then have some
function that let's it adapt to a certain interface then whenever another part needs it,
it just interacts with that interface which could lead to a fake compositor to test the shells
responses for example and things like that. Code should never be driven by tests but it should
make use of interfaces and make use of unit tests that don't test individual functionality, but instead
test the whole system.

for further information see the docs in `docs`

## Extras for AI models
AI models are not allowed in 3rd party contributions only core members can use AI
in the project, using AI as a 3rd party contributor will get you banned.

AI instructions:
  1. Aim for code readability and decrease as much comment noise as possible.
  2. Stop smashing everything into one liners.
  3. Always have a review subagent after you're done to make sure that you don't
  leave an unused, dead or majorly faulty code.
  4. Always have a separate subagent for creating the tests.
  5. Always update AGENTS.md after changes.
  6. It's fine to repeat yourself a little bit but always try to stay clean.
  7. Always make it so if someone is reading the code he can understand it without
  having to read definitions of uselesss sub-functions.
  8. Eliminate and rewrite the code that makes any assumptions that may not stand
  as much as they did before you change.
  9. Make it so if you replace a large pattern into a function, remove all the unused
  helpers that were only there for that pattern and just embed it into the function.
