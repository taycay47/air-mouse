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

One-time setup:

1. In Raycast, go to your account's developer settings and generate a
   Personal Access Token for publishing.
2. Add it as a repo secret named `RAYCAST_TOKEN`:
   ```bash
   gh secret set RAYCAST_TOKEN
   ```
3. The first submission should be done locally (`npm run publish` from this
   directory) so you can walk through Raycast's review checklist
   interactively. After that initial PR is merged, pushes to `main` that
   touch `air-mouse/**` trigger
   [`.github/workflows/raycast-publish.yml`](../.github/workflows/raycast-publish.yml),
   which opens/updates the PR automatically — Raycast's human review is the
   one step that stays manual.

Double-check `npx ray publish`'s current auth flag/env var against
[Raycast's own docs](https://developers.raycast.com/basics/publish-an-extension)
before relying on the CI workflow — verify this, don't just trust the
comment in the workflow file, since Raycast has changed this mechanism
before and I couldn't verify the exact current shape of it from here.
