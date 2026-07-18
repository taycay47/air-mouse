# Air Mouse (Raycast Extension)

Starts/stops the [Air Mouse](../README.md) server and shows the pairing QR
code + PIN, from Raycast instead of the menu bar app.

## Local development

```bash
npm install
npm run dev   # ray develop
```

It auto-detects the repo it lives in (walks up from its own source location
looking for a sibling `mouse_controller.py`). If you ever install this
extension separately from the server, set the **Air Mouse Server Directory**
preference to override that.

## Publishing to the Raycast Store

There's no CI automation for this — `npm run publish` (i.e. `npx @raycast/api@latest publish`)
is designed to run locally and interactively. It opens a browser for GitHub
auth, forks [raycast/extensions](https://github.com/raycast/extensions) under
your account if needed, and opens a PR there. That PR then goes through
Raycast's human review.

(The `raycast/github-actions` CI action and `RAYCAST_ORGANIZATION_TOKEN` you
might find in Raycast's docs/templates are for **private team extensions**,
a different product — not applicable to a public Store submission like this
one.)

Before running it:

```bash
cd air-mouse
npm run lint     # fails the build on the same checks the Store review does
npm run build    # confirms it compiles clean
npm run publish
```

For subsequent updates, just run `npm run publish` again from a clean `main`.
