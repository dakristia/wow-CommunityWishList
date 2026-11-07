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
| `Mail.lua` | `ns.Mail`: the mail slice (prepare a send, detect sent and received mail) and its side panel |
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

Every message is a `Codec`-serialized table with `p = 1` (protocol version) and `k` (kind). A receiver drops messages without `p`, ignores kinds it does not know, and ignores unknown fields, so later versions can add to v1. The guild is one scope; groups add more, as described under "Sync over groups".

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

## Groups

`docs/adr/0002-group-sync-over-hidden-channels.md` explains the transport. `GLOSSARY.md` defines group, creator, invite and member.

### Group record

```lua
db.groups[groupId] = {
    id = "Thrall-Area52:12",   -- creator .. ":" .. seq (the same seq counter as wishes)
    name = "Raid team",         -- 1 to 32 chars, control chars stripped
    creator = "Thrall-Area52",
    key = "k7Qx2p9LmA3z",       -- channel password, 12 random letters and digits, set at creation
    v = 1,                      -- creator's version: +1 on rename or removal
    members = {
        ["Thrall-Area52"] = { state = "joined", v = 1, by = "Thrall-Area52" },
        ["Jaina-Area52"]  = { state = "invited", v = 1, by = "Thrall-Area52" },
    },
}
```

Member states and who may set them:

| state | rank | set by |
|-------|------|--------|
| invited | 0 | any joined member |
| joined | 1 | the member itself, from invited |
| left | 2 | the member itself, from joined or invited (declining) |
| removed | 3 | the creator, from any state |

Every member change sets `v` to the entry's old `v + 1` and `by` to the author. Merging two copies of an entry keeps the one with the higher `v`; on a tie, the higher rank. Re-inviting a left or removed member is a new change with a higher `v`, so it wins. A group holds at most 40 entries in `invited` or `joined`. The creator cannot leave or be removed. Merging the body (`name`) keeps the copy with the higher group `v`; `key`, `creator` and `id` never change.

`Merge` validates: `by` must be a member of the copy being merged for `invited`, equal to the member for `joined` and `left`, and equal to `creator` for `removed`. An entry that breaks the rule is ignored.

### Groups API

`ns.Groups.new{ db, me, now, random }` (`random()` returns a float in [0, 1); `math.random` in WoW). Methods return `nil, "reason"` on a rule break and never raise an error. Each change calls the listeners with `kind` `"group"`.

| Method | Who may |
|--------|---------|
| `Create(name)` → group | anyone; the creator starts as `joined` |
| `Invite(groupId, name)` | a joined member; fails at 40 or when already joined |
| `Accept(groupId)` | me, while invited |
| `Leave(groupId)` | me, while invited or joined; not the creator |
| `Remove(groupId, name)` | the creator |
| `Rename(groupId, name)` | the creator |
| `Get(id)`, `List()` (my groups: me joined or invited), `IsMember(groupId, name)` (joined), `Members(groupId)` (joined, sorted) | |
| `Merge(remoteGroup)` → changed | |
| `Sig(groupId)` → `v .. "." .. hash of sorted "name=v.rank" member entries` | |
| `OnChange(fn(kind, group))` | |

### Wishes for groups

`Store:AddWish{ ..., guild = bool, groups = { groupId, ... } }` stores `audience.groups = { [groupId] = true }` for the groups where I am joined (Store gets `opts.isMember(groupId)`). It fails when the result has no guild and no group. A wish can target the guild and groups at once.

### Sync over groups

`Sync` serves several **scopes**. The guild is one scope; each joined group is another. A scope is `{ id, channel, target, includes(wish), accepts(sender) }`:

- Guild: `channel = "GUILD"`, `includes` = `audience.guild == guild()`, `accepts` = anyone.
- Group: `channel = "CHANNEL"`, `target` = the channel number from `GetChannelName(channelName)`, `includes` = `audience.groups[groupId]`, `accepts(sender)` = `Groups:IsMember(groupId, sender)`.

Every group message carries `g = groupId`. A receiver drops a group message when it does not know the group, I am not joined, or the sender is not a joined member. `H`, `W` and `R` work per scope exactly as for the guild. A wish in two scopes is answered and relayed separately in each, and dedupe is per scope.

New kinds (version 1 clients ignore them):

| Kind | Fields | Where | Sent when |
|------|--------|-------|-----------|
| `G` group | `r` = group record in wire form, without `key` | the group's channel | after every local group change, and in answer to `H` when `gs` differs |
| `I` invite | `r` = group record **with** `key` | `WHISPER` to the invitee | on `Invite` |
| `A` accepted | `g`, `r` = group record | `WHISPER` to the inviter | on `Accept`, in case the channel is not joined yet |

`H` on a group channel also carries `gs` = my `Sig(groupId)`. A peer whose `Sig` differs answers with `G` after the same jitter as wishes.

Channel name: `"CWL" .. base36(djb2(groupId))`, at most 31 characters. Init joins the channel with `JoinTemporaryChannel(name, key)` for every group where I am joined, removes it from every chat window, leaves it on `Leave` or `removed`, and starts the scope's `H` once `GetChannelName` returns a number.

An `I` from a character opens a confirmation popup ("<name> invites you to the group <group>. Join?"). It never joins on its own. An `I` for a group I already joined only merges the record.

## Notify

- When a `"claim_new"` change arrives for a wish whose owner is `me` and the claim is not in `db.seen`, `Notify` alerts and adds the claim to `seen`. The alert is a chat line, `"Jaina will send you 40 x [Peacebloom]"`, plus a sound and a line in `UIErrorsFrame`.
- After login, once the first sync settles (10 seconds after `Start`), it alerts for unseen claims in one summary line.
- When I claim, and the wisher's recipient or owner is online in the guild roster, it whispers `"I will send you 40 x [Peacebloom] (CommunityWishList)"`. When I mark a claim sent, it whispers `"I have sent you ..."` in the same way.

## Mail

`ns.Mail.new{ store, me, api }` holds the mail rules. `api` is a table of the WoW functions it calls, so tests pass fakes and `Init.lua` passes the real ones. `Init.lua` registers `MAIL_SHOW`, `MAIL_CLOSED`, `MAIL_SEND_SUCCESS` and `MAIL_FAILED`, and hooks `SendMail`, `TakeInboxItem` and `AutoLootMailItem`.

- `ClaimsToSend()` lists my open claims on open wishes, grouped by recipient, oldest first.
- `Prepare(wishId, claimId)` opens the send tab, fills the recipient and the subject `"CommunityWishList: <qty> x <item>"`, and attaches whole bag stacks of the item. It takes the largest stacks that still fit under the claim quantity. Attaching is best effort: each attach runs in `pcall`, and when none fits the player attaches by hand.
- Auto-sent: `OnSendMail` (the `SendMail` hook) records the recipient and the attachments. On `MAIL_SEND_SUCCESS`, my open claims for those items whose wish recipient or owner is that recipient become `sent`, oldest first, while the sent count covers the claim quantity. `MAIL_FAILED` drops the record.
- Auto-received: when I take mail (`TakeInboxItem` or `AutoLootMailItem`) as the owner or recipient of a wish, the sender's `sent` claims for the taken item become `received`, oldest first, while the taken count covers them.

`ns.Mail.CreatePanel(mail)` builds a small panel on the right of `MailFrame`. It lists `ClaimsToSend()` with a "Mail it" button that calls `Prepare`, and it says "Nothing to send." when the list is empty. `Init.lua` creates it on the first `MAIL_SHOW` and shows and hides it with the mail window.

## UI

`CommunityWishListFrame`, a movable window that saves its position in `db.ui`. `/cwl` and `/wishlist` toggle it. `/cwl add <qty> <item link or name>` adds a guild wish from chat, and `/cwl help` lists the commands. It has four tabs:

- **Wishes**: every open wish from others. A row shows the item icon and link, remaining and wanted quantity, wisher, note, gold, priority and a Claim button. Claim asks for a quantity and defaults to the remaining amount.
- **My wishes**: my wishes with their claims (claimer, quantity, state, age), and Close, Delete, Release and Received buttons. An add form sits on top. Typing at least two characters searches ItemDB and shows up to eight suggestions with icons and quality colours. Items in bags rank first, then names starting with the query, then other matches, alphabetically within each group. Clicking a suggestion or pressing Enter selects an item and shows its icon and tooltip. A shift-clicked link or dragged item also selects it. Editing clears the selection. Escape or losing focus hides suggestions. Add uses the selection or resolves an exact name or item link, and stores the real item name. An unresolved item shows "Pick an item from the list, or shift-click an item link." and adds nothing. `/cwl add` uses the same resolution and error.
- **My claims**: my claims with Mark sent and Cancel buttons.
- **Groups**: a placeholder that says groups come in a later version.

The window uses native portrait chrome, top tabs and a textured inset. The search box filters Wishes, My wishes and My claims by item name, wisher short name or note, without case sensitivity. LibDBIcon owns the minimap launcher's position and visibility settings.

The UI talks to the store and `Items`. It refreshes on every store change. `Items` looks up ItemDB lazily and returns empty results when the library is missing or not ready.
