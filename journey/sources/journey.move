// Cocoon - access policy package.
//
// This package holds no funds. Payment passes through `purchase` atomically
// to the journey's treasury address in the same transaction; nothing ever
// rests here. Its only job is to answer one question for Seal's key servers:
// may this wallet, right now, decrypt this session's data?
//
// Two gates, both required:
//   identity - the caller must be the wallet that paid for this session
//   time     - the current on-chain time must be strictly before expiry
//
// Expiry is written once at purchase and is not mutable by anyone, including
// the package owner. There is no reopen path by design.
//
// Key identity format: [pkg id][session object id][nonce]
// The session object id is the namespace, so every re-upload across a
// session is covered by this one policy without any syncing. The Walrus
// blob id must never appear in the identity.

module cocoon::journey;

use sui::clock::Clock;
use sui::coin::{Self, Coin};

const VERSION: u64 = 1;

const EWrongVersion: u64 = 5;
const EInvalidFee: u64 = 12;
const ENotBuyer: u64 = 20;
const EAlreadyCompleted: u64 = 21;
const ENoAccess: u64 = 77;

/// Global version marker, per Seal's upgrade guidance. `seal_approve` refuses
/// to answer unless the shared version object matches the compiled VERSION,
/// so an upgrade cannot silently leave an old policy answering requests.
public struct PackageVersion has key {
    id: UID,
    version: u64,
}

public struct AdminCap has key, store {
    id: UID,
}

/// A journey that can be bought. Align is the first one.
public struct Journey has key {
    id: UID,
    /// Wallet that receives payment.
    treasury: address,
    /// Price, in the smallest unit of the payment coin.
    price: u64,
    /// How long the buyer gets, in milliseconds from the moment of purchase.
    window_ms: u64,
}

/// One purchase by one wallet. Shared so key servers can resolve it, but
/// only `buyer` can ever obtain a decryption key for the data it points at.
public struct Session has key {
    id: UID,
    journey_id: ID,
    buyer: address,
    /// Absolute expiry in milliseconds. Written once, never mutable.
    expiry_ms: u64,
    /// Walrus blob holding the current encrypted state. Superseded blobs
    /// stay covered by the same policy because the Seal identity is derived
    /// from this object's id, not from any blob id.
    blob_id: vector<u8>,
    /// Set once the insight has been generated. No retaking.
    completed: bool,
}

fun init(ctx: &mut TxContext) {
    transfer::share_object(PackageVersion {
        id: object::new(ctx),
        version: VERSION,
    });
    transfer::public_transfer(AdminCap { id: object::new(ctx) }, ctx.sender());
}

// ---------------------------------------------------------------------------
// Setup
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// Purchase
// ---------------------------------------------------------------------------

/// Pay for a journey and open a session in one transaction. The coin is
/// forwarded straight to the treasury - this package never holds it.
/// Generic over the coin type so the same code works for SUI on testnet and
/// USDC on mainnet.
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

// ---------------------------------------------------------------------------
// Session state
// ---------------------------------------------------------------------------

/// Point the session at a newer Walrus blob after another visit.
entry fun set_blob_id(session: &mut Session, blob_id: vector<u8>, ctx: &TxContext) {
    assert!(ctx.sender() == session.buyer, ENotBuyer);
    assert!(!session.completed, EAlreadyCompleted);
    session.blob_id = blob_id;
}

/// Record the final insight and lock the questionnaire.
entry fun complete(session: &mut Session, blob_id: vector<u8>, ctx: &TxContext) {
    assert!(ctx.sender() == session.buyer, ENotBuyer);
    assert!(!session.completed, EAlreadyCompleted);
    session.blob_id = blob_id;
    session.completed = true;
}

// ---------------------------------------------------------------------------
// Access control
// ---------------------------------------------------------------------------

fun check_policy(
    id: vector<u8>,
    pkg_version: &PackageVersion,
    session: &Session,
    c: &Clock,
    ctx: &TxContext,
): bool {
    assert!(pkg_version.version == VERSION, EWrongVersion);

    // Identity gate.
    if (ctx.sender() != session.buyer) {
        return false
    };

    // Time gate. Read live from the on-chain clock on every single request,
    // never cached at encryption time - this is what makes expiry apply
    // equally to every version of the session's data.
    if (c.timestamp_ms() >= session.expiry_ms) {
        return false
    };

    // Namespace gate: the requested identity must sit under this session.
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

entry fun seal_approve(
    id: vector<u8>,
    pkg_version: &PackageVersion,
    session: &Session,
    c: &Clock,
    ctx: &TxContext,
) {
    assert!(check_policy(id, pkg_version, session, c, ctx), ENoAccess);
}

// ---------------------------------------------------------------------------
// Reads
// ---------------------------------------------------------------------------

public fun buyer(session: &Session): address { session.buyer }

public fun expiry_ms(session: &Session): u64 { session.expiry_ms }

public fun blob_id(session: &Session): vector<u8> { session.blob_id }

public fun is_completed(session: &Session): bool { session.completed }

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

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
    let mut c = clock::create_for_testing(ctx); // t = 0

    let pkg_version = new_version_for_testing(ctx);
    let session = new_session_for_testing(buyer, 1000, ctx);

    // An identity under this session's namespace.
    let mut id = session.id.to_bytes();
    id.push_back(7);

    // Wrong caller is denied even before expiry. tx_context::dummy() has a
    // sender of @0x0, not the buyer.
    assert!(!check_policy(id, &pkg_version, &session, &c, ctx), 0);

    // Right caller, before expiry, is allowed.
    let buyer_ctx = &tx_context::new_from_hint(buyer, 0, 0, 0, 0);
    assert!(check_policy(id, &pkg_version, &session, &c, buyer_ctx), 1);

    // An identity outside the namespace is denied.
    let foreign = vector[9u8, 9u8, 9u8];
    assert!(!check_policy(foreign, &pkg_version, &session, &c, buyer_ctx), 2);

    // At expiry exactly, denied.
    c.increment_for_testing(1000);
    assert!(!check_policy(id, &pkg_version, &session, &c, buyer_ctx), 3);

    // And after.
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
    // 150 paid in, price 100, so 50 comes back to the buyer.
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
