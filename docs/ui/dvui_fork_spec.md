# DVUI Fork Specification

## 1. Goal

Fork DVUI and make it the application's actual UI toolkit.

The fork must remain recognizably DVUI.

Do not build a second GUI framework around it.

The fork exists to make targeted changes to:

* layout
* alignment
* widget ergonomics
* animation ergonomics
* rendering
* SDL support
* application-required drawing features

Everything else should stay close to upstream unless there is a concrete reason to change it.

The current DVUI repository already provides the immediate-mode widget model, widget tree through parent nesting, `WidgetData`, `Options`, `BasicLayout`, `FlexBoxWidget`, `GridWidget`, animation storage, gradients, blur-backdrop support, themes, drawing, and multiple backends. The fork should extend those systems rather than replace them.

---

# 2. Start From the Real Repository

Start from a specific upstream DVUI commit.

Record it in the fork:

```text
UPSTREAM_COMMIT
UPSTREAM_VERSION
```

Do not copy an old DVUI version and then design against today's documentation.

The fork should be understandable as:

```text
upstream DVUI
+
small, deliberate local changes
```

not:

```text
DVUI-inspired custom toolkit
```

The current upstream repository is tested with Zig 0.16.0 and exposes `src/dvui.zig` as the main client-facing module.

---

# 3. Keep `src/dvui.zig`

`src/dvui.zig` remains the central public module.

Do not move the public API into a new framework layer.

The current file already re-exports the important types and widgets, including:

```text
Options
Widget
WidgetData
Rect
Size
Color
Gradient
Theme
BasicLayout
Alignment
AnimateWidget
BoxWidget
FlexBoxWidget
GridWidget
...
```

The fork should continue this pattern.

New public fork functionality should be exported from `dvui.zig` when it is genuinely part of DVUI's public API.

---

# 4. SDL-Only Build

The fork removes non-SDL backends from the forked project.

Keep:

```text
SDL backend
DVUI core
current renderer used by the SDL backend
```

Remove from the fork's build surface:

```text
Web
Raylib
GLFW
WIO
DX11
other unused backends
```

Do not leave dead backend abstractions merely for theoretical compatibility.

The upstream build currently supports several backend choices, including SDL2, SDL3, Raylib, DX11, GLFW, WIO, and Web. The fork intentionally narrows this to SDL.

### Important

Do not invent a new generic backend interface to replace the removed backends.

Keep the backend structure that DVUI already uses.

Only delete the backend choices that are no longer required.

---

# 5. Do Not Fork the Architecture

Do not introduce:

```text
UI tree
retained widget tree
component framework
CSS system
layout framework
second renderer
event bus
animation framework
```

DVUI's existing architecture is the foundation.

The fork should continue using:

```text
Window
    ↓
current parent
    ↓
Widget / WidgetData
    ↓
child widgets
```

DVUI's implementation explicitly uses the current parent widget to establish nesting. A widget obtains its rectangle from its parent unless `Options.rect` explicitly chooses placement.

---

# 6. Understand the Existing Layout Model

The current layout model is:

```text
child reports:
    minimum size
    expand
    gravity_x
    gravity_y

parent chooses:
    child's rectangle
```

`Options` currently contains:

```zig
expand: ?Expand
gravity_x: ?f32
gravity_y: ?f32
min_size_content: ?Size
max_size_content: ?MaxSize
rect: ?Rect
```

with:

```text
Expand:
    none
    horizontal
    vertical
    both
    ratio

gravity:
    float 0..1
```

This is the mechanism the fork must improve. Do not replace it with a completely unrelated flexbox implementation.

---

# 7. Existing `BasicLayout`

`src/layout.zig` already contains `BasicLayout`.

For a vertical layout it:

```text
tracks y position
adds child heights
tracks maximum child width
```

For a horizontal layout it:

```text
tracks x position
adds child widths
tracks maximum child height
```

`rectFor()` ultimately calls:

```zig
dvui.placeIn(...)
```

with:

```text
min_size
expand
gravity
```

The existing implementation also has an important restriction:

> Once an expanded child has been encountered in the packing direction, a later sibling is an error.

The source explicitly recommends wrapping children in another vertical/horizontal box when that layout is needed.

The fork should fix the layout behavior where required rather than pretending DVUI already has a general flex layout system.

---

# 8. Alignment Is the Main Layout Change

The fork adds a real alignment model to the existing layout system.

Current DVUI uses:

```text
gravity_x
gravity_y
```

where the values are floats from `0` to `1`.

The fork should make the common cases explicit.

Add:

```zig
pub const Align = enum {
    start,
    center,
    end,
    stretch,
};
```

and use it at the layout level.

Do not remove numeric gravity internally if existing DVUI code still depends on it.

The implementation may translate:

```text
start   → 0
center  → 0.5
end     → 1
```

where appropriate.

`stretch` is different from gravity and must remain an explicit sizing operation.

---

# 9. Parent Alignment Defaults

The important new behavior is inheritance.

A parent container can specify:

```zig
align_x = .center
align_y = .center
```

and children inherit those defaults.

Example:

```zig
var box = dvui.box(@src(), .{}, .{
    .align_x = .center,
    .align_y = .center,
});
defer box.deinit();

...
```

The exact API can be finalized during implementation, but the semantic rule is fixed:

```text
parent alignment
        ↓
child default
        ↓
child explicit override
```

A child only specifies an alignment when it needs to differ from the parent.

---

# 10. Do Not Confuse Alignment With `expand`

These are separate decisions.

### Natural child

```text
min width = 200
expand = none
align = center
```

means:

```text
width = 200
position = centered
```

### Expanded child

```text
expand = horizontal
```

means:

```text
child consumes available horizontal space
```

### Stretch alignment

If introduced as a high-level alignment value:

```text
align = stretch
```

it must translate to the appropriate expansion/allocation behavior.

Do not implement:

```text
stretch = gravity 0.5
```

because that is incorrect.

---

# 11. Keep `Options` as the Boundary

Alignment belongs with layout options.

The existing `Options` struct is already the place for:

```text
rect
expand
gravity
margin
border
padding
min/max size
colors
font
theme
accessibility
```

The fork should extend `Options` rather than create a separate per-widget layout configuration object.

For example:

```zig
pub const Options = struct {
    ...
    align_x: ?Align = null,
    align_y: ?Align = null,
};
```

A `null` value means:

```text
inherit
```

This matches the existing optional `Options` pattern.

---

# 12. Layout Resolution

The fork's container layout should resolve children in this order:

```text
1. Child reports minimum size.
2. Parent collects child minimum sizes.
3. Parent determines available content space.
4. Parent allocates expanded children.
5. Parent applies maximum-size constraints.
6. Parent resolves alignment/gravity.
7. Parent produces the final child rectangle.
8. Child renders using that rectangle.
```

Do not calculate alignment from an earlier, provisional rectangle.

The final rectangle is the authoritative layout result.

---

# 13. Do Not Break `Options.rect`

`Options.rect` already means:

> The child is choosing its own placement.

When `rect != null`, the normal parent placement path must not also reposition the child.

The current implementation explicitly says that code using a non-null `rect` should not call `rectFor` or `minSizeForChild`. Preserve this distinction.

Alignment applies to normal parent-managed layout.

Explicitly positioned widgets remain explicitly positioned.

---

# 14. Margins, Padding, Borders

Do not replace DVUI's existing box model.

`Options` already separates:

```text
margin
border
padding
content
```

and `padSize()` adds them when calculating the widget's total size.

The alignment change must operate on the correct content/child rectangle after those dimensions are accounted for.

Do not create a second padding or spacing model.

---

# 15. Container Gap

Add a container-level gap where it is useful.

Example:

```zig
row(.{
    .gap = 8,
}) {
    ...
}
```

Internally this should be implemented by the existing container layout.

Do not implement gap by injecting visible spacer widgets unless that is genuinely required by DVUI's layout mechanism.

The goal is:

```text
children
+
relationship spacing
```

rather than:

```text
child
+
manual spacer
+
child
+
manual spacer
```

---

# 16. Existing `Alignment` Helper

DVUI already has an `Alignment` type in `src/layout.zig`.

It is **not** the same thing as the requested child alignment system.

The existing helper records widget positions in persistent data and adds spacers so widgets can share a left edge. It uses `_align` and `_max_align` data and refreshes when those values change.

Do not rename this existing type and pretend it solves the problem.

Either:

```text
keep it as-is
```

or:

```text
rename/refactor it deliberately
```

so the two concepts are not confused.

The new concept is:

```text
layout alignment
```

The existing helper is:

```text
cross-widget edge alignment using stored measurements
```

They are different.

---

# 17. Images

Image alignment needs special handling.

The image widget must distinguish:

```text
widget allocation rectangle
```

from:

```text
actual displayed image rectangle
```

For a non-expanded image:

```text
image natural/displayed size
```

is what should be aligned.

Do not center a source texture's dimensions after it has been scaled.

Do not treat unused expansion space as part of the visible image.

---

# 18. Image Fit Modes

If the existing image implementation already has the required sizing behavior, extend it rather than adding a parallel image widget.

The required semantic modes are:

```text
natural
contain
cover
stretch
```

For:

```text
contain
cover
```

alignment applies to the resulting displayed image rectangle.

Example:

```text
parent: 800 × 400
image:  200 × 100

center:
displayed image centered at 200 × 100
```

The source texture dimensions are irrelevant to parent alignment.

---

# 19. Text

Text layout already has its own measurement.

Use the measured text bounds for alignment.

Do not solve text alignment with:

```text
spaces
manual x offsets
magic margins
```

If text is placed inside a larger widget, alignment should operate on the text layout rectangle.

---

# 20. Baseline Alignment

Add baseline alignment only where the text layout data makes it possible to do correctly.

Primary use:

```text
icon + text
small text + large text
label + text
```

Do not fake baseline alignment by applying a fixed vertical offset to every icon.

If the required font metrics are not available at the point where a layout decision is made, change the layout data flow so the actual baseline can be used.

---

# 21. `FlexBoxWidget` and `GridWidget`

The current DVUI already contains:

```text
FlexBoxWidget
GridWidget
```

Do not create:

```text
NewFlexWidget
NewGridWidget
LayoutEngine
```

just because the fork needs more layout behavior.

First inspect the existing widgets and determine whether the desired behavior belongs in:

```text
BasicLayout
BoxWidget
FlexBoxWidget
GridWidget
Options
placeIn
```

Only add a new layout primitive if none of these is the correct owner.

---

# 22. Widget Rectangles

`WidgetData` already owns the widget's layout data and rectangle.

The fork should continue using that data rather than introducing a separate geometry object.

After layout:

```text
WidgetData.rect
```

is the widget's allocated rectangle.

For widgets with internal content, distinguish:

```text
widget rect
content rect
visual/content bounds
```

where necessary.

Do not redefine `WidgetData.rect` to mean something different for different widgets.

---

# 23. `data_out`

DVUI already has:

```zig
Options.data_out: ?*dvui.WidgetData
```

for obtaining widget data from higher-level APIs.

Do not invent another mechanism just to return:

```text
id
rect
min size
```

If the application-layer `ui` API wants a convenient result object, it can wrap `WidgetData`.

The core fork should preserve DVUI's existing mechanism.

---

# 24. Interaction API

Do not rewrite all of DVUI's event handling into a new event system.

DVUI already has widget event matching and dedicated input/dragging systems.

The fork may add convenience helpers, but they must delegate to the existing event machinery.

Target:

```zig
const result = ui.button(...);

if (result.clicked) {
    ...
}
```

This is primarily an **application ****`ui`**** layer** concern.

Do not contaminate every core DVUI widget with an unnecessary new return type if that makes the existing API worse.

---

# 25. Core DVUI vs Application `ui`

Keep this boundary strict.

### DVUI fork

Owns:

```text
Widget
WidgetData
Options
layout
events
rendering
theme
fonts
animation storage
backend
core widgets
```

### Application `ui`

Owns:

```text
button result conventions
application components
design tokens
application theme
convenience functions
application animations
application icons
application-specific layout helpers
```

If a change is useful to any DVUI application, it may belong in the fork.

If it exists only because this application wants a particular visual convention, it belongs in `ui`.

---

# 26. Animation: Use DVUI's Existing System

The previous specification was wrong to describe animation as if DVUI had no animation state system.

It does.

The current `AnimateWidget` uses:

```zig
dvui.animation(...)
dvui.animationGet(...)
```

and stores animation values using widget IDs and named data such as:

```text
"_start"
"_end"
```

`dvui.Id.update()` is explicitly used for stable names in systems including:

```text
dataGet/dataSet
animation
timer
```

The animation object stores its own start/end timing and easing.

The fork should extend this existing mechanism.

---

# 27. `animateValue`

Add a high-level helper in the fork or application `ui` layer:

```zig
const value = dvui.animateValue(
    id,
    from,
    to,
    .{
        .duration = 150_000,
        .easing = dvui.easing.easeOut,
    },
);
```

or, preferably for application code:

```zig
const value = ui.animateValue(
    "sidebar",
    0.0,
    if (open) 1.0 else 0.0,
    .{
        .duration = 150,
        .curve = .ease_out,
    },
);
```

The second API is an ergonomic wrapper.

It should use DVUI's existing persistent animation/data machinery rather than creating a second animation store.

---

# 28. Animation ID

Do not create a separate animation database keyed by arbitrary strings if DVUI's existing `Id` mechanism can represent the same identity.

Use DVUI IDs.

A string helper may derive an ID from the current widget/parent ID:

```text
parent ID
+
animation name
→
stable animation ID
```

This avoids collisions between two widgets both using:

```text
"opacity"
```

---

# 29. Animation Reversal

When:

```text
open → closed
```

changes to:

```text
closed → open
```

while the animation is still running, the new animation should start from the current interpolated value.

Do not restart from:

```text
0
```

or:

```text
1
```

unless explicitly requested.

This behavior belongs in the existing animation mechanism.

---

# 30. Existing `AnimateWidget`

Do not delete `AnimateWidget`.

It currently supports:

```text
none
alpha
vertical
horizontal
```

and uses the existing animation system to modify:

```text
alpha
height
width
```

It also accounts for gravity when shrinking an expanded widget.

The fork should preserve this behavior unless the new layout model makes it incorrect.

If `animateValue()` makes some uses of `AnimateWidget` redundant, migrate those callers deliberately.

Do not maintain two competing animation implementations indefinitely.

---

# 31. Animation Units

The existing `AnimateWidget.InitOptions.duration` is documented and implemented as:

```text
microseconds
```

Do not silently change that core API to milliseconds.

If the application `ui` API wants:

```zig
.duration = 150
```

to mean 150 ms, convert:

```text
milliseconds → microseconds
```

at that boundary.

Core DVUI keeps its existing time representation.

---

# 32. Easing

Use DVUI's existing easing system.

Do not introduce a second cubic-bezier implementation just for the fork.

Add missing easing functions only when required.

The existing `AnimateWidget` accepts:

```zig
?*const dvui.easing.EasingFn
```

and defaults to linear easing.

Application defaults may choose a different easing function.

That is a policy decision, not a reason to replace DVUI's easing mechanism.

---

# 33. Reduced Motion

DVUI already has:

```zig
dvui.reduce_motion
```

and the animation system knows about it.

Keep that mechanism.

Do not create:

```text
ui.reduce_motion
```

as an unrelated second global.

The application layer may provide a convenience accessor, but there must be one underlying state.

---

# 34. Gradients Already Exist

Do **not** specify "future gradient support" as if gradients are absent.

Current DVUI already exposes:

```zig
Gradient
ColorOrGradient
```

and `Options` color fields accept `ColorOrGradient`.

The fork should therefore:

```text
keep the existing gradient system
```

and only extend it where the application needs additional gradient operations.

Do not build a new gradient abstraction.

---

# 35. Blur Already Exists

Current DVUI contains:

```text
BlurBackdrop
```

and exports it from `dvui.zig`.

Therefore the fork specification is:

```text
inspect existing BlurBackdrop
↓
make it work correctly with SDL renderer
↓
fix limitations needed by the application
↓
provide an ergonomic wrapper if useful
```

Do not design a new blur framework.

If SDL cannot provide the desired blur directly, implement the smallest renderer-side mechanism that fits the existing render pipeline.

---

# 36. Glass

Glass is an application visual style, not a new fundamental DVUI widget.

The fork should expose the rendering primitives required to implement it:

```text
background
alpha
blur/backdrop
border
corner radius
shadow
```

The application `ui` layer can then define:

```zig
ui.glass(...)
```

Do not bake:

```text
black 0.85 alpha
white 0.85 alpha
specific blur radius
specific saturation
```

into every DVUI surface.

Those are application design decisions.

---

# 37. Rendering Changes

Use the existing render command pipeline.

Current `dvui.zig` exposes:

```text
renderText
renderTexture
renderIcon
renderImage
renderNinepatch
renderTriangles
```

and the render system already has render targets.

New drawing features should use these systems.

Do not create:

```text
UiRenderer
GlassRenderer
GradientRenderer
```

on top of the existing renderer.

If a feature cannot be implemented cleanly through the existing renderer, change the renderer itself.

---

# 38. Colors

Do not create an application-style color system inside core DVUI merely for:

```text
tint
shade
saturate
```

DVUI already owns the fundamental `Color` type and theme colors.

Add small, general-purpose color operations to `Color.zig` only when they are broadly useful.

Application-specific tokens remain in the application `ui` layer.

---

# 39. Theme

Keep DVUI's existing `Theme` and `Options.style/theme/color_*` mechanisms.

`Options` already allows:

```text
style
theme
color_fill
color_fill_hover
color_fill_press
color_text
color_text_hover
color_text_press
color_border
font
```

and supports gradients in those color fields.

Do not create a second theme system in the fork.

---

# 40. Widget Defaults

DVUI already allows widget defaults to be modified.

For example, its README documents changing:

```zig
dvui.ButtonWidget.defaults.background = false;
```

The fork should use this existing mechanism where global widget defaults are required.

Do not wrap every widget solely to change one default.

Use the application `ui` wrapper when the wrapper also provides meaningful application behavior.

---

# 41. Source-Level Customization

DVUI explicitly recommends copying the body of a high-level widget function when deeper customization is required.

The fork should follow that model.

If:

```text
button()
```

almost does what is needed but has one wrong behavior:

```text
inspect button implementation
↓
copy/modify the relevant implementation
↓
keep the widget architecture
```

Do not put a generic adapter around the original widget just to intercept every operation.

---

# 42. Do Not Invent a New Widget Lifecycle

Keep the existing:

```text
init
register
parentSet
children
deinit
```

flow.

DVUI's implementation notes describe `WidgetData.init()` as obtaining the widget ID, loading the previous frame's minimum size, obtaining a rectangle from the parent, and establishing the widget as the current parent.

Changes to layout must respect this lifecycle.

---

# 43. Two-Pass / Previous-Frame Behavior

Do not assume all layout information is available immediately.

DVUI persists widget data between frames.

For example:

```text
minimum size
alignment helper measurements
animation state
```

can depend on previous-frame data.

Any new layout behavior must explicitly account for this.

Do not write a layout algorithm that assumes:

```text
all children have already been measured
```

when DVUI's current execution model does not provide that information synchronously.

This is one of the main reasons the fork should modify `BasicLayout` and the relevant widgets rather than dropping in a generic retained-layout algorithm.

---

# 44. Expanded Children

Respect DVUI's existing `Expand` semantics.

Current values are:

```text
none
horizontal
vertical
both
ratio
```

with helper functions:

```zig
isHorizontal()
isVertical()
```

The fork should not replace this with a boolean:

```text
fill = true
```

because DVUI already distinguishes the two axes and has ratio expansion.

---

# 45. Ratio Expansion

Preserve:

```zig
.expand = .ratio
```

unless there is a demonstrated reason to change it.

Do not break image/aspect-ratio behavior while adding alignment.

Any alignment changes must have tests covering:

```text
ratio expansion
+
center alignment
+
nested containers
```

---

# 46. Testing Layout

Add focused tests for the modified layout functions.

Minimum cases:

```text
natural child + start
natural child + center
natural child + end

expanded child + start
expanded child + center
expanded child + end
expanded child + stretch

horizontal parent
vertical parent

nested aligned parents

minimum size
maximum size

mixed natural + expanded children

ratio expansion

explicit Options.rect

image contain
image cover

baseline alignment
```

Do not only test rendered screenshots.

Test the actual rectangles.

---

# 47. Test the Real Geometry

For a layout test, assert:

```text
x
y
width
height
```

on the resulting `WidgetData.rect`.

Do not test only:

```text
widget exists
```

or:

```text
render function was called
```

The purpose of the fork's layout work is deterministic geometry.

---

# 48. Regression Tests for Existing Behavior

Before changing layout:

```text
run existing tests
```

After changing layout:

```text
run existing tests
run new layout tests
run SDL example
```

The fork should not accept a layout change that fixes one alignment case while breaking:

```text
scrolling
dialogs
menus
tables
panels
floating widgets
```

---

# 49. SDL Verification

The fork is not complete when it compiles.

Verify an actual SDL application.

At minimum:

```text
window creation
input
mouse
keyboard
text
icons
images
clipping
scrolling
animation
render targets
blur if enabled
gradients
```

The SDL example must exercise the modified code paths.

---

# 50. Upstream Sync

Keep upstream changes recognizable.

When modifying an upstream file:

```text
preserve surrounding structure
make the local change obvious
keep comments short
avoid unrelated formatting changes
```

Do not rewrite an entire upstream file merely because one function needs modification.

This is important because the fork may later be compared manually with upstream.

---

# 51. File Ownership

Prefer this ownership:

```text
src/Options.zig
    alignment options
    existing widget sizing/style options

src/layout.zig
    alignment resolution
    placement
    BasicLayout changes

src/widgets/BoxWidget.zig
    container-specific layout behavior

src/widgets/FlexBoxWidget.zig
    flex-specific behavior

src/widgets/GridWidget.zig
    grid-specific behavior

src/widgets/AnimateWidget.zig
    existing animated container behavior

src/Animation/Data system
    persistent animation state

src/render*.zig
    renderer changes

src/BlurBackdrop.zig
    existing blur/backdrop implementation

src/Color.zig
    general color operations

src/dvui.zig
    public exports
```

Do not put all fork changes into `dvui.zig`.

---

# 52. What Belongs in the Application `ui` Module

The application layer can then add:

```text
ui.button()
ui.iconButton()
ui.animateValue()
ui.glass()
ui.row()
ui.column()
ui.center()
ui.spacing()
ui.colors
ui.icons
```

These are ergonomic application APIs.

The fork should provide the primitives that make those APIs cheap.

---

# 53. The Target API

The target is not:

```zig
var animation = ...
var timer = ...
var elapsed = ...
var progress = ...
dvui.refresh(...)
...
```

The target application code is:

```zig
const opacity = ui.animateValue(
    "sidebar",
    0.0,
    if (open) 1.0 else 0.0,
    .{ .duration = 150 },
);
```

Likewise, normal interaction should be:

```zig
const result = ui.button("Save", .{});

if (result.clicked) {
    save();
}
```

The application layer hides repetitive mechanics.

The DVUI fork provides the underlying mechanisms.

---

# 54. Do Not Put Everything in the Fork

A useful rule:

### Put it in the fork if it changes DVUI's fundamental behavior.

Examples:

```text
parent alignment inheritance
better placement
image alignment
layout fixes
SDL renderer behavior
animation primitive
general rendering primitive
```

### Put it in `ui` if it is an application convention.

Examples:

```text
36px buttons
8px standard gaps
glass card style
application accent color
Lucide icon defaults
button result wrapper
design tokens
```

This prevents the fork from becoming application-specific sludge.

---

# 55. Implementation Order

Do the fork in this order:

```text
1. Copy upstream DVUI at a recorded commit.

2. Make the fork build with SDL only.

3. Run the unmodified SDL examples.

4. Add layout tests around the existing BasicLayout/placeIn path.

5. Add alignment inheritance to Options + container layout.

6. Fix image alignment using actual displayed bounds.

7. Add/verify baseline alignment.

8. Fix mixed natural/expanded child layout.

9. Verify existing FlexBox/Grid behavior.

10. Extend the existing animation/data system.

11. Add animateValue() as a thin API over that system.

12. Verify gradients already present.

13. Verify/fix BlurBackdrop on SDL.

14. Add only the renderer changes required by the application.

15. Run the full SDL test/example set.

16. Compare the final fork against the recorded upstream commit.
```

Do not start by designing new abstractions.

Start by changing the actual code paths responsible for the behavior.

---

# 56. Definition of Done

The fork is complete when:

```text
SDL-only build works
existing DVUI widgets work
existing immediate-mode model remains intact
Options remains the widget configuration boundary
BasicLayout remains understandable
parent alignment works
child alignment overrides work
natural children align correctly
expanded children still work
images align using displayed bounds
baseline alignment works
minimum/maximum sizing still works
FlexBox still works
Grid still works
animations use persistent DVUI state
animation reversal works
gradients work
blur works or has a deliberate fallback
application can build its ui module on top
```

And, importantly:

```text
A developer familiar with upstream DVUI can open the fork
and understand where the local changes are.
```

---

# 57. Non-Goals

Do not build:

```text
CSS
retained-mode application framework
React-style component model
second widget tree
second renderer
generic backend framework
physics animation engine
layout DSL
automatic responsive design engine
massive design-token system inside DVUI
```

Do not solve problems the application does not have.

---

# 58. Core Principle

The fork is a **modified DVUI**, not a replacement for DVUI.

Keep DVUI's:

```text
IDs
WidgetData
Options
parent/child model
immediate-mode execution
layout primitives
render pipeline
data persistence
animation machinery
```

Change the parts that currently make the application's UI unnecessarily awkward.

The largest planned core change is:

```text
current:
child gives parent minimum size + expand + gravity

fork:
child gives parent minimum size + sizing requirements
parent supplies inherited alignment
child may explicitly override alignment
parent produces final rectangle
```

Everything else should stay as close to DVUI as practical.
