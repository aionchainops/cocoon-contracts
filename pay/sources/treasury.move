module cocoon_pay::treasury;

use sui::balance::{Self, Balance};
use sui::coin::{Self, Coin};
use sui::sui::SUI;
use sui::table::{Self, Table};
use sui::event;

const EAlreadyProvisioned: u64 = 1;
const EInsufficientTreasurySui: u64 = 2;
const EInsufficientTreasuryWal: u64 = 3;

const PROVISION_SUI_MIST: u64 = 11_000_000;
const PROVISION_WAL_FROST: u64 = 3_000_000_000;

const TARGET_FLOAT_SUI_MIST: u64 = 7_200_000_000;
const TARGET_FLOAT_WAL_FROST: u64 = 309_000_000_000;
const ALERT_THRESHOLD_SUI_MIST: u64 = 2_900_000_000;
const ALERT_THRESHOLD_WAL_FROST: u64 = 124_000_000_000;

/// Authorises treasury administration.
public struct OperatorCap has key, store { id: UID }

/// Holds the SUI and WAL float for buyer provisions.
public struct Treasury<phantom W> has key {
    id: UID,
    sui: Balance<SUI>,
    wal: Balance<W>,

    claimed: Table<address, bool>,
}

/// Emitted when the treasury balance changes by deposit or withdrawal.
public struct TreasuryDeposit has copy, drop {
    sui_in: u64,
    wal_in: u64,
    post_sui: u64,
    post_wal: u64,
}
/// Emitted when a provision is drawn.
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

/// Creates and shares a Treasury.
entry fun create_treasury<W>(_: &OperatorCap, ctx: &mut TxContext) {
    transfer::share_object(Treasury<W> {
        id: object::new(ctx),
        sui: balance::zero<SUI>(),
        wal: balance::zero<W>(),
        claimed: table::new(ctx),
    });
}

/// Adds SUI to the treasury.
entry fun deposit_sui<W>(t: &mut Treasury<W>, c: Coin<SUI>) {
    let amt = coin::value(&c);
    balance::join(&mut t.sui, coin::into_balance(c));
    event::emit(TreasuryDeposit { sui_in: amt, wal_in: 0, post_sui: balance::value(&t.sui), post_wal: balance::value(&t.wal) });
}
/// Adds WAL to the treasury.
entry fun deposit_wal<W>(t: &mut Treasury<W>, c: Coin<W>) {
    let amt = coin::value(&c);
    balance::join(&mut t.wal, coin::into_balance(c));
    event::emit(TreasuryDeposit { sui_in: 0, wal_in: amt, post_sui: balance::value(&t.sui), post_wal: balance::value(&t.wal) });
}

/// Sends one provision to the sender.
entry fun claim_provision<W>(t: &mut Treasury<W>, ctx: &mut TxContext) {
    let who = ctx.sender();
    assert!(!table::contains(&t.claimed, who), EAlreadyProvisioned);

    assert!(balance::value(&t.sui) >= PROVISION_SUI_MIST, EInsufficientTreasurySui);
    assert!(balance::value(&t.wal) >= PROVISION_WAL_FROST, EInsufficientTreasuryWal);
    table::add(&mut t.claimed, who, true);
    let s = coin::from_balance(balance::split(&mut t.sui, PROVISION_SUI_MIST), ctx);
    let w = coin::from_balance(balance::split(&mut t.wal, PROVISION_WAL_FROST), ctx);
    transfer::public_transfer(s, who);
    transfer::public_transfer(w, who);
    event::emit(TreasuryDraw { recipient: who, sui_out: PROVISION_SUI_MIST, wal_out: PROVISION_WAL_FROST, post_sui: balance::value(&t.sui), post_wal: balance::value(&t.wal) });
}

/// Withdraws SUI and WAL to the operator.
entry fun withdraw<W>(_: &OperatorCap, t: &mut Treasury<W>, sui_amt: u64, wal_amt: u64, ctx: &mut TxContext) {
    let who = ctx.sender();
    if (sui_amt > 0) transfer::public_transfer(coin::from_balance(balance::split(&mut t.sui, sui_amt), ctx), who);
    if (wal_amt > 0) transfer::public_transfer(coin::from_balance(balance::split(&mut t.wal, wal_amt), ctx), who);
    event::emit(TreasuryDraw { recipient: who, sui_out: sui_amt, wal_out: wal_amt, post_sui: balance::value(&t.sui), post_wal: balance::value(&t.wal) });
}

/// Read-only views.
public fun balances<W>(t: &Treasury<W>): (u64, u64) { (balance::value(&t.sui), balance::value(&t.wal)) }
public fun provision_amounts(): (u64, u64) { (PROVISION_SUI_MIST, PROVISION_WAL_FROST) }
public fun thresholds(): (u64, u64, u64, u64) { (TARGET_FLOAT_SUI_MIST, TARGET_FLOAT_WAL_FROST, ALERT_THRESHOLD_SUI_MIST, ALERT_THRESHOLD_WAL_FROST) }
public fun has_claimed<W>(t: &Treasury<W>, a: address): bool { table::contains(&t.claimed, a) }
