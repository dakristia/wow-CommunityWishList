# CommunityWishList design

This is the contract between the modules. `GLOSSARY.md` defines the words. `docs/adr/0001-cache-and-relay-sync.md` explains why sync works the way it does.

Target client: WoW: Forever (`## Interface: 16001`). Use `C_ChatInfo.SendChatMessage` and `C_Item.GetItemInfo`, because the old globals `SendChatMessage` and `GetItemInfo` do not exist there.

ItemDB is a required addon dependency. It provides item names, links and search through `LibItemDB-1.0`.

## Files and load order

| File | Owns |
|------|------|
| `Core.lua` | Namespace, `CommunityWishList` global, small helpers (`ns.FullName`, `ns.Print`) |
| `Items.lua` | `ns.Items`: ItemDB search, exact-name and link resolution, icons, links and quality |
| `Codec.lua` | `ns.Codec`: serialize and deserialize plain tables |
| `Store.lua` | `ns.Store`: wishes, claims, merge, digest |
| `Comm.lua` | `ns.Comm`: chunking, reassembly, throttled send queue |
| `Sync.lua` | `ns.Sync`: the guild protocol on top of `Store` and `Comm` |
| `Notify.lua` | `ns.Notify`: claim alerts, whispers |
| `UI.lua` | `CommunityWishListFrame` and its tabs |
| `Minimap.lua` | The minimap button |
| `Init.lua` | Wires everything to real WoW APIs, events and slash commands |

Every file starts with `local _, ns = ...`. `Core.lua` sets the global `CommunityWishList = ns`, so tests and other addons reach the modules. No module except `Init.lua` touches events, `CommunityWishListDB` or real network APIs directly. Store, sync and notification dependencies are passed in, so tests can run two stores and a fake network in one Lua state. `Items` uses ItemDB, `C_Container` and `C_Item` directly.

Code style follows `src/TodoList/TodoList.lua`: 4-space indent, `local` functions, short comments only where the code needs a reason.

## Identity

A character is always written as `Name-Realm`, for example `Thrall-Area52`. `ns.FullName(name)` appends `-` plus `GetNormalizedRealmName()` when the name has no `-`. Every name that enters the store goes through it.

## Saved variables

`CommunityWishListDB` is account-wide, so alts share the cache.

```lua
CommunityWishListDB = {
    schema = 1,
    wishes = { [wishId] = wish },  -- the cache, including tombstones
    seq = { ["Name-Realm"] = n },  -- last used wish/claim number per character
    seen = { [claimId] = true },   -- claims the wisher has already been alerted about
    ui = { point = "CENTER", x = 0, y = 0, tab = "wishes", minimap = { minimapPos = 200 } },
}
```

## Wish and claim

```lua
wish = {
    id = "Thrall-Area52:7",     -- owner .. ":" .. seq
    owner = "Thrall-Area52",
    recipient = "Thrall-Area52", -- defaults to owner
    item = 2447,                 -- itemID, or nil when only a name is known
    name = "Peacebloom",         -- always set, used when item is nil
    qty = 200,
    note = "for alchemy",        -- optional, max 120 chars, control chars stripped
    gold = 0,                    -- optional offer, in copper
    prio = 2,                    -- 1 low, 2 normal, 3 urgent
    audience = { guild = "Horde Heroes", groups = {} }, -- guild name, or nil for no guild
    state = "open",              -- "open" | "closed" | "deleted"
    v = 1,                       -- wisher's version, +1 on every wisher change
    created = 1730000000,
    modified = 1730000000,
    claims = { [claimId] = claim },
}

claim = {
    id = "Jaina-Area52:3",       -- claimer .. ":" .. seq
    by = "Jaina-Area52",
    qty = 40,                    -- fixed at creation
    state = "open",              -- see ranks below
    created = 1730000100,
    sentAt = nil,
    receivedAt = nil,
}
```

A deleted wish is a tombstone. It keeps `id`, `owner`, `state`, `v` and `modified` and drops the rest, so a relay cannot bring it back.

### Claim state merge

Claim states only move forward. Merging two copies of a claim keeps the state with the higher rank, and copies `sentAt` and `receivedAt` from whichever copy has them.

| state | rank | set by |
|-------|------|--------|
| open | 0 | claimer, on creation |
| released | 1 | wisher |
| cancelled | 2 | claimer |
| sent | 3 | claimer |
| received | 4 | wisher |

`sent` outranks `cancelled` and `released`, because the mail physically went out.

### Wish merge

For the wish body, the copy with the higher `v` wins entirely, except `claims`. Claims always merge one by one, as described above, whatever `v` says. A claim that exists only on one side is added.

### Quantities

- `Store:SentQty(wish)` is the sum of `qty` over claims in `sent` or `received`.
- `Store:ClaimedQty(wish)` is the sum of `qty` over claims in `open`, `sent` or `received`.
- `Store:Remaining(wish)` is `max(0, wish.qty - ClaimedQty(wish))`.
- A wish is filled when `SentQty >= qty`. When the wisher's own store sees that its wish is filled, it sets `state = "closed"` and bumps `v`. Other stores only display it as filled.

## Store API

`ns.Store.new(opts)` returns a store. `opts`:

- `db`: the table to keep data in (the `CommunityWishListDB` shape above). Missing fields are created.
- `me`: the current character, `Name-Realm`.
- `now`: function returning seconds (`time` in WoW).
- `guild`: function returning the current guild name, or nil.

Methods. Each one validates its input and returns `nil, "reason"` on a rule break, never raising an error. Each successful change calls the change listeners.

| Method | Who may | Returns |
|--------|---------|---------|
| `AddWish{ item, name, qty, note, gold, prio, guild = bool, recipient }` | anyone | wish |
| `UpdateWish(id, fields)` (note, qty, gold, prio, recipient) | owner | wish |
| `CloseWish(id)` | owner | wish |
| `DeleteWish(id)` | owner | wish (tombstone) |
| `Claim(id, qty)` | anyone but the owner, 1 ≤ qty ≤ Remaining, wish open | claim, wish |
| `CancelClaim(wishId, claimId)` | claimer, claim open | claim, wish |
| `MarkSent(wishId, claimId)` | claimer, claim open | claim, wish |
| `ReleaseClaim(wishId, claimId)` | owner, claim open | claim, wish |
| `MarkReceived(wishId, claimId)` | owner, claim sent | claim, wish |
| `Get(id)` | | wish or nil |
| `List(filter)` | | array of wishes, newest first. Filter keys: `owner`, `claimer` (has a claim by that character), `state`, `includeDeleted` (default false) |
| `Merge(remoteWish)` | | true when anything changed |
| `Digest(predicate)` | | `{ [id] = sig }` for wishes where `predicate(wish)` is true |
| `OnChange(fn)` | | registers `fn(kind, wish, claim)` |

`AddWish` with `guild = true` stores `audience.guild = opts.guild()`. It fails when the character has no guild and no groups are given.

Change kinds passed to listeners:

- `"wish"`: a wish was added or its body changed.
- `"claim_new"`: a claim was added, locally or through `Merge`.
- `"claim_state"`: a claim's state changed.

`Merge` fires the same kinds as local changes. It never trusts its input: it ignores fields with the wrong type, wishes without `id` or `owner`, claims whose `id` does not start with `by .. ":"`, and states that are not in the table above.

`sig` in the digest is `v .. "." .. h`. `h` is a 32-bit hash (djb2 is fine) of the claim list, written as `claimId=rank` pairs sorted by `claimId` and joined with `,`. Two stores with the same `sig` for a wish hold the same wish.

## Codec

`ns.Codec.Serialize(value)` returns a string. `ns.Codec.Deserialize(str)` returns the value, or nil when the input is malformed. It never raises an error, because the input comes from other players. It supports nil-free tables, strings, numbers (integers and floats) and booleans. It refuses nesting deeper than 8 and input longer than 64 KB. The output never contains `"\0"`.

## Comm

`ns.Comm.new(opts)`. `opts`:

- `prefix`: `"CWList"`.
- `send(prefix, text, channel, target)`: returns the `SendAddonMessageResult` code. 0 means success, and 3 (`AddonMessageThrottle`) or 8 (`ChannelThrottle`) means try again later.
- `now()` and `after(seconds, fn)`: a clock and a timer (`GetTime` and `C_Timer.After` in WoW).

Methods: `comm:Send(text, channel, target, priority)` with priority `"high"` or `"bulk"`, `comm:Receive(prefix, text, channel, sender)` and `comm:OnMessage(fn(text, channel, sender))`.

Wire framing: every addon message is `"<i>/<n>/<mid>|<chunk>"` and at most 255 bytes. `mid` is a per-sender counter. Reassembly is keyed by sender and `mid`, drops parts that arrive out of range, and gives up after 30 seconds or more than 64 parts. The send queue allows a burst of 10 messages, then 1 per second, and sends `"high"` before `"bulk"`.

## Sync protocol, version 1

Every message is a `Codec`-serialized table with `p = 1` (protocol version) and `k` (kind). A receiver drops messages without `p`, ignores kinds it does not know, and ignores unknown fields, so later versions can add to v1. Only the guild channel exists in this slice. Groups come later over `WHISPER`.

On the wire, a wish uses short keys so it fits in fewer messages. `Sync` converts with `ToWire` and `FromWire`.

| Kind | Fields | Sent when |
|------|--------|-----------|
| `H` hello | `d` = digest of my guild wishes | at login, after the guild roster is known |
| `W` wish | `w` = one wish in wire form | after every local change, as a relay, and as an answer to `H` or `R` |
| `R` request | `ids` = array of wish ids | after an `H` shows someone has wishes I lack, or newer ones |

Rules:

- Drop messages from myself, because `CHAT_MSG_ADDON` echoes my own guild messages.
- Accept a `W` from the guild channel only when `audience.guild` equals my guild name. Never relay a wish into a channel its audience does not include.
- On `H` from peer A: list the wishes A lacks or holds an older or different `sig` for. Also list the wishes where A's `v` is higher or where `sig` differs, for an `R`. Wait a random 0.5 to 4 seconds. Then drop every wish that someone else already broadcast after the `H` arrived, with a `sig` equal to mine, and every id someone else already requested. Send what is left.
- On `R`: answer with `W` for the ids I have. The owner waits 0 to 0.5 seconds and other peers wait 1 to 4 seconds, and peers skip ids that were answered meanwhile.
- `W` and `R` go out as `"bulk"`, except a `W` for a local change, which goes out as `"high"`.

`ns.Sync.new{ store, comm, me, guild, now, after, random }` returns a sync. Methods: `sync:Start()` (sends `H`), `sync:OnLocalChange(wish)` and the handler that it registers on `comm`.

## Notify

- When a `"claim_new"` change arrives for a wish whose owner is `me` and the claim is not in `db.seen`, `Notify` alerts and adds the claim to `seen`. The alert is a chat line, `"Jaina will send you 40 x [Peacebloom]"`, plus a sound and a line in `UIErrorsFrame`.
- After login, once the first sync settles (10 seconds after `Start`), it alerts for unseen claims in one summary line.
- When I claim, and the wisher's recipient or owner is online in the guild roster, it whispers `"I will send you 40 x [Peacebloom] (CommunityWishList)"`. When I mark a claim sent, it whispers `"I have sent you ..."` in the same way.

## UI

`CommunityWishListFrame`, a movable window that saves its position in `db.ui`. `/cwl` and `/wishlist` toggle it. `/cwl add <qty> <item link or name>` adds a guild wish from chat, and `/cwl help` lists the commands. It has four tabs:

- **Wishes**: every open wish from others. A row shows the item icon and link, remaining and wanted quantity, wisher, note, gold, priority and a Claim button. Claim asks for a quantity and defaults to the remaining amount.
- **My wishes**: my wishes with their claims (claimer, quantity, state, age), and Close, Delete, Release and Received buttons. An add form sits on top. Typing at least two characters searches ItemDB and shows up to eight suggestions with icons and quality colours. Items in bags rank first, then names starting with the query, then other matches, alphabetically within each group. Clicking a suggestion or pressing Enter selects an item and shows its icon and tooltip. A shift-clicked link or dragged item also selects it. Editing clears the selection. Escape or losing focus hides suggestions. Add uses the selection or resolves an exact name or item link, and stores the real item name. An unresolved item shows "Pick an item from the list, or shift-click an item link." and adds nothing. `/cwl add` uses the same resolution and error.
- **My claims**: my claims with Mark sent and Cancel buttons.
- **Groups**: a placeholder that says groups come in a later version.

The window uses native portrait chrome, top tabs and a textured inset. The search box filters Wishes, My wishes and My claims by item name, wisher short name or note, without case sensitivity. LibDBIcon owns the minimap launcher's position and visibility settings.

The UI talks to the store and `Items`. It refreshes on every store change. `Items` looks up ItemDB lazily and returns empty results when the library is missing or not ready.
