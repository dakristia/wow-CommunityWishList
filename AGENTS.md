# Agent notes

CommunityWishList is a custom addon. It keeps a shared wish list for a guild and for friend groups: members add wishes, others claim part of a wish and mail the items. It targets WoW Forever (`_forever_`), with `## Interface: 16001`. A Retail TOC exists but is untested. The addon sits in the `CommunityWishList/` subfolder, not at the repo root.

Read `CommunityWishList/docs/design.md` (the module contract), `CommunityWishList/GLOSSARY.md` and `CommunityWishList/docs/adr/` before you change behaviour.

## Where this repo fits

- The hub, `~/source/repos/wow-workspace`, lists this addon in `addons.conf` and deploys it to the game. Read the hub's `CLAUDE.md` before you change anything about deploys, backups or the folder layout.
- The workshop, `~/source/repos/wow-addon-workshop`, runs the tests in wowless, a headless WoW client in Docker.
- The tests live in `tests/CommunityWishList_Tests/`. The test addon prints `PASS`, `FAIL` and `RESULT` lines. `tests/ItemDB/` is a stand-in for the ItemDB library, so the addon's dependency loads in wowless. Deploys leave `tests/` out of the game.

## Commands

```bash
~/source/repos/wow-addon-workshop/bin/test CommunityWishList           # test the main checkout
~/source/repos/wow-addon-workshop/bin/test "$PWD"                      # test the worktree you are in
~/source/repos/wow-workspace/deploy.sh CommunityWishList               # deploy main
~/source/repos/wow-workspace/deploy.sh CommunityWishList --from "$PWD" # deploy this worktree as a dev build
```

After a deploy, the user types `/reload` in the game. A deploy from `main` skips an installed dev build unless you pass `--replace-dev`.

## Rules

- The addon depends on the **ItemDB** addon (`LibStub("LibItemDB-1.0")`), which needs Ace3, VersionCheck-1.0 and LibAceGUIWidgets. Do not vendor ItemDB into this repo, because it is 180 MB. Reach it only through `Items.lua`.
- The libraries in `CommunityWishList/Libs/` are copied from wow-Grudgekeeper. Do not edit them; replace a whole library to update it.
- The sync protocol is versioned (`p = 1`). Clients already in the guild keep relaying old messages, so a change must stay readable by version 1 or bump the version. See `docs/adr/0001-cache-and-relay-sync.md`.
- Everything from another player is untrusted. `Store:Merge` and `Codec.Deserialize` validate their input and never raise an error; keep it that way.
- Only `Init.lua` touches events, saved variables and real network APIs. The other modules take their dependencies as arguments, so the tests can run several stores and a fake network in one Lua state.
- Forever has no global `SendChatMessage` or `GetItemInfo`. Use `C_ChatInfo.SendChatMessage` and `C_Item.GetItemInfo`.
- In wowless, `EditBox:SetText` does not fire `OnTextChanged`, and edit-box focus is not tracked. The UI tests call those handlers directly.
