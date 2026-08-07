# Upstream report for ubavic/srb-id-pkcs11 (v0.5.0)

Text prepared for filing GitHub issues (or one combined issue + PR with the
attached `srb-id-pkcs11-robustness.patch`). Written in English; feel free to
file in Serbian instead — the findings map 1:1 to the patch hunks.

---

## Summary

Using srb-id-pkcs11 v0.5.0 on Linux (Ubuntu 24.04) with a 2026-issued ID card
("SCE 8.0-C2V0" ATR, NetSeT CardEdge token) for **eid.gov.rs browser login**
(Brave/Chromium via NSS) we hit four independent bugs. `pkcs11-tool` works
fine in all cases — every bug only manifests under a real browser's threading
and call patterns, which is why they are easy to miss in testing. All four are
fixed by the attached patch; each fix was verified with a purpose-built
multithreaded harness that mimics Chromium's usage (dlopen + C_Initialize
with CKF_OS_LOCKING_OK + concurrent enumeration/polling threads).

## Bug 1 — C_GetSlotList only refreshes reader state when `slot_list == null`

`p11_slot_and_token.zig`: `refreshStatuses()` runs only in the size-query
branch. Callers that pass a pre-allocated buffer directly (legal per PKCS#11,
and NSS does this) never trigger a refresh. If the module is loaded before
pcscd has enumerated the reader (e.g. browser autostart at session login, or
pcscd socket-activation still warming up), `reader_states` stays empty
**forever**: C_GetSlotList returns `CKR_OK` with 0 slots for the lifetime of
the process, the browser sees no certificates and silently sends no client
cert (the user just gets the portal's error 403 page with no picker shown).

**Fix:** refresh unconditionally in C_GetSlotList (and take `reader.lock`
while doing it — the refresh mutates `reader_states`, which C_GetSlotList
previously accessed without any lock, racing against C_GetTokenInfo's
exclusive-locked refresh of the same hashmap).

## Bug 2 — no PC/SC transactions around multi-APDU sequences

`smart-card.zig` issues multi-APDU sequences (SELECT + chained READ BINARY
for certificates; MSE SET + PSO for signing; applet select + file select +
read for token info) over `SCARD_SHARE_SHARED` connections without
`SCardBeginTransaction`. Any other PC/SC client running concurrently — the
browser's own slot-polling thread using a second connection, gsd-smartcard,
OpenSC registered in the same NSS db, another app — interleaves APDUs into
the middle of the sequence. Besides corrupting the card's logical state
(selected file), on common flaky readers (built-in Realtek 0bda:0169) the
interleaving kills the T=1 state machine outright: pcscd logs
`CCID_Receive() Can't read all data` → `T=1 state machine is DEAD`, and the
card stops responding until physically reinserted. Reproduced deterministically
by running two concurrent `pkcs11-tool` loops (6/10 operations failed);
with transactions, 0 failures in 90+ concurrent operations.

**Fix:** wrap every card operation in `SCardBeginTransaction`/`SCardEndTransaction`
(pcsc-z already exposes `Card.transaction()`).

## Bug 3 — transactions + concurrent SCardConnect self-deadlock in-process

Adding transactions alone introduces a deadlock: libpcsclite serializes all
calls of one process behind a single internal mutex, and pcscd parks
`SCardConnect` while any connection holds a transaction. So: thread A begins
a transaction and wants to transmit; thread B (slot polling) calls
`SCardConnect`, which blocks server-side **while holding libpcsclite's
mutex**; thread A's `SCardTransmit` now blocks on that mutex; pcscd waits for
A to finish the transaction before answering B. Permanent deadlock, captured
with gdb stack traces (available on request).

**Fix:** a process-wide lock (`card_ops_busy` in the patch) serializing every
PC/SC interaction of the module — connects, transacted operations, and
disconnects — so a connect can never overlap a transaction held by another
thread of the same process. Cross-process safety still comes from the
transactions themselves.

## Bug 4 — stale handles after card reset are not recovered (CKR_DEVICE_ERROR)

A browser session opens its PC/SC connection at C_OpenSession time and then
sits idle for minutes while the user browses and eventually types the PIN.
If the card is reset/re-powered in the meantime (any other client, pcscd
power management), PC/SC fails the next use of the old handle with
`SCARD_W_RESET_CARD`/`SCARD_W_UNPOWERED_CARD`. `pkcs_error.formPCSC` maps
these to `CKR_DEVICE_ERROR` and the operation is abandoned — in practice
**C_Login fails with CKR_DEVICE_ERROR** and Chromium reports
`ERR_SSL_CLIENT_AUTH_SIGNATURE_FAILED`. Reproduced without a PIN via
C_GenerateRandom on a session handle left idle for 60 s while another thread
polls the token: `CKR_DEVICE_ERROR` before the fix, `CKR_OK` after.

**Fix:** on `ResetCard`/`UnpoweredCard` during transmit, `SCardReconnect`
(LEAVE), re-select the PKCS#15 applet (the reset cleared card state), and
retry the APDU once. This is what Windows middlewares do and is why the same
card works out-of-the-box there.

## Environment (for reproduction)

- Ubuntu 24.04, pcscd 2.0.3, libccid, Brave (Chromium 151) via NSS user db
- ID card issued 2026-06 ("SCE 8.0-C2V0" ATR: `3B 9E 96 80 31 FE 45 53 43
  45 20 38 2E 30 2D 43 32 56 30 0D 0A 6C`), NetSeT CardEdge SSCD v1 token
- Built-in Realtek 0bda:0169 combo reader (smart card + SD). Worth noting in
  the README: the SD interface's kernel polling corrupts CCID transfers on
  this reader; unbinding usb-storage from that interface fixes it.
