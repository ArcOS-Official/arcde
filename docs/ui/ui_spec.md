# UI Specification

## 1. Purpose

This document defines the exact visual and interaction rules for the application UI.

The implementation must follow these rules unless a screen-specific specification overrides them.

The goal is:

* consistent sizing
* predictable spacing
* consistent component density
* predictable responsive behavior
* consistent animation
* reusable layouts
* minimal arbitrary CSS values

Use existing components and tokens before creating new values.

---

# 2. Base Units

The UI uses a **4px base unit**.

All spacing should normally be a multiple of 4px.

| Token      | Value | Typical use                          |
| ---------- | ----: | ------------------------------------ |
| `space-1`  |   4px | icon/text gap, very small separation |
| `space-2`  |   8px | compact component spacing            |
| `space-3`  |  12px | component internal spacing           |
| `space-4`  |  16px | default component spacing            |
| `space-5`  |  20px | section/component separation         |
| `space-6`  |  24px | card padding, section spacing        |
| `space-8`  |  32px | large section separation             |
| `space-10` |  40px | major section separation             |
| `space-12` |  48px | page-level separation                |
| `space-16` |  64px | large visual separation              |

Do not introduce values such as 13px, 18px, 22px, or 27px unless there is a specific design requirement.

---

# 3. Component Sizing

## 3.1 Control Heights

Controls use three standard sizes.

| Size    | Height | Use                                |
| ------- | -----: | ---------------------------------- |
| Small   |   32px | dense interfaces, tables, toolbars |
| Default |   36px | normal application controls        |
| Large   |   40px | primary actions, prominent forms   |

Default size is **36px**.

Do not create separate heights for individual components.

Buttons, inputs, selects, comboboxes, icon buttons, and similar controls should align to the same height scale.

### Responsive rule

Do not continuously scale controls with viewport width.

Use discrete size changes.

Example:

```text
Desktop:
Default control = 36px

Mobile:
Default control = 40px when additional touch area is required
```

Do not make a control 37px, 38px, or 39px simply because the viewport changed.

---

# 4. Buttons

## 4.1 Dimensions

| Size    | Height | Horizontal padding | Icon |
| ------- | -----: | -----------------: | ---: |
| Small   |   32px |               12px | 16px |
| Default |   36px |               16px | 16px |
| Large   |   40px |               20px | 18px |

Button content uses:

```text
icon → 8px → label
label → 8px → icon
```

Do not use arbitrary icon gaps.

## 4.2 Icon-only Buttons

| Size    |    Button | Icon |
| ------- | --------: | ---: |
| Small   | 32 × 32px | 16px |
| Default | 36 × 36px | 16px |
| Large   | 40 × 40px | 18px |

Icon-only controls must have an accessible label.

## 4.3 Button Groups

Buttons placed next to each other use:

```text
8px gap
```

Use `4px` only for extremely dense toolbar controls.

Use `12px` when buttons represent separate actions rather than a tightly related group.

---

# 5. Inputs

## 5.1 Standard Input

Default:

```text
height: 36px
horizontal padding: 12px
text size: 14px
icon: 16px
icon/text gap: 8px
```

Small:

```text
height: 32px
horizontal padding: 10px
text size: 14px
```

Large:

```text
height: 40px
horizontal padding: 12px
text size: 14px
```

## 5.2 Input Groups

Label to input:

```text
8px
```

Input to help text:

```text
4px
```

Input to error text:

```text
4px
```

Separate form fields:

```text
16px
```

Related fields inside the same group:

```text
12px
```

---

# 6. Typography

The default application text size is **14px**.

| Role       | Size | Line height |
| ---------- | ---: | ----------: |
| Caption    | 12px |        16px |
| Small      | 12px |        16px |
| Body       | 14px |        20px |
| Large body | 16px |        24px |
| Heading 4  | 16px |        24px |
| Heading 3  | 20px |        28px |
| Heading 2  | 24px |        32px |
| Heading 1  | 30px |        36px |

Do not increase body text size simply because there is empty space.

Increase hierarchy before increasing arbitrary font sizes.

---

# 7. Icons

Use one icon family throughout the application.

Preferred default:

**Lucide-style outline icons.**

Standard sizes:

| Size | Use                            |
| ---- | ------------------------------ |
| 14px | metadata, dense UI             |
| 16px | normal controls                |
| 18px | prominent controls             |
| 20px | navigation and section actions |
| 24px | large standalone actions       |

Default icon size is **16px**.

Icons must not be used merely as decoration when they communicate an action.

Do not mix filled, outlined, rounded, and custom icon styles without a documented reason.

---

# 8. Border Radius

Use a small radius scale.

| Token         |  Value | Use              |
| ------------- | -----: | ---------------- |
| `radius-sm`   |    4px | small elements   |
| `radius-md`   |    6px | controls         |
| `radius-lg`   |    8px | cards, panels    |
| `radius-xl`   |   12px | large containers |
| `radius-full` | 9999px | pills, avatars   |

Default control radius:

```text
6px
```

Default card radius:

```text
8px
```

Do not give every component a different radius.

---

# 9. Component Internal Spacing

## Card

Default:

```text
padding: 24px
```

Compact:

```text
padding: 16px
```

Dense:

```text
padding: 12px
```

Card title to description:

```text
4px
```

Description to content:

```text
16px
```

Card sections:

```text
24px
```

---

# 10. Widget Spacing

A widget is a reusable functional unit such as:

* chart
* table
* form
* card
* metric
* activity list
* editor
* search panel

Use the following hierarchy.

### Elements inside a widget

```text
4px–8px
```

### Related controls

```text
8px–12px
```

### Separate controls/groups

```text
16px
```

### Separate widgets

```text
24px
```

### Major page sections

```text
32px–48px
```

The default gap between widgets is:

```text
24px
```

Do not use the same spacing value for every relationship.

The larger the semantic separation, the larger the spacing should be.

---

# 11. Spacing Hierarchy

Use this hierarchy:

```text
4px
↓
8px
↓
12px
↓
16px
↓
24px
↓
32px
↓
48px
↓
64px
```

Interpretation:

```text
4px   = belonging
8px   = related
12px  = grouped
16px  = separate
24px  = distinct
32px  = section
48px  = major section
64px  = major visual break
```

Do not use 24px between two elements that clearly belong together.

Do not use 8px between two independent sections.

Spacing communicates hierarchy.

---

# 12. Page Layout

Use a page structure with three levels:

```text
Application shell
    ↓
Page container
    ↓
Content sections
    ↓
Widgets
```

Do not place widgets directly against the application shell.

## Page padding

| Viewport      | Horizontal padding |
| ------------- | -----------------: |
| Mobile        |               16px |
| Tablet        |               20px |
| Desktop       |               24px |
| Large desktop |               32px |

Use a maximum content width when the content becomes difficult to read or manage.

Typical maximum widths:

```text
640px   narrow content
768px   reading/forms
1024px  normal content
1280px  application dashboards
1440px  large application workspace
```

---

# 13. Layout Selection

Choose layouts based on the relationship between content.

## 13.1 Vertical Stack

Use when:

* content has a clear order
* sections depend on previous sections
* forms are sequential
* content should remain readable at all widths

Example:

```text
Page title
    ↓
Description
    ↓
Form
    ↓
Actions
```

Default gap:

```text
16px
```

---

## 13.2 Horizontal Row

Use when:

* elements belong to the same action group
* controls should remain on one line
* content has a strong horizontal relationship

Example:

```text
Search                  Filter   Sort
```

Default gap:

```text
8px
```

Allow items to wrap when the viewport becomes too small.

Do not force horizontal overflow unless horizontal scrolling is part of the design.

---

# 14. Grid

Use Grid when elements form a two-dimensional structure.

Good use cases:

* dashboards
* metric cards
* galleries
* settings panels
* repeated widgets
* responsive card layouts

Example:

```text
┌────────┬────────┬────────┐
│ Card   │ Card   │ Card   │
├────────┼────────┼────────┤
│ Chart          │ List    │
└────────────────┴─────────┘
```

Default grid gap:

```text
24px
```

Compact grid:

```text
16px
```

Large dashboard sections:

```text
32px
```

---

# 15. Responsive Grid Rules

Prefer minimum useful widths over arbitrary breakpoint-specific positioning.

Example:

```text
min card width: 280px
```

Conceptually:

```text
1 column
→ 2 columns
→ 3 columns
→ 4 columns
```

depending on available width.

Do not create separate desktop and mobile layouts when the same structure can adapt naturally.

Change the layout only when the relationship between elements changes.

---

# 16. Two-Column Layout

Use two columns when the secondary content supports the primary content.

Examples:

```text
Main content       Sidebar
──────────────     ───────
Editor             Properties
Document           Metadata
Chart              Filters
```

Recommended ratio:

```text
2fr 1fr
```

or:

```text
3fr 1fr
```

The primary content should receive more space.

On narrow screens:

```text
Main
↓
Sidebar
```

Do not keep a sidebar at desktop width on mobile.

---

# 17. Sidebar Layout

Use a sidebar when navigation or persistent tools are frequently accessed.

Recommended widths:

| Sidebar   | Width |
| --------- | ----: |
| Compact   |  56px |
| Standard  | 240px |
| Wide      | 280px |
| Inspector | 320px |

Do not make sidebars wider than necessary.

The main content should remain the dominant visual area.

---

# 18. Toolbar Layout

Toolbars should use compact spacing.

Default:

```text
control gap: 8px
group gap: 16px
```

Example:

```text
[Search] [Filter]     [View] [Sort]     [Create]
```

The spaces between groups must be larger than the spaces between controls inside a group.

This makes the toolbar readable without adding labels everywhere.

---

# 19. Tables

Table density should use three modes.

| Density     | Row height |
| ----------- | ---------: |
| Compact     |       32px |
| Default     |       40px |
| Comfortable |       48px |

Default:

```text
40px
```

Cell horizontal padding:

```text
12px
```

Dense table:

```text
8px–12px
```

Table headers should use the same horizontal alignment as table content.

Do not vertically center unrelated controls by adding arbitrary padding.

---

# 20. Dialogs

Recommended widths:

| Dialog      | Width |
| ----------- | ----: |
| Small       | 384px |
| Default     | 512px |
| Large       | 672px |
| Extra large | 768px |

Default dialog:

```text
512px
```

Dialog padding:

```text
24px
```

Title to description:

```text
4px
```

Description to content:

```text
16px
```

Content to actions:

```text
24px
```

Actions:

```text
8px gap
```

---

# 21. Drawers / Sheets

Use a drawer when the user needs to maintain context with the underlying page.

Good use cases:

* filters
* properties
* editing secondary information
* navigation
* contextual tools

Do not use a drawer for a workflow that requires full attention.

Recommended widths:

```text
320px
400px
480px
```

For mobile:

```text
100% width
```

---

# 22. Empty States

An empty state should use:

```text
icon
↓ 12px
title
↓ 4px
description
↓ 16px
primary action
```

Do not center every empty state vertically on the page.

Center it inside the relevant content region.

---

# 23. Loading States

Use skeletons when the structure of the content is known.

Use spinners when:

* the operation is short
* the layout cannot be predicted
* the action is local

Do not replace a full page with a spinner when the page structure can be displayed immediately.

Skeleton dimensions should match the final content dimensions.

Avoid animated skeletons when they provide no useful feedback.

---

# 24. Interaction States

Every interactive component should define:

```text
default
hover
focusDiscoverDiscover
pressed
disabled
loading
error
```

Not every component needs a visible style for every state, but the behavior must be intentional.

Focus must remain visible.

Disabled controls must not appear identical to normal controls.

---

# 25. Motion

Motion must communicate a state change.

Do not animate elements only because animation is available.

Use three motion speeds.

| Token             | Duration | Use                               |
| ----------------- | -------: | --------------------------------- |
| `duration-fast`   |    100ms | hover, color, opacity             |
| `duration-normal` |    150ms | controls, menus                   |
| `duration-slow`   |    200ms | dialogs, drawers, larger movement |

Avoid UI transitions longer than:

```text
300ms
```

unless the movement represents a substantial spatial change.

---

# 26. Easing

Use three primary curves.

## Standard

```text
cubic-bezier(0.2, 0, 0, 1)
```

Use for:

* panels
* drawers
* menus
* layout movement

## Enter

```text
cubic-bezier(0, 0, 0.2, 1)
```

Use when an element appears.

## Exit

```text
cubic-bezier(0.4, 0, 1, 1)
```

Use when an element disappears.

Do not use spring physics by default.

Use spring motion only when the product specifically benefits from physical movement.

---

# 27. Hover Motion

Hover effects should be subtle.

Preferred:

```text
opacity
background-color
border-color
box-shadow
transform
```

Avoid large movement.

Typical transform:

```text
translateY(-1px)
```

Typical duration:

```text
100ms
```

Do not make buttons jump several pixels on hover.

---

# 28. Pressed State

Pressed states should respond immediately.

Preferred duration:

```text
50ms–100ms
```

A small scale change may be used:

```text
scale(0.98)
```

Do not use large scale changes.

---

# 29. Dialog Animation

Recommended sequence:

```text
Overlay:
opacity 0 → 1
150ms

Dialog:
opacity 0 → 1
transform: scale(0.98) → scale(1)
150ms
```

Do not use large zoom effects.

The dialog should feel like it entered the current context, not like a separate page.

---

# 30. Drawer Animation

Recommended:

```text
transform: translateX(100%) → translateX(0)
200ms
```

Use the standard easing curve.

Overlay:

```text
opacity 0 → 1
150ms
```

Exit slightly faster than entry when appropriate.

---

# 31. Reduced Motion

Respect the user's reduced-motion preference.

When reduced motion is enabled:

```text
remove transforms
remove decorative movement
reduce transition duration
retain necessary opacity/state changes
```

Never make important information dependent on animation.

---

# 32. Scaling Rules

The UI should scale through **discrete design tiers**, not arbitrary continuous scaling.

### Small

```text
32px controls
12–16px spacing
16px widget gaps
```

### Default

```text
36px controls
16–24px spacing
24px widget gaps
```

### Large

```text
40px controls
24–32px spacing
32px widget gaps
```

Do not increase every dimension when the viewport increases.

Increase only the dimensions that benefit from additional space.

For example:

```text
button:
36px → 40px

page padding:
24px → 32px

widget gap:
24px → 32px

body text:
14px → 14px
```

Typography should usually remain stable while layout spacing expands.

---

# 33. Dense Interfaces

Use dense layouts for:

* developer tools
* data tables
* administration
* monitoring
* IDE-like interfaces
* professional dashboards

Dense mode:

```text
control height: 32px
widget gap: 16px
table row: 32px
control gap: 8px
card padding: 12px–16px
```

Do not use dense mode for onboarding, marketing, or primary consumer workflows.

---

# 34. Comfortable Interfaces

Use comfortable layouts for:

* forms
* settings
* content management
* general application screens

Comfortable mode:

```text
control height: 36px
widget gap: 24px
section gap: 32px
card padding: 24px
form field gap: 16px
```

This is the default mode.

---

# 35. Large / Presentation Interfaces

Use larger spacing when the interface needs strong visual hierarchy.

Examples:

* dashboards with few important metrics
* landing screens
* workspace home screens
* onboarding
* empty states

Large mode:

```text
control height: 40px
widget gap: 32px
section gap: 48px
card padding: 24px–32px
```

Do not increase everything simultaneously.

Large layouts require fewer elements per visual region.

---

# 36. Choosing a Layout

Use this decision rule.

### One primary task

Use:

```text
single-column
```

Example:

```text
Settings
↓
Profile
↓
Preferences
↓
Save
```

### Primary task + supporting information

Use:

```text
2-column
```

Example:

```text
Editor              Properties
```

### Many independent pieces of information

Use:

```text
Grid
```

Example:

```text
Metrics
Charts
Recent activity
Status
```

### Data with many rows

Use:

```text
Table
```

Do not convert a table into cards merely because cards are visually easier.

### Frequent tools

Use:

```text
Toolbar
Sidebar
Inspector
```

### Temporary contextual task

Use:

```text
Dialog
Drawer
Popover
```

Choose the smallest surface that supports the task.

---

# 37. Layout Priority

When space becomes constrained, remove secondary content before shrinking primary content below its usable size.

Priority:

```text
Primary content
↓
Primary action
↓
Required supporting information
↓
Secondary actions
↓
Decorative content
```

Do not allow secondary UI to make the primary task unusable.

---

# 38. Example 1 — Dashboard

Use a grid.

```text
┌─────────────────────────────────────────────────────┐
│ Page title                              [Create]    │
│ Description                                         │
├─────────────────────────────────────────────────────┤
│                                                     │
│  ┌────────────┐  ┌────────────┐  ┌────────────┐    │
│  │ Metric     │  │ Metric     │  │ Metric     │    │
│  │            │  │            │  │            │    │
│  └────────────┘  └────────────┘  └────────────┘    │
│                                                     │
│  ┌──────────────────────────┐  ┌────────────────┐  │
│  │                          │  │                │  │
│  │ Chart                    │  │ Activity       │  │
│  │                          │  │                │  │
│  └──────────────────────────┘  └────────────────┘  │
└─────────────────────────────────────────────────────┘
```

Rules:

```text
page padding: 24px
widget gap: 24px
section gap: 32px
card padding: 24px
control height: 36px
```

The dashboard uses Grid because the widgets have independent dimensions and relationships.

---

# 39. Example 2 — Settings Page

Use a two-column layout.

```text
┌─────────────────────────────────────────────────────┐
│ Settings                                            │
│                                                     │
│ Navigation       Profile                            │
│ ──────────       ───────────────────────────────    │
│ General          Name                              │
│ Account          [________________________]         │
│ Security         Email                             │
│ Billing          [________________________]         │
│                  Password                          │
│                  [________________________]         │
│                                                     │
│                                      [Save changes] │
└─────────────────────────────────────────────────────┘
```

Rules:

```text
sidebar: 240px
column gap: 32px
form field gap: 16px
label/input gap: 8px
input height: 36px
section gap: 32px
```

The sidebar should collapse above the main content on narrow screens.

---

# 40. Example 3 — Editor Workspace

Use a persistent application shell.

```text
┌──────┬──────────────────────────────────────────────┐
│      │ Toolbar                                      │
│ Side │──────────────────────────────────────────────│
│ bar  │                                              │
│      │                 Editor                       │
│      │                                              │
│      │                                              │
│      │───────────────────────────────┬──────────────│
│      │                               │ Inspector    │
└──────┴───────────────────────────────┴──────────────┘
```

Rules:

```text
sidebar: 240px
toolbar: 40px
inspector: 320px
toolbar control height: 32px
toolbar gap: 8px
inspector padding: 16px
```

The editor receives all remaining space.

The inspector must not reduce the editor below its minimum usable width.

On narrow screens:

```text
sidebar → collapses
inspector → drawer
editor → full width
```

This is preferable to shrinking the entire workspace until controls become unusable.

---

# 41. Implementation Rules

1. Use the defined spacing tokens.
2. Use the defined control heights.
3. Use the defined typography scale.
4. Use one icon family.
5. Use the defined radius scale.
6. Use semantic layout primitives.
7. Prefer Grid for two-dimensional layouts.
8. Prefer Flex for one-dimensional layouts.
9. Prefer Stack for vertical content.
10. Do not use absolute positioning for normal document layout.
11. Do not introduce arbitrary pixel values without a reason.
12. Do not redesign a screen while implementing its specification.
13. Do not create a new component when an existing component can satisfy the requirement.
14. Do not create a new spacing value for one screen.
15. Do not create a new animation curve for one component.
16. Do not use animation to hide poor layout.
17. Preserve accessibility and keyboard interaction.
18. Respect reduced-motion preferences.
19. Keep responsive behavior structural rather than cosmetic.
20. When a requirement conflicts with this specification, report the conflict instead of silently choosing a new rule.

---

# 42. AI Implementation Contract

When implementing a screen from this document:

```text
1. Identify the required layout.
2. Identify the required components.
3. Apply the sizing tokens.
4. Apply the spacing hierarchy.
5. Apply responsive rules.
6. Implement interaction states.
7. Implement motion.
8. Verify the resulting dimensions.
9. Do not invent new design rules.
```

If the design requires a value not present in this specification, first determine whether an existing token can satisfy the requirement.

Only introduce a new token when the value represents a reusable design decision.

A one-off pixel value is not a design system.

---

# 43. Default Values Summary

```text
Base unit:              4px

Default control:        36px
Small control:           32px
Large control:           40px

Default body:            14px / 20px

Default icon:            16px

Control radius:           6px
Card radius:              8px

Control gap:              8px
Form field gap:          16px
Widget gap:              24px
Section gap:             32px
Major section gap:       48px

Card padding:            24px
Compact card padding:    16px

Default dialog:         512px
Standard sidebar:       240px
Inspector:              320px

Fast animation:         100ms
Normal animation:       150ms
Slow animation:         200ms

Standard easing:
cubic-bezier(0.2, 0, 0, 1)Discover
```
