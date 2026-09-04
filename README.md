# Cocoon Move contracts

The on-chain half of [Cocoon](https://your-cocoon.com), a paid writing session
that ends with an encrypted deliverable. Two packages, both live on Sui mainnet.

Published here so the access-control and payment logic can be read and
criticised by people who did not write it. Issues and pull requests welcome,
particularly on the authority model.

| Package | Module | Mainnet package ID |
| --- | --- | --- |
| `journey` | `cocoon::journey` | `0x682d456a9b6c051c9b70e2f67bcee9602b1244278b898e70348b8c6214c214ab` |
| `pay` | `cocoon_pay::treasury` | `0x50a0583be0008d76f2d94988b1d81960b61e18a647deb3004052f0ce038341bb` |

## What each package does

### `cocoon::journey`

Purchase, session lifecycle, and the Seal decryption policy.

- `purchase<T>` is generic over the coin type and takes a currency-blind `u64`
  price, so a new settlement currency is a client-side change rather than a
  contract upgrade. It aborts `EInvalidFee` on underpayment and forwards funds
  in the same transaction.
- `Session` is a **shared** object, because the Seal key servers must read it
  during a dry run. `buyer` is fixed at purchase and never mutated.
- `complete` and `set_blob_id` both assert `ctx.sender() == session.buyer` and
  both assert `!completed`, so the blob reference is write-once by the buyer.
- `seal_approve` is the policy entry point. Seal key servers build a PTB with
  the requesting address as sender and dry-run it; an abort withholds the key
  shares. It delegates to `check_policy`, which gates on three things and
  nothing else: package version, `sender == buyer`, and `now < expiry_ms`,
  plus a namespace check that the requested identity is prefixed with the
  session's own object ID so one session cannot decrypt another's blob.

The deliberate omission is worth stating: **`seal_approve` never reads
`completed`.** Completion stops new conversation turns, which is a server-side
property, and it is not a decryption right. Conflating the two is the main way
this module could go wrong, and there is a test pinning it (a completed session
still approves).

Version safety: a shared `PackageVersion` object
(`0x4e0cf71a175ed934276861b7247a19d1428e9c1f5756e2453dc1b2ba4957a528`) is
asserted against the compiled `VERSION`, so an upgrade cannot silently leave an
old policy answering requests.

### `cocoon_pay::treasury`

A small operator-funded float that hands each new buyer address a one-off
provision of SUI and WAL so they can pay for their own Walrus storage.

- `claim_provision` is once per address, forever, tracked in a `Table` and
  asserted with `EAlreadyProvisioned`.
- `withdraw` requires `OperatorCap`. Deposits do not.
- `Treasury<phantom W>` is generic over the WAL type rather than hardcoding it.

## What is deliberately not here

The Worker never holds a key that can move buyer funds. Buyers sign their own
purchases; refunds are manual. Nothing in these packages custodies a buyer
balance, and no admin function can move a `Session` or reassign its `buyer`.

## A third package exists on chain

`cocoon_seal::access_policy`
(`0x3a35f12152047ef6174981642699f46ade6f83b700297abd6686286c479e4254`) is
published on mainnet but **is not used by the product** and is not included
here. It is an earlier, superseded access policy with a different `Session`
shape (a `payer` field rather than `buyer`). It is referenced by no client and
no server. Mentioned only so that anyone reading the chain does not mistake it
for the live policy.

## Build and test

Requires the [Sui CLI](https://docs.sui.io/guides/developer/getting-started/sui-install).

```
cd journey && sui move build && sui move test
cd ../pay && sui move build && sui move test
```

`journey` carries tests for the identity and time gates, fund forwarding and
expiry, and underpayment. Both packages target Move edition `2024.beta`.

## Licence

See `LICENSE` if present; otherwise all rights reserved pending a decision.
