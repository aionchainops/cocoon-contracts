module cocoon::journey;

use sui::clock::Clock;
use sui::coin::{Self, Coin};

const VERSION: u64 = 1;

const EWrongVersion: u64 = 5;
const EInvalidFee: u64 = 12;
const ENotBuyer: u64 = 20;
const EAlreadyCompleted: u64 = 21;
const ENoAccess: u64 = 77;

/// Package version marker read by `seal_approve`.
public struct PackageVersion has key {
    id: UID,
    version: u64,
}

/// Authorises creating journeys.
public struct AdminCap has key, store {
    id: UID,
}

/// A purchasable journey: price, treasury address and access window.
public struct Journey has key {
    id: UID,

    treasury: address,

    price: u64,

    window_ms: u64,
}

/// A buyer's access record for one purchase of a journey.
public struct Session has key {
    id: UID,
    journey_id: ID,
    buyer: address,

    expiry_ms: u64,

    blob_id: vector<u8>,

    completed: bool,
}

fun init(ctx: &mut TxContext) {
    transfer::share_object(PackageVersion {
        id: object::new(ctx),
        version: VERSION,
    });
    transfer::public_transfer(AdminCap { id: object::new(ctx) }, ctx.sender());
}

/// Creates and shares a Journey.
entry fun create_journey(
    _: &AdminCap,
    treasury: address,
    price: u64,
    window_ms: u64,
    ctx: &mut TxContext,
) {
    transfer::share_object(Journey {
        id: object::new(ctx),
        treasury,
        price,
        window_ms,
    });
}

/// Pays the journey price and shares a new Session for the sender.
entry fun purchase<T>(
    journey: &Journey,
    payment: &mut Coin<T>,
    c: &Clock,
    ctx: &mut TxContext,
) {
    assert!(coin::value(payment) >= journey.price, EInvalidFee);
    let fee = coin::split(payment, journey.price, ctx);
    transfer::public_transfer(fee, journey.treasury);

    transfer::share_object(Session {
        id: object::new(ctx),
        journey_id: object::id(journey),
        buyer: ctx.sender(),
        expiry_ms: c.timestamp_ms() + journey.window_ms,
        blob_id: vector[],
        completed: false,
    });
}

/// Records the Walrus blob id of the session's stored state.
entry fun set_blob_id(session: &mut Session, blob_id: vector<u8>, ctx: &TxContext) {
    assert!(ctx.sender() == session.buyer, ENotBuyer);
    assert!(!session.completed, EAlreadyCompleted);
    session.blob_id = blob_id;
}

/// Marks the session completed and records its final blob id.
entry fun complete(session: &mut Session, blob_id: vector<u8>, ctx: &TxContext) {
    assert!(ctx.sender() == session.buyer, ENotBuyer);
    assert!(!session.completed, EAlreadyCompleted);
    session.blob_id = blob_id;
    session.completed = true;
}

/// Seal access check for an identity under a session.
fun check_policy(
    id: vector<u8>,
    pkg_version: &PackageVersion,
    session: &Session,
    c: &Clock,
    ctx: &TxContext,
): bool {
    assert!(pkg_version.version == VERSION, EWrongVersion);

    if (ctx.sender() != session.buyer) {
        return false
    };

    if (c.timestamp_ms() >= session.expiry_ms) {
        return false
    };

    let namespace = session.id.to_bytes();
    if (namespace.length() > id.length()) {
        return false
    };
    let mut i = 0;
    while (i < namespace.length()) {
        if (namespace[i] != id[i]) {
            return false
        };
        i = i + 1;
    };

    true
}

/// Seal entry point: aborts with `ENoAccess` unless `check_policy` passes.
entry fun seal_approve(
    id: vector<u8>,
    pkg_version: &PackageVersion,
    session: &Session,
    c: &Clock,
    ctx: &TxContext,
) {
    assert!(check_policy(id, pkg_version, session, c, ctx), ENoAccess);
}

/// The session's buyer.
public fun buyer(session: &Session): address { session.buyer }

/// The journey the session was bought against.
public fun journey_id(session: &Session): ID { session.journey_id }

/// The session's expiry, in milliseconds.
public fun expiry_ms(session: &Session): u64 { session.expiry_ms }

/// The Walrus blob id of the session's stored state.
public fun blob_id(session: &Session): vector<u8> { session.blob_id }

/// Whether the session is completed.
public fun is_completed(session: &Session): bool { session.completed }

/// A purchase record that must be consumed in the same transaction.
public struct Receipt {
    journey_id: ID,
    buyer: address,

    coin: std::type_name::TypeName,

    price_paid: u64,
}

/// As `purchase`, and also returns a Receipt.
public fun purchase_receipt<T>(
    journey: &Journey,
    payment: &mut Coin<T>,
    c: &Clock,
    ctx: &mut TxContext,
): Receipt {
    let (session, receipt) = build_purchase(journey, payment, c, ctx);
    transfer::share_object(session);
    receipt
}

/// Purchase logic shared by `purchase` and `purchase_receipt`.
fun build_purchase<T>(
    journey: &Journey,
    payment: &mut Coin<T>,
    c: &Clock,
    ctx: &mut TxContext,
): (Session, Receipt) {
    assert!(coin::value(payment) >= journey.price, EInvalidFee);
    let fee = coin::split(payment, journey.price, ctx);
    transfer::public_transfer(fee, journey.treasury);

    let session = Session {
        id: object::new(ctx),
        journey_id: object::id(journey),
        buyer: ctx.sender(),
        expiry_ms: c.timestamp_ms() + journey.window_ms,
        blob_id: vector[],
        completed: false,
    };

    let receipt = Receipt {
        journey_id: object::id(journey),
        buyer: ctx.sender(),

        coin: std::type_name::with_original_ids<T>(),
        price_paid: journey.price,
    };

    (session, receipt)
}

/// Consumes a Receipt and returns its journey id, buyer, coin type and price paid.
public fun burn_receipt(r: Receipt): (ID, address, std::type_name::TypeName, u64) {
    let Receipt { journey_id, buyer, coin, price_paid } = r;
    (journey_id, buyer, coin, price_paid)
}

/// Receipt fields.
public fun receipt_journey_id(r: &Receipt): ID { r.journey_id }
public fun receipt_buyer(r: &Receipt): address { r.buyer }
public fun receipt_coin(r: &Receipt): std::type_name::TypeName { r.coin }
public fun receipt_price_paid(r: &Receipt): u64 { r.price_paid }

/// Journey fields.
public fun price(journey: &Journey): u64 { journey.price }

public fun treasury(journey: &Journey): address { journey.treasury }

public fun window_ms(journey: &Journey): u64 { journey.window_ms }

#[test_only]
use sui::clock;
#[test_only]
use sui::sui::SUI;

#[test_only]
fun new_version_for_testing(ctx: &mut TxContext): PackageVersion {
    PackageVersion { id: object::new(ctx), version: VERSION }
}

#[test_only]
fun destroy_version_for_testing(v: PackageVersion) {
    let PackageVersion { id, .. } = v;
    object::delete(id);
}

#[test_only]
fun new_session_for_testing(
    buyer: address,
    expiry_ms: u64,
    ctx: &mut TxContext,
): Session {
    Session {
        id: object::new(ctx),
        journey_id: object::id_from_address(@0x1),
        buyer,
        expiry_ms,
        blob_id: vector[],
        completed: false,
    }
}

#[test_only]
fun destroy_session_for_testing(s: Session) {
    let Session { id, .. } = s;
    object::delete(id);
}

#[test]
fun test_identity_and_time_gates() {
    let buyer = @0xA;
    let ctx = &mut tx_context::dummy();
    let mut c = clock::create_for_testing(ctx);

    let pkg_version = new_version_for_testing(ctx);
    let session = new_session_for_testing(buyer, 1000, ctx);

    let mut id = session.id.to_bytes();
    id.push_back(7);

    assert!(!check_policy(id, &pkg_version, &session, &c, ctx), 0);

    let buyer_ctx = &tx_context::new_from_hint(buyer, 0, 0, 0, 0);
    assert!(check_policy(id, &pkg_version, &session, &c, buyer_ctx), 1);

    let foreign = vector[9u8, 9u8, 9u8];
    assert!(!check_policy(foreign, &pkg_version, &session, &c, buyer_ctx), 2);

    c.increment_for_testing(1000);
    assert!(!check_policy(id, &pkg_version, &session, &c, buyer_ctx), 3);

    c.increment_for_testing(1);
    assert!(!check_policy(id, &pkg_version, &session, &c, buyer_ctx), 4);

    destroy_session_for_testing(session);
    destroy_version_for_testing(pkg_version);
    c.destroy_for_testing();
}

#[test]
fun test_purchase_forwards_funds_and_sets_expiry() {
    let treasury = @0xB;
    let buyer = @0xA;
    let ctx = &mut tx_context::new_from_hint(buyer, 0, 0, 0, 0);
    let c = clock::create_for_testing(ctx);

    let journey = Journey {
        id: object::new(ctx),
        treasury,
        price: 100,
        window_ms: 60_000,
    };

    let mut payment = coin::mint_for_testing<SUI>(150, ctx);
    purchase(&journey, &mut payment, &c, ctx);

    assert!(coin::value(&payment) == 50, 0);
    coin::burn_for_testing(payment);

    let Journey { id, .. } = journey;
    object::delete(id);
    c.destroy_for_testing();
}

#[test]
#[expected_failure(abort_code = EInvalidFee)]
fun test_underpayment_aborts() {
    let ctx = &mut tx_context::dummy();
    let c = clock::create_for_testing(ctx);

    let journey = Journey {
        id: object::new(ctx),
        treasury: @0xB,
        price: 100,
        window_ms: 60_000,
    };

    let mut payment = coin::mint_for_testing<SUI>(99, ctx);
    purchase(&journey, &mut payment, &c, ctx);
    coin::burn_for_testing(payment);

    let Journey { id, .. } = journey;
    object::delete(id);
    c.destroy_for_testing();
}

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) { init(ctx) }

#[test_only]
public fun new_journey_for_testing(
    treasury: address,
    price: u64,
    window_ms: u64,
    ctx: &mut TxContext,
): Journey {
    Journey { id: object::new(ctx), treasury, price, window_ms }
}

#[test_only]
public fun destroy_journey_for_testing(j: Journey) {
    let Journey { id, .. } = j;
    object::delete(id);
}

#[test_only]
public fun destroy_session_for_dependent_testing(s: Session) {
    let Session { id, .. } = s;
    object::delete(id);
}

#[test_only]
use sui::test_scenario as tsc;

#[test]
#[expected_failure(abort_code = EInvalidFee)]
fun underpaying_purchase_receipt_aborts_with_the_same_code_as_purchase() {

    let ctx = &mut tx_context::dummy();
    let c = clock::create_for_testing(ctx);
    let j = new_journey_for_testing(@0xA, 1_000, 1_000, ctx);
    let mut pay = coin::mint_for_testing<SUI>(999, ctx);
    let (session, receipt) = build_purchase(&j, &mut pay, &c, ctx);

    destroy_session_for_testing(session);
    let (_, _, _, _) = burn_receipt(receipt);
    destroy_journey_for_testing(j);
    clock::destroy_for_testing(c);
    coin::burn_for_testing(pay);
}

#[test]
#[expected_failure(abort_code = EInvalidFee)]
fun underpaying_purchase_aborts_with_the_same_code() {

    let ctx = &mut tx_context::dummy();
    let c = clock::create_for_testing(ctx);
    let j = new_journey_for_testing(@0xA, 1_000, 1_000, ctx);
    let mut pay = coin::mint_for_testing<SUI>(999, ctx);
    purchase(&j, &mut pay, &c, ctx);
    destroy_journey_for_testing(j);
    clock::destroy_for_testing(c);
    coin::burn_for_testing(pay);
}

#[test]
fun both_paths_take_exactly_the_price_and_leave_the_remainder() {

    let ctx = &mut tx_context::dummy();
    let c = clock::create_for_testing(ctx);
    let j = new_journey_for_testing(@0xA, 1_000, 5_000, ctx);

    let mut pay_a = coin::mint_for_testing<SUI>(1_500, ctx);
    purchase(&j, &mut pay_a, &c, ctx);
    let left_after_purchase = coin::value(&pay_a);

    let mut pay_b = coin::mint_for_testing<SUI>(1_500, ctx);
    let (session, receipt) = build_purchase(&j, &mut pay_b, &c, ctx);
    let left_after_receipt = coin::value(&pay_b);

    assert!(left_after_purchase == 500, 900);
    assert!(left_after_receipt == 500, 901);
    assert!(left_after_purchase == left_after_receipt, 902);

    assert!(receipt_price_paid(&receipt) == 1_000, 903);
    assert!(receipt_journey_id(&receipt) == object::id(&j), 904);
    assert!(receipt_buyer(&receipt) == ctx.sender(), 905);

    assert!(buyer(&session) == ctx.sender(), 906);
    assert!(journey_id(&session) == object::id(&j), 907);
    assert!(expiry_ms(&session) == 5_000, 908);
    assert!(!is_completed(&session), 909);

    destroy_session_for_testing(session);
    let (_, _, _, _) = burn_receipt(receipt);
    destroy_journey_for_testing(j);
    clock::destroy_for_testing(c);
    coin::burn_for_testing(pay_a);
    coin::burn_for_testing(pay_b);
}

#[test]
fun purchase_receipt_SHARES_its_session_just_as_purchase_does() {

    let buyer_addr = @0xB0B;
    let mut s = tsc::begin(buyer_addr);
    {
        let ctx = tsc::ctx(&mut s);
        let c = clock::create_for_testing(ctx);
        let j = new_journey_for_testing(@0xA, 1_000, 5_000, ctx);
        let mut pay = coin::mint_for_testing<SUI>(1_000, ctx);

        let receipt = purchase_receipt(&j, &mut pay, &c, ctx);
        let (_, _, _, _) = burn_receipt(receipt);

        tsc::next_tx(&mut s, buyer_addr);
        let session = tsc::take_shared<Session>(&s);
        assert!(buyer(&session) == buyer_addr, 910);
        assert!(journey_id(&session) == object::id(&j), 911);
        tsc::return_shared(session);

        destroy_journey_for_testing(j);
        clock::destroy_for_testing(c);
        coin::burn_for_testing(pay);
    };
    tsc::end(s);
}

#[test]
fun purchase_also_shares_its_session() {

    let buyer_addr = @0xB0B;
    let mut s = tsc::begin(buyer_addr);
    {
        let ctx = tsc::ctx(&mut s);
        let c = clock::create_for_testing(ctx);
        let j = new_journey_for_testing(@0xA, 1_000, 5_000, ctx);
        let mut pay = coin::mint_for_testing<SUI>(1_000, ctx);

        purchase(&j, &mut pay, &c, ctx);

        tsc::next_tx(&mut s, buyer_addr);
        let session = tsc::take_shared<Session>(&s);
        assert!(buyer(&session) == buyer_addr, 920);
        tsc::return_shared(session);

        destroy_journey_for_testing(j);
        clock::destroy_for_testing(c);
        coin::burn_for_testing(pay);
    };
    tsc::end(s);
}
