module cocoon_provision::treasury;

use sui::balance::{Self, Balance};
use sui::coin::{Self, Coin};
use sui::sui::SUI;
use sui::table::{Self, Table};
use sui::event;
use std::type_name;
use std::ascii::String;

const EAlreadyProvisioned: u64 = 1;
const EInsufficientTreasurySui: u64 = 2;
const EInsufficientTreasuryWal: u64 = 3;
const ENotBuyer: u64 = 4;
const EJourneyNotApproved: u64 = 5;
const EPriceBelowFloor: u64 = 6;
const ECoinNotAccepted: u64 = 7;

#[allow(unused_const)]
const EJourneyMismatch: u64 = 8;
const EWrongVersion: u64 = 9;
const ESuperseded: u64 = 10;

const VERSION: u64 = 2;

const PROVISION_SUI_MIST: u64 = 11_000_000;
const PROVISION_WAL_FROST: u64 = 3_000_000_000;

const MIN_QUALIFYING_PRICE: u64 = 50_000_000;

const USDC_TYPE: vector<u8> =
    b"dba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC";
const USDSUI_TYPE: vector<u8> =
    b"44f838219cf67b058f3b37907b655f226153c18e33dfcd0da559a844fea9b1c1::usdsui::USDSUI";

/// Authorises vault administration.
public struct OperatorCap has key, store { id: UID }

/// Holds the SUI and WAL float for buyer provisions, with its approved journeys and accepted coin types.
public struct Vault<phantom W> has key {
    id: UID,

    version: u64,
    sui: Balance<SUI>,
    wal: Balance<W>,

    claimed: Table<ID, bool>,

    approved: Table<ID, bool>,

    accepted_coins: Table<vector<u8>, bool>,
}

/// Emitted when a provision is paid.
public struct ProvisionDraw has copy, drop {
    recipient: address,

    session_id: ID,
    journey_id: ID,
    sui_out: u64,
    wal_out: u64,
    post_sui: u64,
    post_wal: u64,
}

/// Emitted when the vault balance changes by deposit or withdrawal.
public struct VaultDeposit has copy, drop {
    vault: ID,
    sui_in: u64,
    wal_in: u64,
    post_sui: u64,
    post_wal: u64,
}

/// Emitted when a vault is migrated to this package version.
public struct VaultMigrated has copy, drop {
    vault: ID,
    version: u64,
}

/// Emitted when a journey's approval changes.
public struct JourneyApproval has copy, drop {
    vault: ID,
    journey_id: ID,
    approved: bool,
}

fun init(ctx: &mut TxContext) {
    transfer::public_transfer(OperatorCap { id: object::new(ctx) }, ctx.sender());
}

/// Creates and shares a Vault.
entry fun create_vault<W>(
    _: &OperatorCap,
    coin_types: vector<vector<u8>>,
    ctx: &mut TxContext,
) {
    let mut accepted = table::new<vector<u8>, bool>(ctx);
    let mut i = 0;
    while (i < vector::length(&coin_types)) {
        table::add(&mut accepted, *vector::borrow(&coin_types, i), true);
        i = i + 1;
    };
    transfer::share_object(Vault<W> {
        id: object::new(ctx),
        version: VERSION,
        sui: balance::zero<SUI>(),
        wal: balance::zero<W>(),
        claimed: table::new(ctx),
        approved: table::new(ctx),
        accepted_coins: accepted,
    });
}

/// Aborts unless the vault is at this package version.
fun assert_version<W>(v: &Vault<W>) {
    assert!(v.version == VERSION, EWrongVersion);
}

/// Moves a vault to this package version.
entry fun migrate<W>(_: &OperatorCap, v: &mut Vault<W>) {
    assert!(v.version < VERSION, EWrongVersion);
    v.version = VERSION;
    event::emit(VaultMigrated { vault: object::id(v), version: VERSION });
}

/// Approves or unapproves a journey for provisions.
entry fun set_journey_approved<W>(
    _: &OperatorCap,
    v: &mut Vault<W>,
    journey_id: ID,
    approved: bool,
) {
    assert_version(v);
    let present = table::contains(&v.approved, journey_id);
    if (approved && !present) { table::add(&mut v.approved, journey_id, true); }
    else if (!approved && present) { table::remove(&mut v.approved, journey_id); };
    event::emit(JourneyApproval { vault: object::id(v), journey_id, approved });
}

/// Adds SUI to the vault.
entry fun deposit_sui<W>(v: &mut Vault<W>, c: Coin<SUI>) {
    assert_version(v);
    let amt = coin::value(&c);
    balance::join(&mut v.sui, coin::into_balance(c));
    event::emit(VaultDeposit { vault: object::id(v), sui_in: amt, wal_in: 0,
        post_sui: balance::value(&v.sui), post_wal: balance::value(&v.wal) });
}
/// Adds WAL to the vault.
entry fun deposit_wal<W>(v: &mut Vault<W>, c: Coin<W>) {
    assert_version(v);
    let amt = coin::value(&c);
    balance::join(&mut v.wal, coin::into_balance(c));
    event::emit(VaultDeposit { vault: object::id(v), sui_in: 0, wal_in: amt,
        post_sui: balance::value(&v.sui), post_wal: balance::value(&v.wal) });
}

/// Retired. Always aborts with `ESuperseded`.
public fun claim_provision<W>(
    _v: &mut Vault<W>,
    _receipt: cocoon::journey::Receipt,
    _session: &cocoon::journey::Session,
    _ctx: &mut TxContext,
) {
    abort ESuperseded
}

/// Consumes a purchase Receipt and pays one provision to its buyer.
public fun claim<W>(
    v: &mut Vault<W>,
    receipt: cocoon::journey::Receipt,
    ctx: &mut TxContext,
) {
    assert_version(v);

    let (journey_id, buyer, coin_type, price_paid) =
        cocoon::journey::burn_receipt(receipt);

    assert!(ctx.sender() == buyer, ENotBuyer);

    assert!(is_accepted_coin(v, &coin_type), ECoinNotAccepted);

    assert!(table::contains(&v.approved, journey_id), EJourneyNotApproved);
    assert!(price_paid >= MIN_QUALIFYING_PRICE, EPriceBelowFloor);

    assert!(balance::value(&v.sui) >= PROVISION_SUI_MIST, EInsufficientTreasurySui);
    assert!(balance::value(&v.wal) >= PROVISION_WAL_FROST, EInsufficientTreasuryWal);

    let s = coin::from_balance(balance::split(&mut v.sui, PROVISION_SUI_MIST), ctx);
    let w = coin::from_balance(balance::split(&mut v.wal, PROVISION_WAL_FROST), ctx);
    transfer::public_transfer(s, buyer);
    transfer::public_transfer(w, buyer);

    event::emit(ProvisionDraw {
        recipient: buyer,
        session_id: journey_id,
        journey_id,
        sui_out: PROVISION_SUI_MIST,
        wal_out: PROVISION_WAL_FROST,
        post_sui: balance::value(&v.sui),
        post_wal: balance::value(&v.wal),
    });
}

/// Withdraws SUI and WAL to the operator.
entry fun withdraw<W>(
    _: &OperatorCap,
    v: &mut Vault<W>,
    sui_amt: u64,
    wal_amt: u64,
    ctx: &mut TxContext,
) {
    assert_version(v);
    let who = ctx.sender();
    if (sui_amt > 0) {
        transfer::public_transfer(coin::from_balance(balance::split(&mut v.sui, sui_amt), ctx), who);
    };
    if (wal_amt > 0) {
        transfer::public_transfer(coin::from_balance(balance::split(&mut v.wal, wal_amt), ctx), who);
    };
    event::emit(VaultDeposit { vault: object::id(v), sui_in: 0, wal_in: 0,
        post_sui: balance::value(&v.sui), post_wal: balance::value(&v.wal) });
}

/// Whether a coin type is accepted by the vault.
fun is_accepted_coin<W>(v: &Vault<W>, t: &type_name::TypeName): bool {
    let s: &String = type_name::as_string(t);
    table::contains(&v.accepted_coins, *s.as_bytes())
}

/// Read-only views.
public fun balances<W>(v: &Vault<W>): (u64, u64) {
    (balance::value(&v.sui), balance::value(&v.wal))
}
public fun provision_amounts(): (u64, u64) { (PROVISION_SUI_MIST, PROVISION_WAL_FROST) }
public fun min_qualifying_price(): u64 { MIN_QUALIFYING_PRICE }

public fun production_coin_types(): (vector<u8>, vector<u8>) { (USDC_TYPE, USDSUI_TYPE) }
public fun is_coin_accepted<W>(v: &Vault<W>, coin_type: vector<u8>): bool {
    table::contains(&v.accepted_coins, coin_type)
}
public fun is_journey_approved<W>(v: &Vault<W>, journey_id: ID): bool {
    table::contains(&v.approved, journey_id)
}

public fun has_claimed_session<W>(v: &Vault<W>, session_id: ID): bool {
    table::contains(&v.claimed, session_id)
}

public fun claimed_count<W>(v: &Vault<W>): u64 { table::length(&v.claimed) }

public fun vault_version<W>(v: &Vault<W>): u64 { v.version }
public fun package_version(): u64 { VERSION }

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) { init(ctx) }

#[test_only]
public fun new_vault_for_testing<W>(coin_types: vector<vector<u8>>, ctx: &mut TxContext): Vault<W> {
    let mut accepted = table::new<vector<u8>, bool>(ctx);
    let mut i = 0;
    while (i < vector::length(&coin_types)) {
        table::add(&mut accepted, *vector::borrow(&coin_types, i), true);
        i = i + 1;
    };
    Vault<W> {
        id: object::new(ctx),
        version: VERSION,
        sui: balance::zero<SUI>(),
        wal: balance::zero<W>(),
        claimed: table::new(ctx),
        approved: table::new(ctx),
        accepted_coins: accepted,
    }
}

#[test_only]
public fun new_vault_at_version_for_testing<W>(
    version: u64,
    coin_types: vector<vector<u8>>,
    ctx: &mut TxContext,
): Vault<W> {
    let mut v = new_vault_for_testing<W>(coin_types, ctx);
    v.version = version;
    v
}

#[test_only]
public fun withdraw_for_testing<W>(v: &mut Vault<W>, sui_amt: u64, wal_amt: u64, ctx: &mut TxContext) {
    assert_version(v);
    let who = ctx.sender();
    if (sui_amt > 0) {
        transfer::public_transfer(coin::from_balance(balance::split(&mut v.sui, sui_amt), ctx), who);
    };
    if (wal_amt > 0) {
        transfer::public_transfer(coin::from_balance(balance::split(&mut v.wal, wal_amt), ctx), who);
    };
}

#[test_only]
public fun set_journey_approved_for_testing<W>(v: &mut Vault<W>, journey_id: ID, approved: bool) {
    assert_version(v);
    let present = table::contains(&v.approved, journey_id);
    if (approved && !present) { table::add(&mut v.approved, journey_id, true); }
    else if (!approved && present) { table::remove(&mut v.approved, journey_id); };
}

#[test_only]
public fun migrate_for_testing<W>(v: &mut Vault<W>) {
    assert!(v.version < VERSION, EWrongVersion);
    v.version = VERSION;
}

#[test_only]
public fun coin_type_string_for_testing<T>(): vector<u8> {
    let t = type_name::with_original_ids<T>();
    *type_name::as_string(&t).as_bytes()
}

#[test_only]
public fun destroy_vault_for_testing<W>(v: Vault<W>) {
    let Vault { id, version: _, sui, wal, claimed, approved, accepted_coins } = v;
    balance::destroy_for_testing(sui);
    balance::destroy_for_testing(wal);
    table::drop(claimed);
    table::drop(approved);
    table::drop(accepted_coins);
    object::delete(id);
}

#[test_only]
public fun fund_for_testing<W>(v: &mut Vault<W>, sui_amt: u64, wal_amt: u64) {
    balance::join(&mut v.sui, balance::create_for_testing<SUI>(sui_amt));
    balance::join(&mut v.wal, balance::create_for_testing<W>(wal_amt));
}

#[test_only]
public fun approve_for_testing<W>(v: &mut Vault<W>, journey_id: ID) {
    table::add(&mut v.approved, journey_id, true);
}

#[test_only]
public fun is_accepted_coin_for_testing<W, T>(v: &Vault<W>): bool {
    is_accepted_coin(v, &type_name::with_original_ids<T>())
}

#[test_only]
public fun accepted_type_strings_for_testing(): (vector<u8>, vector<u8>) {
    (USDC_TYPE, USDSUI_TYPE)
}
