// cocoon_pay - purchase provisioning treasury. SEPARATE from cocoon::journey by
// design: the policy package ratchets to DEP_ONLY; money code stays COMPATIBLE.
//
// The treasury is a shared object holding Balance<SUI> + Balance<WAL>, deposited
// by the operator, drawn by contract logic only. No signer can move it; the
// Worker never touches it; release is code. THE FLOAT IS THE HARD EXPOSURE CAP:
// nothing in this module can emit more than the treasury holds, and nothing
// refills it except an explicit deposit call. There is NO auto-replenish path.
//
// FAIL CLOSED: claim_provision aborts (per-asset checks) BEFORE any balance is
// split. Composed in one PTB with the payment (journey::purchase), an abort here
// aborts the whole transaction - the buyer's payment coin never moves, so
// paid-but-unprovisioned cannot exist.
//
// Drain bound: one provision per address, forever (Table). A hostile wallet mill
// can claim at most PROVISION_* per fresh address until the float is gone - the
// float cap is the loss bound, stated in PAY-RESULTS.md.
module cocoon_pay::treasury;

use sui::balance::{Self, Balance};
use sui::coin::{Self, Coin};
use sui::sui::SUI;
use sui::table::{Self, Table};
use sui::event;

const EAlreadyProvisioned: u64 = 1;
const EInsufficientTreasurySui: u64 = 2;
const EInsufficientTreasuryWal: u64 = 3;

// Provision amounts. Observed per-write cost (5 consecutive mainnet runs):
// 0.0034 SUI gas + 0.0175 WAL storage. Grace multiplier 3, rounded up:
//   SUI: 3_424_784 * 3 = 10_274_352 -> 11_000_000 MIST (0.011 SUI)
//   WAL: 17_496_171 * 3 = 52_488_513 -> 53_000_000 FROST (0.053 WAL)
const PROVISION_SUI_MIST: u64 = 11_000_000;
const PROVISION_WAL_FROST: u64 = 53_000_000;

// Addendum thresholds (config constants; changing them is a package upgrade by
// the operator - cocoon_pay stays COMPATIBLE indefinitely, so this remains
// possible; no governance implied). Price basis recorded in PAY-RESULTS.md.
const TARGET_FLOAT_SUI_MIST: u64 = 7_200_000_000;    // ~ $25 at build-time price
const TARGET_FLOAT_WAL_FROST: u64 = 309_000_000_000; // ~ $25
const ALERT_THRESHOLD_SUI_MIST: u64 = 2_900_000_000; // ~ $10
const ALERT_THRESHOLD_WAL_FROST: u64 = 124_000_000_000; // ~ $10

public struct OperatorCap has key, store { id: UID }

/// Generic over the storage asset W (instantiated with mainnet WAL at
/// creation), so no external coin-package dependency is needed.
public struct Treasury<phantom W> has key {
    id: UID,
    sui: Balance<SUI>,
    wal: Balance<W>,
    /// One provision per address, forever. The drain rate-limit.
    claimed: Table<address, bool>,
}

/// Every draw and deposit emits post-action balances so any outside watcher
/// (explorer, GraphQL, the operator's own tooling) tracks levels without
/// custom reads.
public struct TreasuryDeposit has copy, drop {
    sui_in: u64,
    wal_in: u64,
    post_sui: u64,
    post_wal: u64,
}
public struct TreasuryDraw has copy, drop {
    recipient: address,
    sui_out: u64,
    wal_out: u64,
    post_sui: u64,
    post_wal: u64,
}

fun init(ctx: &mut TxContext) {
    transfer::public_transfer(OperatorCap { id: object::new(ctx) }, ctx.sender());
}

/// One-time, operator-gated: instantiate the shared treasury with the concrete
/// storage-asset type (mainnet WAL). Gating on the cap prevents decoy treasuries
/// under this package id.
entry fun create_treasury<W>(_: &OperatorCap, ctx: &mut TxContext) {
    transfer::share_object(Treasury<W> {
        id: object::new(ctx),
        sui: balance::zero<SUI>(),
        wal: balance::zero<W>(),
        claimed: table::new(ctx),
    });
}

/// Anyone may top up (deposits are safe; only balances change).
entry fun deposit_sui<W>(t: &mut Treasury<W>, c: Coin<SUI>) {
    let amt = coin::value(&c);
    balance::join(&mut t.sui, coin::into_balance(c));
    event::emit(TreasuryDeposit { sui_in: amt, wal_in: 0, post_sui: balance::value(&t.sui), post_wal: balance::value(&t.wal) });
}
entry fun deposit_wal<W>(t: &mut Treasury<W>, c: Coin<W>) {
    let amt = coin::value(&c);
    balance::join(&mut t.wal, coin::into_balance(c));
    event::emit(TreasuryDeposit { sui_in: 0, wal_in: amt, post_sui: balance::value(&t.sui), post_wal: balance::value(&t.wal) });
}

/// The provision draw. Composed in one PTB with the payment; aborting here
/// aborts the payment too (fail closed, atomically).
entry fun claim_provision<W>(t: &mut Treasury<W>, ctx: &mut TxContext) {
    let who = ctx.sender();
    assert!(!table::contains(&t.claimed, who), EAlreadyProvisioned);
    // Per-asset fail-closed checks BEFORE any split.
    assert!(balance::value(&t.sui) >= PROVISION_SUI_MIST, EInsufficientTreasurySui);
    assert!(balance::value(&t.wal) >= PROVISION_WAL_FROST, EInsufficientTreasuryWal);
    table::add(&mut t.claimed, who, true);
    let s = coin::from_balance(balance::split(&mut t.sui, PROVISION_SUI_MIST), ctx);
    let w = coin::from_balance(balance::split(&mut t.wal, PROVISION_WAL_FROST), ctx);
    transfer::public_transfer(s, who);
    transfer::public_transfer(w, who);
    event::emit(TreasuryDraw { recipient: who, sui_out: PROVISION_SUI_MIST, wal_out: PROVISION_WAL_FROST, post_sui: balance::value(&t.sui), post_wal: balance::value(&t.wal) });
}

/// Operator recovery of overfunding. Trivial, so included per brief.
entry fun withdraw<W>(_: &OperatorCap, t: &mut Treasury<W>, sui_amt: u64, wal_amt: u64, ctx: &mut TxContext) {
    let who = ctx.sender();
    if (sui_amt > 0) transfer::public_transfer(coin::from_balance(balance::split(&mut t.sui, sui_amt), ctx), who);
    if (wal_amt > 0) transfer::public_transfer(coin::from_balance(balance::split(&mut t.wal, wal_amt), ctx), who);
    event::emit(TreasuryDraw { recipient: who, sui_out: sui_amt, wal_out: wal_amt, post_sui: balance::value(&t.sui), post_wal: balance::value(&t.wal) });
}

// ----- reads (explorer/watcher-friendly; events are the primary trail) -----
public fun balances<W>(t: &Treasury<W>): (u64, u64) { (balance::value(&t.sui), balance::value(&t.wal)) }
public fun provision_amounts(): (u64, u64) { (PROVISION_SUI_MIST, PROVISION_WAL_FROST) }
public fun thresholds(): (u64, u64, u64, u64) { (TARGET_FLOAT_SUI_MIST, TARGET_FLOAT_WAL_FROST, ALERT_THRESHOLD_SUI_MIST, ALERT_THRESHOLD_WAL_FROST) }
public fun has_claimed<W>(t: &Treasury<W>, a: address): bool { table::contains(&t.claimed, a) }
