# arc

A Wayland desktop environment in one tree: a compositor, a shell, an IPC
protocol, and a forked GUI toolkit.

```
arc/
├── bank/       IPC protocol library (compositor <-> shell, unix sockets)
├── compositor/ nile — a wlroots 0.20 Wayland compositor (River lineage)
├── shell/      nshell — the layer-shell UI: bar, hub, control center
└── ui/         DVUI fork, SDL3-only (git submodule)
```

## What this is

Three projects that used to live as sibling repositories — `nile`
(compositor), `nshell` (shell) and `nilebank` (protocol) — plus a fork of
[DVUI](https://github.com/david-vanderson/dvui) — merged into one codebase
that builds as a unit. The IPC protocol, the compositor's bank that serves
it, and the shell that consumes it evolve together in one commit history.

## Building

Zig 0.16 plus system packages: `wayland`, `wayland-protocols`, `wlroots-0.20`
(`pkg-config wlroots-0.20`), `xkbcommon >= 1.12`, `libevdev`, `libinput`,
`pixman-1`, `systemd` (sd-bus for the shell). `scdoc` is optional for man
pages.

```
zig build -Dllvm=true            # nile + nshell + bank-server + bank-client
zig build -Dllvm=true test        # all test suites
zig build -Dllvm=true check       # typecheck only
zig build -Dllvm=true run-compositor
zig build -Dllvm=true run-shell
zig build -Dllvm=true bench       # headless launcher bench
```

`-Dllvm=true` is preferred on Linux: the self-hosted backend currently hits
`R_X86_64_PC64` sframe relocations with newer binutils. Pass `-Dxwayland=true`
for Xwayland support in the compositor.

The shell links against the `ui/` DVUI fork through a path dependency;
`git submodule update --init` after cloning.

## Running

From a TTY: `./scripts/arc-tty` starts nile with nshell as its startup
command (extra args pass to nile; `ARC_CMD` overrides the command,
`ARC_NILE`/`ARC_NSHELL` override binary resolution).

Start `nile` from a TTY (KMS/DRM) or nested in an existing session. It
spawns `$XDG_CONFIG_HOME/river/init` if present. `nshell` connects over
`/tmp/arcos/nilebank.sock` (see `bank/src/root.zig`) and draws the bar and
hub as layer-shell surfaces.

## Docs

- `NEWCOMMERS.md` — where to start reading this codebase
- `GUIDELINES.md` — commit rules, comment policy, memory + threading rules
- `docs/compositor_architecture.md` — compositor threading model
- `docs/nile-api.md` — the compositor's function API
- `docs/ui/ui_spec.md` — shell UI design tokens
- `docs/ui/dvui_fork_spec.md` — what belongs in the ui fork vs the app layer
- `ui/FORK.md` — fork provenance for the DVUI submodule

## Licensing

The compositor descends from River (GPL-3.0-only). The shell and bank are
original to this project. The ui fork carries DVUI's license (MIT). See
`LICENSES/` in the compositor directory and each subproject's header.
