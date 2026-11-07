# Every client caches and relays all wishes, and the wisher's version wins

Addon messages only reach players who are online, but most mail goes to players who are offline. So every client keeps an account-wide cache of every wish it has seen and relays it to members who log in later. This way a wish stays visible and claimable while its wisher is offline.

Each wish carries a version number that only the wisher increments, and the higher version always replaces the lower one. Claims carry no version. Instead each claim only moves forward through its states (open, then sent, then received, or open, then cancelled or released), so two copies merge by taking the later state. Any member could relay a forged copy with a higher version. We accept that because a guild or a friend group gains nothing from forging a wish list.

## Considered options

- **Online only.** Only wishes of players who are online are visible. This was rejected because you could rarely help a wisher who is offline.
- **Owner-only data.** No relaying, so a wish travels only from its wisher. This was rejected because it brings back most of the offline problem.

## Consequences

Every message carries a protocol version from the first release. Old clients stay in the network as relays, so a newer version must still read and write what version 1 understands.
