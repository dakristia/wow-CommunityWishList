# Groups sync over one hidden, password-protected chat channel each

A group has no shared addon channel the way a guild does. Whispering every member would work for online members, but the client prints "No player named X is currently playing" for every offline one, and a sender cannot tell who is online outside its guild and friends list. So each group gets a custom chat channel: its name comes from the group id, its password is random and only travels inside invites, and the addon removes the channel from every chat window. The guild sync protocol then runs unchanged over that channel, and whispers carry only the invite itself.

Anyone who learns the channel name and password could listen in. The receiver therefore drops every group message whose sender is not a joined member, so an outsider cannot inject wishes. A removed member still knows the password and could keep listening. We accept that, because rotating the channel on every removal costs a new channel for every member and a friend group's wish list is not secret.

## Considered options

- **Whisper each member.** No channel to manage, but it spams errors for offline members and cannot find out who is online.
- **Rotate the channel on removal.** Stops a removed member from listening, at the cost of every member moving channel. Rejected for now; the protocol carries the channel key in the group record, so a later version can rotate it.

## Consequences

A character in many groups uses one custom channel slot per group, and the client allows only about ten. The group limit of 40 members keeps each channel's traffic close to a small guild's.
