# 10. Two channels open at once, not one chosen

**Status:** accepted

## Context

Input reached the Mac over a single TLS WebSocket on TCP — the transport the web
client needed, inherited unchanged when the client went native. On a quiet
network it is fine. On a busy one it stutters: the cursor freezes for a beat and
then jumps to where it should have been.

That signature is head-of-line blocking. TCP guarantees delivery and ordering,
so a single lost packet on a contended access point stalls every packet behind
it until the retransmit lands. For cursor deltas both halves of that guarantee
are wrong. A delta that arrives 150ms late is *worse* than one that never
arrives, because the late one is applied on top of everything since.

Going native also opened three doors the web client could not reach, none of
which had been walked through: Network.framework's socket options, Wi-Fi service
classes, and peer-to-peer links.

## Decision

Open every channel the network allows, at the same time, and route each message
to the best one that suits it.

**Reliable channel.** `ReliableTransport`: Network.framework speaking WebSocket
over pinned TLS, with `noDelay` set (Nagle holds small writes back waiting for
bigger ones — every packet here is small and urgent, exactly the case Nagle
defeats), the voice service class, and peer-to-peer permitted. Falls back to
URLSession's WebSocket, which is kept because it is the most *ordinary* thing on
the network and therefore the most likely to survive one that objects to the
rest. A fallback is only worth having if it differs from what it falls back
from.

**Fast channel.** `DatagramTransport`: DTLS over UDP, carrying `trackpad`,
`scroll` and `motion` only. Authenticated by a pre-shared key issued over the
already-pinned reliable channel, so completing the handshake *is* the
authentication — no second PIN, no replay window, and no need to turn the
server's PEM files into a `SecIdentity`.

Both channels stay up. Falling back costs one assignment rather than a
handshake, which matters because it happens mid-gesture.

## Consequences

**No sequence numbers.** Deltas add, and addition commutes, so movement packets
arriving out of order produce the same cursor position as in-order ones. Only
loss matters, and loss is what this channel exists to accept. Adding sequence
numbers would have meant changing `trackpad`'s shape and every test that asserts
it, to solve a problem the arithmetic already solves.

**Movement returns to the reliable channel while a button is held.** The two
channels have independent latency; a `click`/`down` that lands after the
movement it was meant to precede starts a drag in the wrong place — a selection
from nowhere to somewhere. Inferred from the message stream in `ChannelSet`, so
no other component has to know the rule exists.

**Nothing is routed to UDP on faith.** The fast channel carries nothing until a
`ping` sent over it has been answered over it. A completed DTLS handshake proves
the port is open, not that packets are getting through, and on a network that
silently drops UDP the difference is the whole app. Three unanswered probes in a
row demote it.

**DTLS stops at 1.2.** Network.framework offers no DTLS 1.3, and 1.2 needs an
explicit PSK ciphersuite — `TLS_PSK_WITH_AES_128_GCM_SHA256`, spelled by value
because the Swift enum has no case for it. TLS 1.3 would have folded PSK into
the ordinary suites.

**The peer-to-peer path is a "may", not a "will".** `includePeerToPeer` and a
Bonjour-advertised listener let the system choose a direct AWDL link, bypassing
the access point entirely. It is not guaranteed, and AWDL time-shares the Wi-Fi
radio, so it brings jitter of its own. It is offered alongside the plain port
rather than instead of it.

**Round-trip time is now measured on every channel, once a second.** It exists
to make the routing decision honest — choosing UDP because it is theoretically
faster, without checking, would be a guess dressed as an optimisation. It is
also the first real measurement this app has ever had of its own latency.
