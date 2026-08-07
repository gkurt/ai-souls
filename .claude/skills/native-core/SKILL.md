---
name: core
description: Core Native SDK guide for AI agents. Read this before explaining the Native SDK or changing a Native SDK app. Covers the mental model (native-rendered apps by default, WebView shells as a coexisting architecture), project structure, app.zon, App and Runtime patterns, frontend integration, web engines, JavaScript bridge commands, permissions, windows, WebViews, dialogs, packaging, debugging, testing, and when to load deeper references. For authoring native-rendered UI (Native markup .native views, Model/Msg/update, UiApp), load the native-ui skill. Use when the user asks what the Native SDK is, how to build or modify an app, how to package or debug it, or how to add native capabilities.
---

# Build Native SDK apps

The Native SDK is a cross-platform native app toolkit inspired by the web. The default app (`native init`) is native-rendered: a declarative Native markup view (`.native`) plus Zig logic on the `UiApp` loop, drawn by Native SDK's own engine — **load the `native-ui` skill for everything about authoring those** (markup grammar, bindings, messages, testing, hot reload). This skill covers the shared foundation and the WebView-shell architecture: apps that render web frontends in a WebView (`native init --frontend next|vite|react|svelte|vue`). Both architectures share windows, policies, lifecycle, commands, and platform services, and one app can mix native-rendered surfaces and WebViews. WebView engines: platform WebView (WKWebView on macOS, WebKitGTK on Linux) or Chromium through CEF where supported.

Agents should assume they do not know the Native SDK from general model knowledge. Read this skill first. For implementation work, run `native skills get core --full` so the referenced files are included in the CLI output.

## Mental model

- `App` describes the product: app state, name, WebView source, lifecycle callbacks, and optional bridge dispatcher.
- `Runtime` owns the event loop, windows, bridge dispatch, security checks, automation, tracing, platform services, and window state.
- `WebViewSource` tells the runtime what to load: inline HTML, a URL, or packaged assets from a local app origin.
- `app.zon` is the app manifest: identity, icons, windows, frontend assets, web engine, permissions, bridge policy, security policy, and packaging inputs.
- `src/runner.zig` is the generated runtime wiring. Edit it when adding runtime services, security policy, builtin bridge policy, tracing, automation, or platform setup.
- `src/main.zig` is app behavior. Edit it when changing app state, source selection, lifecycle callbacks, or app-defined bridge handlers.
- `frontend/` is normal web code. It talks to native Zig through `window.zero.invoke()` or builtin helpers when those are enabled.

## Task router

These references are included by `native skills get core --full`. Use them when the task touches the topic:

- Project creation, generated files, build steps: `references/project-anatomy.md`
- `App`, `Runtime`, callbacks, embedding, tests: `references/app-model-runtime.md`
- React/Vue/Svelte/Next/Vite, dev server, bundled assets: `references/frontend-assets.md`
- App-defined bridge commands, builtin commands, permissions, windows, WebViews, dialogs: `references/bridge-security-native-capabilities.md`
- Web engine choice, CEF, packaging, signing, doctor, logs, debugging: `references/web-engines-packaging-debugging.md`
- Running-app inspection and smoke tests: `native skills get automation`
- `zig build` fails on std APIs ("no member named 'cwd'", ArrayList `init`): `native skills get zig` — the Zig 0.16 idioms, indexed by compile error

## Quick start

Use the CLI for new apps:

```bash
npm install -g @native-sdk/cli
native init my_app --frontend next
cd my_app
zig build run
```

Frontend choices are `next`, `vite`, `react`, `svelte`, and `vue`. The first `zig build run` installs frontend dependencies, builds the native shell, and opens a desktop window.

## Workflow for existing apps

Before editing an existing Native SDK app:

1. Read `app.zon`, `src/main.zig`, `src/runner.zig`, and `build.zig`.
2. Identify whether the change is app metadata/policy, runtime wiring, app-native behavior, frontend behavior, packaging, or automation.
3. Follow the generated code and examples in the repository instead of inventing a new app layout.
4. Prefer exact security policy changes over broad allowances.
5. Validate with the narrowest useful command.

Common file ownership:

- `app.zon`: app identity, version, icons, windows, permissions, capabilities, bridge command policy, allowed origins, frontend dist/dev config, web engine, CEF config.
- `src/main.zig`: `App` state, source selection, lifecycle callbacks, custom bridge handlers.
- `src/runner.zig`: `Runtime.init`, platform selection, security policy, builtin bridge policy, `js_window_api`, automation server, trace sinks, panic capture, window state store.
- `build.zig`: build options, frontend build/dev/package steps, platform link setup, test steps.
- `frontend/`: web app implementation, `window.zero` calls, dev/build config.

## Core app model

The minimal Zig app returns `native_sdk.App` with `context`, `name`, and a WebView source:

```zig
const App = struct {
    fn app(self: *@This()) native_sdk.App {
        return .{
            .context = self,
            .name = "my-app",
            .source = native_sdk.WebViewSource.html("<h1>Hello from Native SDK</h1>"),
        };
    }
};
```

Use these source constructors:

- `native_sdk.WebViewSource.html(content)` for small inline demos.
- `native_sdk.WebViewSource.url(address)` for an explicit URL.
- `native_sdk.WebViewSource.assets(.{ .root_path = "frontend/dist", .entry = "index.html" })` for packaged frontend assets.

For framework apps, prefer a dynamic source so development loads the local dev server and production loads bundled assets:

```zig
fn source(context: *anyopaque) anyerror!native_sdk.WebViewSource {
    const self: *App = @ptrCast(@alignCast(context));
    return native_sdk.frontend.sourceFromEnv(self.env_map, .{
        .dist = "frontend/dist",
        .entry = "index.html",
    });
}
```

`sourceFromEnv` reads `NATIVE_SDK_FRONTEND_URL`; otherwise it serves the configured asset directory. Use it for most framework apps.

## app.zon essentials

Keep `app.zon` as the source of truth for app-level behavior:

```zig
.{
    .id = "com.example.my-app",
    .name = "my-app",
    .display_name = "My App",
    .description = "One line about the app, shown in the About panel.",
    .version = "0.1.0",
    .icons = .{"assets/icon.png"},
    .platforms = .{ "macos", "linux" },
    .permissions = .{},
    .capabilities = .{ "webview" },
    .frontend = .{
        .dist = "frontend/dist",
        .entry = "index.html",
        .spa_fallback = true,
        .dev = .{
            .url = "http://127.0.0.1:5173/",
            .command = .{ "npm", "--prefix", "frontend", "run", "dev", "--", "--host", "127.0.0.1" },
            .ready_path = "/",
            .timeout_ms = 30000,
        },
    },
    .security = .{
        .navigation = .{
            .allowed_origins = .{ "zero://app", "http://127.0.0.1:5173" },
            .external_links = .{ .action = "deny" },
        },
    },
    .web_engine = "system",
    .windows = .{
        .{ .label = "main", .title = "My App", .width = 960, .height = 640, .restore_state = true },
    },
}
```

Use exact local origins for dev servers. Add `zero://inline` only for inline HTML sources.

## Common implementation recipes

### Add a new framework app

Use `native init <path> --frontend <next|vite|react|svelte|vue>`. Then inspect the generated `app.zon`, `src/main.zig`, and `build.zig` before customizing. For framework behavior, keep frontend work in `frontend/` and use `sourceFromEnv` so development and packaged builds share one app shell.

### Add a native bridge command

1. Add state and a handler in `src/main.zig`.
2. Register the handler in `bridge()`.
3. Allow the command in `app.zon` and in the runtime bridge policy if the runner reads manifest policy into runtime.
4. Call it from JavaScript with `window.zero.invoke("namespace.command", payload)`.
5. Return valid JSON from Zig. Use `native_sdk.bridge.writeJsonStringValue()` for user-controlled strings.

Bridge calls are size-limited, origin-checked, permission-checked, and routed only to registered handlers.

### Add windows, child WebViews, or dialogs

Use builtin bridge commands only after enabling a policy for the exact commands and origins. Window and child WebView commands need the `window` permission when permissions are configured. Dialog commands are always default-deny and require explicit `builtin_bridge` policy. See `references/bridge-security-native-capabilities.md`.

### Choose a web engine

Default to `.web_engine = "system"` for small apps and native footprint. Use `.web_engine = "chromium"` plus `.cef` when the app needs a pinned Chromium platform or rendering consistency. Chromium apps must install/package the matching CEF layout.

### Package an app

Zero-config apps package WITHOUT ejecting — `native package` works directly on the zero-config build (`native eject` is only for owning the build files, never a packaging prerequisite):

```bash
native build
native package --target macos
```

Apps that own their build (ejected or scaffolded `--full`) wire the same step into the build graph: keep package metadata in `app.zon`, build the frontend assets, build the native binary, then package:

```bash
zig build package
native doctor --manifest app.zon --strict
```

Use signing and CEF options only when the product requires them.

## Development commands

For iterative frontend work, use the managed dev server flow:

```bash
zig build dev
```

Or run the CLI directly after building the binary:

```bash
native dev --manifest app.zon --binary zig-out/bin/MyApp
```

Vite usually uses `http://127.0.0.1:5173/`; Next.js usually uses `http://127.0.0.1:3000/`. The app WebView loads the dev URL directly, so framework HMR remains owned by Vite, Next.js, or the selected dev server.

## Security defaults

Treat WebView content as untrusted:

- List only needed `permissions` and `capabilities`.
- Prefer exact bridge command origins over `"*"`.
- Keep main-frame navigation allowlisted in `security.navigation.allowed_origins`.
- Keep external links denied unless the product explicitly needs them.
- Use a strict CSP for packaged frontend assets.
- Built-in dialogs are always default-deny and require explicit `builtin_bridge` policy.
- Child WebViews receive `window.zero` only when explicitly created with `bridge: true`.

Common bridge failure codes are `invalid_request`, `unknown_command`, `permission_denied`, `handler_failed`, `payload_too_large`, and `internal_error`.

## Validate changes

Useful commands:

```bash
zig build run
zig build dev
zig build test
zig build test-tooling
native validate app.zon
native doctor --manifest app.zon --strict
zig build package
```

Run BOTH `zig build` and `zig build test` before calling a change done: Zig's lazy analysis means code only tests reference (or only `main()` reference) can sit broken for weeks under the other command alone — tests never analyze `main`, so an API removed from std can keep "passing" until the app build finally touches it.

The toolkit requires Zig 0.16.0. When a build fails with "no member named" errors on std APIs (`std.fs.cwd`, `ArrayList.init`, `std.io`, `GeneralPurposeAllocator`), the code was written against older Zig idioms — `native skills get zig` maps each such compile error to the 0.16 idiom as this SDK writes it.

For GUI smoke tests, build with automation enabled and use the `automation` skill:

```bash
zig build run -Dplatform=macos -Dautomation=true
zig-out/bin/native automate snapshot
```

When changing app behavior, add focused Zig tests when the code can run headlessly. Use automation-based tests only for WebView/runtime integration that requires a GUI-capable session.

## Examples to inspect

- `examples/hello`: smallest inline HTML app.
- `examples/webview`: bridge and WebView runtime example.
- `examples/browser`: layered WebView/browser-style example.
- `examples/next`: Next.js with production assets.
- `examples/react`, `examples/svelte`, `examples/vue`: Vite frontend apps.
- `examples/ios`, `examples/android`: mobile host embedding examples.

## When answering users

Explain the Native SDK in concrete terms: Zig owns native app lifecycle and security; web UI renders in a WebView; the bridge is opt-in and policy controlled; `app.zon` is the manifest; framework frontend development uses a dev server in development and bundled assets in production. If asked to implement, read the app files first and make the smallest change in the correct layer.


---
# references/app-model-runtime.md

# App Model and Runtime

Use this when editing `src/main.zig`, `src/runner.zig`, lifecycle behavior, runtime setup, or tests.

## `App`

A Native SDK app returns a `native_sdk.App` value:

```zig
const App = struct {
    fn app(self: *@This()) native_sdk.App {
        return .{
            .context = self,
            .name = "my-app",
            .source = native_sdk.WebViewSource.html("<h1>Hello</h1>"),
            .source_fn = source,
            .start_fn = start,
            .event_fn = event,
            .stop_fn = stop,
        };
    }
};
```

Required fields:

- `context`: pointer to app state.
- `name`: app name for traces and automation snapshots.
- `source`: initial WebView source. Overridden by `source_fn` when present.

Optional callbacks:

- `source_fn`: dynamic source resolver.
- `start_fn`: called after runtime start and initial load.
- `event_fn`: receives lifecycle and runtime events.
- `stop_fn`: called before shutdown.

## `WebViewSource`

Choose one:

```zig
native_sdk.WebViewSource.html("<p>Inline</p>")
native_sdk.WebViewSource.url("http://127.0.0.1:5173/")
native_sdk.WebViewSource.assets(.{
    .root_path = "frontend/dist",
    .entry = "index.html",
    .origin = "zero://app",
    .spa_fallback = true,
})
```

Use inline HTML only for small examples and smoke tests. Use URL sources for explicit local/remote loading. Use assets for packaged apps.

## Runtime setup

Generated runners create a `Runtime` with platform services:

```zig
var runtime = native_sdk.Runtime.init(.{
    .platform = my_platform,
    .trace_sink = fanout.sink(),
    .bridge = my_app.bridge(),
    .builtin_bridge = .{ .enabled = true, .commands = &builtin_policies },
    .security = .{
        .permissions = &app_permissions,
        .navigation = .{ .allowed_origins = &.{ "zero://app" } },
    },
    .js_window_api = true,
    .window_state_store = state_store,
    .automation = if (build_options.automation) automation_server else null,
});
try runtime.run(my_app.app());
```

`RuntimeOptions` fields agents commonly touch:

- `platform`: macOS, Linux, Windows, or `NullPlatform`.
- `trace_sink`: stdout/file/fanout trace destination.
- `bridge`: app-defined bridge dispatcher.
- `builtin_bridge`: policy for built-in windows, WebViews, and dialogs.
- `security`: permissions, navigation allowlist, external links.
- `automation`: file-based automation server.
- `window_state_store`: persisted window geometry.
- `js_window_api`: exposes `window.zero.windows` and `window.zero.webviews`.

## Windows from Zig

Use runtime methods for native window management:

```zig
const info = try runtime.createWindow(.{
    .label = "tools",
    .title = "Tools",
    .default_frame = native_sdk.geometry.RectF.init(80, 80, 420, 320),
});
try runtime.focusWindow(info.id);
```

Window limits:

- Max windows: 16.
- Max label bytes: 64.
- Max title bytes: 128.

Persisted window state is keyed primarily by `label`, so labels should be stable.

## EmbeddedApp

Use `EmbeddedApp` when another host owns the main loop:

```zig
var embedded = native_sdk.embed.EmbeddedApp.init(my_app.app(), my_platform);
defer embedded.deinit();
try embedded.start();
try embedded.frame();
try embedded.resize(new_surface);
try embedded.stop();
```

This is useful for mobile hosts, game engines, custom render loops, and headless tests. The repository includes iOS and Android examples that link `libnative-sdk.a` through Swift/Kotlin host apps.

`stop()` tells the app it is shutting down; `deinit()` releases what the embedded runtime owns on the heap (registered canvas font bytes). It is idempotent, so `defer embedded.deinit()` right after `init` is the idiom — an embedder that creates and destroys apps in one process leaks the font registry per cycle without it. The C ABI's `native_sdk_app_destroy` runs the same deinit through its host wrapper.

## Headless tests

Use `NullPlatform` or `TestHarness` when GUI behavior is not required:

```zig
var null_platform = native_sdk.NullPlatform.init(.{});
var runtime = native_sdk.Runtime.init(.{
    .platform = null_platform.platform(),
});
```

Good headless test targets:

- source selection
- bridge handler logic
- bridge policy enforcement
- lifecycle callbacks
- manifest/tooling behavior

Use automation smoke tests for real WebView/window integration.


---
# references/bridge-security-native-capabilities.md

# Bridge, Security, and Native Capabilities

Use this when adding JavaScript-to-Zig calls, builtin commands, permissions, windows, child WebViews, dialogs, navigation policies, or external links.

## Bridge architecture

JavaScript calls native Zig through:

```javascript
const result = await window.zero.invoke("native.ping", { source: "webview" });
```

The runtime:

1. Parses the JSON request.
2. Enforces message size limits.
3. Checks origin and permissions.
4. Looks up a registered handler.
5. Runs the handler and returns a JSON response.

Bridge commands are default-deny. A command must be registered in Zig and allowed by policy.

## Handler pattern

```zig
fn ping(context: *anyopaque, invocation: native_sdk.bridge.Invocation, output: []u8) anyerror![]const u8 {
    _ = invocation;
    const self: *App = @ptrCast(@alignCast(context));
    self.ping_count += 1;
    return std.fmt.bufPrint(output, "{{\"message\":\"pong\",\"count\":{d}}}", .{self.ping_count});
}
```

Dispatcher pattern:

```zig
fn bridge(self: *App) native_sdk.BridgeDispatcher {
    self.handlers = .{.{ .name = "native.ping", .context = self, .invoke_fn = ping }};
    return .{
        .policy = .{ .enabled = true, .commands = &policies },
        .registry = .{ .handlers = &self.handlers },
    };
}
```

When returning user-controlled strings, escape them:

```zig
return native_sdk.bridge.writeJsonStringValue(output, user_name);
```

## Size limits

- Request message: 16 KiB.
- Response: 16 KiB.
- Handler result: 12 KiB.
- Request ID: 64 bytes.
- Command name: 128 bytes.

For large data, do not force everything through one bridge response. Use native files/resources or chunking patterns.

## Security policy

Core defaults:

- No permissions granted unless listed.
- Bridge commands denied unless policy allows them.
- Navigation blocked unless origin is allowlisted.
- External links denied unless configured.
- Dialog builtin commands always denied unless explicitly listed in `builtin_bridge`.

Manifest examples:

```zig
.permissions = .{ "window" },
.capabilities = .{ "webview", "js_bridge" },
.bridge = .{
    .commands = .{
        .{ .name = "native.ping", .origins = .{ "zero://app" } },
    },
},
.security = .{
    .navigation = .{
        .allowed_origins = .{ "zero://app", "http://127.0.0.1:5173" },
        .external_links = .{ .action = "deny" },
    },
},
```

Prefer exact origins over `"*"`. Use `"*"` only for commands that expose no native state and only when the project already accepts that risk.

## Builtin commands

The Native SDK includes builtin bridge commands for windows, layered WebViews, and dialogs. These are controlled separately from app-defined commands via `builtin_bridge`.

Window commands:

- `native-sdk.window.list`
- `native-sdk.window.create`
- `native-sdk.window.focus`
- `native-sdk.window.close`

Layered WebView commands:

- `native-sdk.webview.create`
- `native-sdk.webview.list`
- `native-sdk.webview.setFrame`
- `native-sdk.webview.navigate`
- `native-sdk.webview.setZoom`
- `native-sdk.webview.setLayer`
- `native-sdk.webview.close`

Dialog commands:

- `native-sdk.dialog.openFile`
- `native-sdk.dialog.saveFile`
- `native-sdk.dialog.showMessage`

Enable explicitly:

```zig
const app_permissions = [_][]const u8{native_sdk.security.permission_window};

.security = .{
    .permissions = &app_permissions,
    .navigation = .{ .allowed_origins = &.{ "zero://app" } },
},
.builtin_bridge = .{
    .enabled = true,
    .commands = &.{
        .{ .name = "native-sdk.window.create", .permissions = .{ "window" }, .origins = .{ "zero://app" } },
        .{ .name = "native-sdk.webview.create", .permissions = .{ "window" }, .origins = .{ "zero://app" } },
        .{ .name = "native-sdk.dialog.openFile", .origins = .{ "zero://app" } },
    },
},
```

`js_window_api = true` exposes `window.zero.windows.*` and `window.zero.webviews.*`, but it does not bypass origin or permission checks.

## Windows from JavaScript

```javascript
const win = await window.zero.windows.create({
  label: "tools",
  title: "Tools",
  width: 420,
  height: 320,
});

const all = await window.zero.windows.list();
await window.zero.windows.focus(win.id);
await window.zero.windows.close(win.id);
```

Window state persistence uses stable labels. Use meaningful labels like `main`, `settings`, `tools`, or `preview`.

## Layered WebViews

Child WebViews are native WebViews layered inside a native window:

```javascript
const preview = await window.zero.webviews.create({
  label: "preview",
  url: "https://example.com",
  frame: { x: 24, y: 24, width: 480, height: 320 },
  layer: 10,
  bridge: false,
});

await preview.setZoom(1.25);
await preview.setLayer(20);
await preview.close();
```

Rules:

- WebView URLs must pass navigation policy.
- Commands target only the calling native window.
- `main` is reserved for the startup WebView.
- Child WebViews receive `window.zero` only with `bridge: true`.
- Backend gaps should reject with `invalid_request`.

## Dialogs

Dialogs require explicit `builtin_bridge` policy.

```javascript
const files = await window.zero.invoke("native-sdk.dialog.openFile", {
  title: "Select a file",
  defaultPath: "/home",
  allowMultiple: true,
  allowDirectories: false,
});

const path = await window.zero.invoke("native-sdk.dialog.saveFile", {
  title: "Save as",
  defaultName: "untitled.txt",
});

const result = await window.zero.invoke("native-sdk.dialog.showMessage", {
  style: "warning",
  title: "Confirm",
  message: "Delete this item?",
  primaryButton: "Delete",
  secondaryButton: "Cancel",
});
```

Use native dialogs for trusted app UI. Do not expose arbitrary filesystem access to remote or untrusted origins.

## Error handling

JavaScript bridge calls reject with `error.code`:

- `invalid_request`: malformed input, unsupported operation, denied navigation URL, missing target, duplicate/reserved label.
- `unknown_command`: no registered handler.
- `permission_denied`: origin or permission failed.
- `handler_failed`: handler returned an error.
- `payload_too_large`: request too large.
- `internal_error`: unexpected runtime failure.

Always handle errors in frontend code:

```javascript
try {
  await window.zero.invoke("native.save", payload);
} catch (error) {
  console.error(error.code, error.message);
}
```


---
# references/frontend-assets.md

# Frontend and Assets

Use this when working with React, Vue, Svelte, Next.js, Vite, dev servers, HMR, static assets, or packaged frontend output.

## Recommended source pattern

Framework apps should use a dynamic source:

```zig
fn source(context: *anyopaque) anyerror!native_sdk.WebViewSource {
    const self: *App = @ptrCast(@alignCast(context));
    return native_sdk.frontend.sourceFromEnv(self.env_map, .{
        .dist = "frontend/dist",
        .entry = "index.html",
    });
}
```

`sourceFromEnv` checks `NATIVE_SDK_FRONTEND_URL`. If set, the WebView loads the dev server URL. If not set, it serves packaged assets from `dist`.

## Manifest frontend config

```zig
.frontend = .{
    .dist = "frontend/dist",
    .entry = "index.html",
    .spa_fallback = true,
    .dev = .{
        .url = "http://127.0.0.1:5173/",
        .command = .{ "npm", "--prefix", "frontend", "run", "dev", "--", "--host", "127.0.0.1" },
        .ready_path = "/",
        .timeout_ms = 30000,
    },
},
```

Fields:

- `dist`: built frontend output path.
- `entry`: HTML entry file within `dist`.
- `spa_fallback`: serve `entry` for unknown routes.
- `dev.url`: local dev server URL.
- `dev.command`: command the Native SDK can spawn.
- `dev.ready_path`: path to poll for readiness.
- `dev.timeout_ms`: readiness timeout.

## Dev server workflow

Use:

```bash
zig build dev
```

Or directly:

```bash
native dev --manifest app.zon --binary zig-out/bin/MyApp
```

The dev command starts the frontend process, waits for readiness, sets `NATIVE_SDK_FRONTEND_URL`, launches the native shell, and terminates the frontend when the shell exits.

Framework defaults:

- Vite, React, Vue, Svelte: `http://127.0.0.1:5173/`, command `npm run dev -- --host 127.0.0.1`.
- Next.js: `http://127.0.0.1:3000/`, command `npm run dev -- --hostname 127.0.0.1`.

## Production assets

For packaged builds, serve local assets from `zero://app`:

```zig
return native_sdk.frontend.productionSource(.{
    .dist = "frontend/dist",
    .entry = "index.html",
});
```

The package/build flow should build the frontend before packaging. `zig build bundle-assets` and `native bundle-assets` copy the configured dist directory into build/package output.

## Security and frontend origins

Add exact origins to `security.navigation.allowed_origins`:

```zig
.security = .{
    .navigation = .{
        .allowed_origins = .{
            "zero://app",
            "http://127.0.0.1:5173",
        },
    },
},
```

Use `zero://inline` only for inline examples. Do not allow `"*"` for production navigation.

For packaged HTML, start with a strict CSP:

```html
<meta http-equiv="Content-Security-Policy"
  content="default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'">
```

For dev servers, keep development CSP separate and add only the local dev/WebSocket endpoints required by the framework.

## Frontend to native calls

Use:

```javascript
const result = await window.zero.invoke("native.ping", { source: "webview" });
```

For builtin windows/WebViews helpers, enable `js_window_api` and policy in the runner. For custom commands, register handlers in Zig and allow the command in policy.

## Example projects

- `examples/next`: Next.js app with production assets under `frontend/out`.
- `examples/react`: React with Vite.
- `examples/svelte`: Svelte with Vite.
- `examples/vue`: Vue with Vite.

When unsure about frontend build commands or output directories, inspect the matching example before editing.


---
# references/project-anatomy.md

# Project Anatomy

Use this when creating, orienting in, or restructuring a Native SDK app.

## Generated project files

A zero-config app ships no build files at all — just `app.zon` + `src/` (+ `assets/`); the `native dev|test|build` verbs synthesize the build graph into `.native/build/` (gitignored). `build.zig`/`build.zig.zon` appear only in apps that own their build (`native eject`, the `--full` scaffold, or an expanded example):

- `build.zig`: Zig build graph. Expanded scaffolds expose platform selection, trace mode, debug overlay, automation, JS bridge, web engine overrides, frontend install/build/dev steps, tests, and package steps.
- `build.zig.zon`: Zig package manifest and dependency declaration.
- `app.zon`: app manifest read by CLI/build/package/doctor tooling.
- `src/main.zig`: app state, `app()` method, source resolver, optional bridge dispatcher, lifecycle callbacks.
- `src/runner.zig`: platform and runtime setup: native backend, trace sinks, panic capture, log paths, state store, security policy, builtin bridge policy, automation.
- `assets/`: icons and other package resources.
- `frontend/`: framework app when using Next, Vite, React, Svelte, or Vue.

## app.zon responsibilities

Keep product-level metadata and policies in `app.zon`:

```zig
.{
    .id = "com.example.my-app",
    .name = "my-app",
    .display_name = "My App",
    .version = "0.1.0",
    .icons = .{"assets/icon.png"},
    .platforms = .{ "macos", "linux" },
    .permissions = .{ "window" },
    .capabilities = .{ "webview", "js_bridge" },
    .bridge = .{
        .commands = .{
            .{ .name = "native.ping", .origins = .{ "zero://app" } },
        },
    },
    .security = .{
        .navigation = .{
            .allowed_origins = .{ "zero://app", "http://127.0.0.1:5173" },
            .external_links = .{ .action = "deny" },
        },
    },
    .frontend = .{
        .dist = "frontend/dist",
        .entry = "index.html",
        .spa_fallback = true,
        .dev = .{
            .url = "http://127.0.0.1:5173/",
            .command = .{ "npm", "--prefix", "frontend", "run", "dev", "--", "--host", "127.0.0.1" },
            .ready_path = "/",
            .timeout_ms = 30000,
        },
    },
    .web_engine = "system",
    .windows = .{
        .{ .label = "main", .title = "My App", .width = 960, .height = 640, .restore_state = true },
    },
}
```

Important manifest fields:

- `id`: reverse-DNS bundle identifier. Used for bundle metadata and log/state paths.
- `name`: short machine name.
- `display_name`: human app name — shown by the application menu, Dock, app switcher, and About panel in dev runs and packaged bundles alike.
- `description`: optional one-line About-panel description (max 256 bytes, single line).
- `version`: package and bundle version — also shown in the About panel.
- `icons`: package resources.
- `platforms`: package targets.
- `permissions`: runtime grants checked by bridge and builtin commands.
- `capabilities`: broad feature declarations.
- `bridge.commands`: app-defined command allowlist.
- `security.navigation.allowed_origins`: main-frame navigation allowlist.
- `security.navigation.external_links`: external link policy.
- `frontend`: production asset and dev server config.
- `web_engine`: `system` or `chromium`.
- `cef`: CEF layout config for Chromium.
- `windows`: initial window definitions.

## Build steps to know

Common generated steps:

```bash
zig build run
zig build dev
zig build test
zig build package
zig build frontend-install
zig build frontend-build
```

Repository-level useful steps:

```bash
zig build test
zig build test-tooling
zig build test-webview-smoke -Dplatform=macos
zig build test-package-cef-layout -Dplatform=macos
```

## Layering rule

- If changing app identity, packaging inputs, permissions, origins, windows, frontend dist/dev paths, or web engine, update `app.zon`.
- If changing runtime services, platform setup, automation, logging, security wiring, or builtin bridge policy, update `src/runner.zig`.
- If changing native business behavior, lifecycle callbacks, bridge handlers, or source selection, update `src/main.zig`.
- If changing UI, routes, CSS, or web calls, update `frontend/`.

Do not put package metadata in Zig app state unless the generated project already does that. Do not bypass `app.zon` policy for convenience.


---
# references/web-engines-packaging-debugging.md

# Web Engines, Packaging, and Debugging

Use this when choosing system WebView vs Chromium, installing CEF, packaging, signing, running doctor, finding logs, or debugging runtime behavior.

## Web engine choice

Default:

```zig
.web_engine = "system",
```

System mode:

- Uses the OS web engine.
- macOS: WKWebView.
- Linux: WebKitGTK.
- Smallest app footprint.
- Fastest startup.
- Rendering depends on the user's OS.

Chromium mode:

```zig
.web_engine = "chromium",
.cef = .{ .dir = "third_party/cef/macos", .auto_install = false },
```

Chromium mode:

- Bundles CEF.
- Gives predictable Chromium behavior.
- Increases package size and startup cost.
- Requires matching CEF layout at build and package time.

Use Chromium when the product needs a pinned web platform, complex frontend rendering consistency, or Chromium-only behavior. Otherwise prefer `system`.

## CEF setup

Install the prepared runtime:

```bash
native cef install
native doctor --manifest app.zon
```

Pin CEF in app setup or CI when reproducibility matters:

```bash
native cef install --version <version>
```

Useful overrides:

```bash
zig build run -Dweb-engine=chromium -Dcef-dir=third_party/cef/macos
zig build run -Dweb-engine=chromium -Dcef-auto-install=true
native package --web-engine chromium --cef-dir third_party/cef/macos
```

Normal product configuration should live in `app.zon`; CLI/build flags are for temporary overrides.

## Packaging

Simple path:

```bash
zig build package
```

CLI path:

```bash
native package --target macos --manifest app.zon --binary zig-out/bin/MyApp
```

Important package manifest fields:

- `id`: bundle ID, desktop ID, log/state prefix.
- `display_name`: app/menu/window title fallback.
- `version`: package metadata.
- `icons`: copied into package resources.
- `platforms`: intended package targets.
- `frontend`: asset directory and entry file.
- `web_engine` and `cef`: engine and Chromium runtime config.

For frontend apps, package the built frontend assets. The build step usually wires this automatically. If using CLI directly, pass `--assets frontend/dist`.

## macOS packages

`zig build package` creates a `.app` bundle with:

- `Contents/MacOS/<binary>`
- `Contents/Resources/AppIcon.icns` (generated from the square `assets/icon.png`/`.svg` source in `.icons`; a prebuilt `.icns` ships untouched under its own name)
- `Contents/Info.plist`
- `Contents/Resources/dist/` when frontend assets are configured
- `Contents/Frameworks/Chromium Embedded Framework.framework` for Chromium apps

macOS minimum system version is 11.0.

Signing modes:

```bash
native package --target macos --signing none
native package --target macos --signing adhoc
native package --target macos --signing identity --identity "Developer ID Application: Your Name"
```

For Chromium apps, verify the CEF framework and resources are included and signed before notarization.

## Linux and Windows packages

Linux creates an install tree with:

- `bin/<name>`
- `share/applications/<name>.desktop`
- icons under `share/icons/hicolor/...`

Windows packaging is early support and creates a directory-based distributable layout.

Shortcut commands:

```bash
native package-linux --binary zig-out/bin/MyApp
native package-windows --binary zig-out/bin/MyApp.exe
```

## Doctor and validation

Validate manifest schema:

```bash
native validate app.zon
```

Check environment and package readiness:

```bash
native doctor
native doctor --manifest app.zon --strict
native doctor --manifest app.zon --web-engine chromium --cef-dir third_party/cef/macos
```

Doctor checks:

- host platform
- WebView availability
- manifest validity
- log directory writability
- CEF layout when Chromium is selected
- signing tools

Use `--strict` in CI or before release so warnings fail the command.

## Debugging

Trace modes:

- `off`
- `events`
- `runtime`
- `all`

Build/run flags commonly include:

```bash
zig build run -Dtrace=all
zig build run-webview -Ddebug-overlay=true
```

Log defaults:

- macOS: `~/Library/Logs/<bundle-id>/native-sdk.jsonl`
- Linux: `~/.local/state/<bundle-id>/logs/native-sdk.jsonl`
- Windows: `%LOCALAPPDATA%\<bundle-id>\Logs\native-sdk.jsonl`

Environment variables:

```bash
NATIVE_SDK_LOG_DIR=/tmp/my-logs zig build run
NATIVE_SDK_LOG_FORMAT=text zig build run
```

Panic capture:

```zig
pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);
```

Generated runners usually install panic capture so crashes write `last-panic.txt` and append a fatal trace record.

## Common failures

- App window opens blank: check `WebViewSource`, `frontend.dist`, `frontend.entry`, and allowed origins.
- Dev server never loads: check `app.zon frontend.dev.url`, command, readiness path, and `NATIVE_SDK_FRONTEND_URL`.
- Bridge call rejects with `permission_denied`: check command origin and permissions in policy.
- Bridge call rejects with `unknown_command`: handler was not registered or command name differs.
- Chromium app fails at launch: check CEF layout, version mismatch, bundle Frameworks layout, and signing.
- Package misses frontend: check `frontend.dist`, frontend build step, and `--assets`.
