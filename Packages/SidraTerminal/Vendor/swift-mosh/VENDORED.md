# swift-mosh, vendored

Source: https://github.com/wiedymi/swift-mosh, commit 966bd6fc9c7e4a7cf0ff514e313ca1e456e45494, MIT.
Unmodified except that `Package.swift` drops the test target. The UI calls this "mosh-compatible".

## Provenance skim, 2026-11-09 (gate from docs/DECISIONS.md entry 2)

Compared against mobile-shell/mosh master (GPLv3), `src/network/{network.cc,transportsender-impl.h,
transportfragment.cc}` and `src/crypto/{crypto.cc,ocb_internal.cc}`, plus the whole of `src/`.

- 10,301 normalised 8-token windows from `Sources/`: 0 appear anywhere in mosh's `src/`.
- Identical comments longer than 18 characters: 0.
- 14 identifiers shared with mosh's network and crypto files. They are wire-format field names
  (`protocol_version`, `throwaway_num`, `timestamp_reply`), the CommonCrypto API, and plain names
  (`printableKey`, `makeFragments`).
- Structure differs: mosh's `TransportSender<MyState>` diffs terminal states against assumed
  receiver states; this client is an actor with a queue of pending user diffs, RTO retransmit and
  a heartbeat. The ACK timing defaults (3000 ms, 100 ms) match, and they are protocol behaviour.

Result: no sign of translated code. This is an engineering skim, not a legal opinion.
