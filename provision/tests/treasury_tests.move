#[test_only]
module cocoon_provision::treasury_tests;

use sui::test_scenario as ts;
use sui::coin;
use sui::sui::SUI;
use sui::clock;
use cocoon_provision::treasury::{Self, Vault};
use cocoon::journey::{Self, Session};

const OPERATOR: address = @0xA1;
const BUYER: address = @0xB0B;
const STRANGER: address = @0x5EA;

public struct WAL has drop {}
public struct JUNK has drop {}

const LAUNCH_PRICE: u64 = 199_990_000;
const TEST_JOURNEY_PRICE: u64 = 1_000;
const PROVISION_SUI: u64 = 11_000_000;
const PROVISION_WAL: u64 = 3_000_000_000;

fun run_claim<C>(price: u64, provisions: u64, approve: bool, claimant: address) {
    let mut s = ts::begin(OPERATOR);
    {
        let ctx = ts::ctx(&mut s);
        let mut vault = treasury::new_vault_for_testing<WAL>(
            vector[treasury::coin_type_string_for_testing<C>()], ctx);
        treasury::fund_for_testing(&mut vault, PROVISION_SUI * provisions, PROVISION_WAL * provisions);
        let j = journey::new_journey_for_testing(OPERATOR, price, 1_000, ctx);
        if (approve) { treasury::approve_for_testing(&mut vault, object::id(&j)); };
        let c = clock::create_for_testing(ctx);
        ts::next_tx(&mut s, claimant);
        let ctx2 = ts::ctx(&mut s);
        let mut pay = coin::mint_for_testing<C>(price, ctx2);
        let receipt = journey::purchase_receipt(&j, &mut pay, &c, ctx2);
        treasury::claim(&mut vault, receipt, ctx2);
        journey::destroy_journey_for_testing(j);
        treasury::destroy_vault_for_testing(vault);
        clock::destroy_for_testing(c);
        coin::burn_for_testing(pay);
    };
    ts::end(s);
}

#[test]
fun a_real_first_time_purchase_is_paid() {
    let mut s = ts::begin(OPERATOR);
    {
        let ctx = ts::ctx(&mut s);
        let mut vault = treasury::new_vault_for_testing<WAL>(
            vector[treasury::coin_type_string_for_testing<SUI>()], ctx);
        treasury::fund_for_testing(&mut vault, PROVISION_SUI * 2, PROVISION_WAL * 2);
        let j = journey::new_journey_for_testing(OPERATOR, LAUNCH_PRICE, 1_000, ctx);
        treasury::approve_for_testing(&mut vault, object::id(&j));
        let c = clock::create_for_testing(ctx);
        ts::next_tx(&mut s, BUYER);
        let ctx2 = ts::ctx(&mut s);
        let mut pay = coin::mint_for_testing<SUI>(LAUNCH_PRICE, ctx2);
        let (sui_before, wal_before) = treasury::balances(&vault);
        let receipt = journey::purchase_receipt(&j, &mut pay, &c, ctx2);
        treasury::claim(&mut vault, receipt, ctx2);
        let (sui_after, wal_after) = treasury::balances(&vault);
        assert!(sui_before - sui_after == PROVISION_SUI, 100);
        assert!(wal_before - wal_after == PROVISION_WAL, 101);
        journey::destroy_journey_for_testing(j);
        treasury::destroy_vault_for_testing(vault);
        clock::destroy_for_testing(c);
        coin::burn_for_testing(pay);
    };
    ts::end(s);
}

#[test]
fun the_session_really_is_shared_by_the_path_these_tests_run() {

    let mut s = ts::begin(OPERATOR);
    {
        let ctx = ts::ctx(&mut s);
        let mut vault = treasury::new_vault_for_testing<WAL>(
            vector[treasury::coin_type_string_for_testing<SUI>()], ctx);
        treasury::fund_for_testing(&mut vault, PROVISION_SUI, PROVISION_WAL);
        let j = journey::new_journey_for_testing(OPERATOR, LAUNCH_PRICE, 1_000, ctx);
        treasury::approve_for_testing(&mut vault, object::id(&j));
        let c = clock::create_for_testing(ctx);
        ts::next_tx(&mut s, BUYER);
        let ctx2 = ts::ctx(&mut s);
        let mut pay = coin::mint_for_testing<SUI>(LAUNCH_PRICE, ctx2);
        let receipt = journey::purchase_receipt(&j, &mut pay, &c, ctx2);
        treasury::claim(&mut vault, receipt, ctx2);
        ts::next_tx(&mut s, BUYER);
        let session = ts::take_shared<Session>(&s);
        assert!(journey::buyer(&session) == BUYER, 110);
        assert!(journey::journey_id(&session) == object::id(&j), 111);
        ts::return_shared(session);
        journey::destroy_journey_for_testing(j);
        treasury::destroy_vault_for_testing(vault);
        clock::destroy_for_testing(c);
        coin::burn_for_testing(pay);
    };
    ts::end(s);
}

#[test]
fun a_returning_buyer_is_paid_again_for_a_second_purchase() {

    let mut s = ts::begin(OPERATOR);
    {
        let ctx = ts::ctx(&mut s);
        let mut vault = treasury::new_vault_for_testing<WAL>(
            vector[treasury::coin_type_string_for_testing<SUI>()], ctx);
        treasury::fund_for_testing(&mut vault, PROVISION_SUI * 2, PROVISION_WAL * 2);
        let j = journey::new_journey_for_testing(OPERATOR, LAUNCH_PRICE, 1_000, ctx);
        treasury::approve_for_testing(&mut vault, object::id(&j));
        let c = clock::create_for_testing(ctx);
        ts::next_tx(&mut s, BUYER);
        let ctx2 = ts::ctx(&mut s);
        let mut pay1 = coin::mint_for_testing<SUI>(LAUNCH_PRICE, ctx2);
        let r1 = journey::purchase_receipt(&j, &mut pay1, &c, ctx2);
        treasury::claim(&mut vault, r1, ctx2);
        let mut pay2 = coin::mint_for_testing<SUI>(LAUNCH_PRICE, ctx2);
        let r2 = journey::purchase_receipt(&j, &mut pay2, &c, ctx2);
        treasury::claim(&mut vault, r2, ctx2);
        let (sui_left, wal_left) = treasury::balances(&vault);
        assert!(sui_left == 0 && wal_left == 0, 200);
        journey::destroy_journey_for_testing(j);
        treasury::destroy_vault_for_testing(vault);
        clock::destroy_for_testing(c);
        coin::burn_for_testing(pay1);
        coin::burn_for_testing(pay2);
    };
    ts::end(s);
}

#[test]
fun two_claims_require_two_payments() {

    let mut s = ts::begin(OPERATOR);
    {
        let ctx = ts::ctx(&mut s);
        let mut vault = treasury::new_vault_for_testing<WAL>(
            vector[treasury::coin_type_string_for_testing<SUI>()], ctx);
        treasury::fund_for_testing(&mut vault, PROVISION_SUI * 2, PROVISION_WAL * 2);
        let j = journey::new_journey_for_testing(OPERATOR, LAUNCH_PRICE, 1_000, ctx);
        treasury::approve_for_testing(&mut vault, object::id(&j));
        let c = clock::create_for_testing(ctx);
        ts::next_tx(&mut s, BUYER);
        let ctx2 = ts::ctx(&mut s);
        let mut pay = coin::mint_for_testing<SUI>(LAUNCH_PRICE * 2, ctx2);
        let r1 = journey::purchase_receipt(&j, &mut pay, &c, ctx2);
        assert!(coin::value(&pay) == LAUNCH_PRICE, 210);
        treasury::claim(&mut vault, r1, ctx2);
        let r2 = journey::purchase_receipt(&j, &mut pay, &c, ctx2);
        assert!(coin::value(&pay) == 0, 211);
        treasury::claim(&mut vault, r2, ctx2);
        journey::destroy_journey_for_testing(j);
        treasury::destroy_vault_for_testing(vault);
        clock::destroy_for_testing(c);
        coin::burn_for_testing(pay);
    };
    ts::end(s);
}

#[test]
#[expected_failure(abort_code = treasury::EJourneyNotApproved)]
fun an_unapproved_journey_earns_nothing() { run_claim<SUI>(LAUNCH_PRICE, 2, false, BUYER); }

#[test]
#[expected_failure(abort_code = treasury::EPriceBelowFloor)]
fun an_approved_journey_below_the_price_floor_earns_nothing() {
    run_claim<SUI>(TEST_JOURNEY_PRICE, 2, true, BUYER);
}

#[test]
#[expected_failure(abort_code = treasury::EInsufficientTreasurySui)]
fun an_empty_float_refuses_on_sui_first() { run_claim<SUI>(LAUNCH_PRICE, 0, true, BUYER); }

#[test]
#[expected_failure(abort_code = treasury::EInsufficientTreasuryWal)]
fun a_float_with_sui_but_no_wal_refuses_on_wal() {

    let mut s = ts::begin(OPERATOR);
    {
        let ctx = ts::ctx(&mut s);
        let mut vault = treasury::new_vault_for_testing<WAL>(
            vector[treasury::coin_type_string_for_testing<SUI>()], ctx);
        treasury::fund_for_testing(&mut vault, PROVISION_SUI * 5, 0);
        let j = journey::new_journey_for_testing(OPERATOR, LAUNCH_PRICE, 1_000, ctx);
        treasury::approve_for_testing(&mut vault, object::id(&j));
        let c = clock::create_for_testing(ctx);
        ts::next_tx(&mut s, BUYER);
        let ctx2 = ts::ctx(&mut s);
        let mut pay = coin::mint_for_testing<SUI>(LAUNCH_PRICE, ctx2);
        let receipt = journey::purchase_receipt(&j, &mut pay, &c, ctx2);
        treasury::claim(&mut vault, receipt, ctx2);
        journey::destroy_journey_for_testing(j);
        treasury::destroy_vault_for_testing(vault);
        clock::destroy_for_testing(c);
        coin::burn_for_testing(pay);
    };
    ts::end(s);
}

#[test]
#[expected_failure(abort_code = treasury::ECoinNotAccepted)]
fun a_purchase_in_an_unaccepted_currency_earns_nothing() {

    let mut s = ts::begin(OPERATOR);
    {
        let ctx = ts::ctx(&mut s);
        let mut vault = treasury::new_vault_for_testing<WAL>(
            vector[treasury::coin_type_string_for_testing<SUI>()], ctx);
        treasury::fund_for_testing(&mut vault, PROVISION_SUI * 2, PROVISION_WAL * 2);
        let j = journey::new_journey_for_testing(OPERATOR, LAUNCH_PRICE, 1_000, ctx);
        treasury::approve_for_testing(&mut vault, object::id(&j));
        let c = clock::create_for_testing(ctx);
        ts::next_tx(&mut s, BUYER);
        let ctx2 = ts::ctx(&mut s);
        let mut pay = coin::mint_for_testing<JUNK>(LAUNCH_PRICE, ctx2);
        let receipt = journey::purchase_receipt(&j, &mut pay, &c, ctx2);
        treasury::claim(&mut vault, receipt, ctx2);
        journey::destroy_journey_for_testing(j);
        treasury::destroy_vault_for_testing(vault);
        clock::destroy_for_testing(c);
        coin::burn_for_testing(pay);
    };
    ts::end(s);
}

#[test]
#[expected_failure(abort_code = treasury::ENotBuyer)]
fun a_stranger_cannot_claim_a_receipt_from_someone_elses_payment() {

    let mut s = ts::begin(OPERATOR);
    {
        let ctx = ts::ctx(&mut s);
        let mut vault = treasury::new_vault_for_testing<WAL>(
            vector[treasury::coin_type_string_for_testing<SUI>()], ctx);
        treasury::fund_for_testing(&mut vault, PROVISION_SUI * 2, PROVISION_WAL * 2);
        let j = journey::new_journey_for_testing(OPERATOR, LAUNCH_PRICE, 1_000, ctx);
        treasury::approve_for_testing(&mut vault, object::id(&j));
        let c = clock::create_for_testing(ctx);
        ts::next_tx(&mut s, BUYER);
        let ctx2 = ts::ctx(&mut s);
        let mut pay = coin::mint_for_testing<SUI>(LAUNCH_PRICE, ctx2);
        let receipt = journey::purchase_receipt(&j, &mut pay, &c, ctx2);
        ts::next_tx(&mut s, STRANGER);
        let ctx3 = ts::ctx(&mut s);
        treasury::claim(&mut vault, receipt, ctx3);
        journey::destroy_journey_for_testing(j);
        treasury::destroy_vault_for_testing(vault);
        clock::destroy_for_testing(c);
        coin::burn_for_testing(pay);
    };
    ts::end(s);
}

#[test]
#[expected_failure(abort_code = treasury::ESuperseded)]
fun the_retired_v1_claim_provision_always_aborts() {

    let mut s = ts::begin(OPERATOR);
    {
        let ctx = ts::ctx(&mut s);
        let mut vault = treasury::new_vault_for_testing<WAL>(
            vector[treasury::coin_type_string_for_testing<SUI>()], ctx);
        treasury::fund_for_testing(&mut vault, PROVISION_SUI, PROVISION_WAL);
        let j = journey::new_journey_for_testing(OPERATOR, LAUNCH_PRICE, 1_000, ctx);
        treasury::approve_for_testing(&mut vault, object::id(&j));
        let c = clock::create_for_testing(ctx);
        ts::next_tx(&mut s, BUYER);
        let ctx2 = ts::ctx(&mut s);
        let mut pay = coin::mint_for_testing<SUI>(LAUNCH_PRICE, ctx2);
        let receipt = journey::purchase_receipt(&j, &mut pay, &c, ctx2);
        ts::next_tx(&mut s, BUYER);
        let session = ts::take_shared<Session>(&s);
        treasury::claim_provision(&mut vault, receipt, &session, ts::ctx(&mut s));
        ts::return_shared(session);
        journey::destroy_journey_for_testing(j);
        treasury::destroy_vault_for_testing(vault);
        clock::destroy_for_testing(c);
        coin::burn_for_testing(pay);
    };
    ts::end(s);
}

#[test]
fun a_vault_accepts_only_the_currencies_it_was_born_with() {

    let mut s = ts::begin(OPERATOR);
    {
        let ctx = ts::ctx(&mut s);
        let sui_vault = treasury::new_vault_for_testing<WAL>(
            vector[treasury::coin_type_string_for_testing<SUI>()], ctx);
        let junk_vault = treasury::new_vault_for_testing<WAL>(
            vector[treasury::coin_type_string_for_testing<JUNK>()], ctx);
        assert!(treasury::is_accepted_coin_for_testing<WAL, SUI>(&sui_vault), 300);
        assert!(!treasury::is_accepted_coin_for_testing<WAL, JUNK>(&sui_vault), 301);
        assert!(treasury::is_accepted_coin_for_testing<WAL, JUNK>(&junk_vault), 302);
        assert!(!treasury::is_accepted_coin_for_testing<WAL, SUI>(&junk_vault), 303);
        treasury::destroy_vault_for_testing(sui_vault);
        treasury::destroy_vault_for_testing(junk_vault);
    };
    ts::end(s);
}

#[test]
fun a_vault_born_with_the_production_list_accepts_exactly_those_two() {
    let mut s = ts::begin(OPERATOR);
    {
        let ctx = ts::ctx(&mut s);
        let (usdc, usdsui) = treasury::production_coin_types();
        let v = treasury::new_vault_for_testing<WAL>(vector[usdc, usdsui], ctx);
        assert!(treasury::is_coin_accepted(&v, usdc), 320);
        assert!(treasury::is_coin_accepted(&v, usdsui), 321);
        assert!(!treasury::is_accepted_coin_for_testing<WAL, SUI>(&v), 322);
        assert!(!treasury::is_accepted_coin_for_testing<WAL, JUNK>(&v), 323);
        treasury::destroy_vault_for_testing(v);
    };
    ts::end(s);
}

#[test]
fun the_accepted_type_strings_are_exactly_the_two_real_ones() {
    let (usdc, usdsui) = treasury::production_coin_types();
    assert!(usdc == b"dba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC", 330);
    assert!(usdsui == b"44f838219cf67b058f3b37907b655f226153c18e33dfcd0da559a844fea9b1c1::usdsui::USDSUI", 331);
}

#[test]
fun a_new_vault_approves_no_journey() {
    let mut s = ts::begin(OPERATOR);
    {
        let ctx = ts::ctx(&mut s);
        let vault = treasury::new_vault_for_testing<WAL>(
            vector[treasury::coin_type_string_for_testing<SUI>()], ctx);
        let j = journey::new_journey_for_testing(OPERATOR, LAUNCH_PRICE, 1_000, ctx);
        assert!(!treasury::is_journey_approved(&vault, object::id(&j)), 400);
        journey::destroy_journey_for_testing(j);
        treasury::destroy_vault_for_testing(vault);
    };
    ts::end(s);
}

#[test]
fun the_provision_amounts_are_what_we_think() {
    let (sui_amt, wal_amt) = treasury::provision_amounts();
    assert!(sui_amt == PROVISION_SUI, 500);
    assert!(wal_amt == PROVISION_WAL, 501);
    assert!(treasury::min_qualifying_price() == 50_000_000, 502);
}

#[test]
fun the_dead_claimed_counter_stays_zero_even_after_a_real_claim() {

    let mut s = ts::begin(OPERATOR);
    {
        let ctx = ts::ctx(&mut s);
        let mut vault = treasury::new_vault_for_testing<WAL>(
            vector[treasury::coin_type_string_for_testing<SUI>()], ctx);
        treasury::fund_for_testing(&mut vault, PROVISION_SUI, PROVISION_WAL);
        let j = journey::new_journey_for_testing(OPERATOR, LAUNCH_PRICE, 1_000, ctx);
        treasury::approve_for_testing(&mut vault, object::id(&j));
        let c = clock::create_for_testing(ctx);
        ts::next_tx(&mut s, BUYER);
        let ctx2 = ts::ctx(&mut s);
        let mut pay = coin::mint_for_testing<SUI>(LAUNCH_PRICE, ctx2);
        let receipt = journey::purchase_receipt(&j, &mut pay, &c, ctx2);
        treasury::claim(&mut vault, receipt, ctx2);
        let (sui_left, _) = treasury::balances(&vault);
        assert!(sui_left == 0, 520);
        assert!(treasury::claimed_count(&vault) == 0, 521);
        journey::destroy_journey_for_testing(j);
        treasury::destroy_vault_for_testing(vault);
        clock::destroy_for_testing(c);
        coin::burn_for_testing(pay);
    };
    ts::end(s);
}

#[test]
#[expected_failure(abort_code = treasury::EWrongVersion)]
fun an_old_package_cannot_claim_against_a_migrated_vault() {
    let mut s = ts::begin(OPERATOR);
    {
        let ctx = ts::ctx(&mut s);
        let mut vault = treasury::new_vault_at_version_for_testing<WAL>(
            99, vector[treasury::coin_type_string_for_testing<SUI>()], ctx);
        treasury::fund_for_testing(&mut vault, PROVISION_SUI, PROVISION_WAL);
        let j = journey::new_journey_for_testing(OPERATOR, LAUNCH_PRICE, 1_000, ctx);
        treasury::approve_for_testing(&mut vault, object::id(&j));
        let c = clock::create_for_testing(ctx);
        ts::next_tx(&mut s, BUYER);
        let ctx2 = ts::ctx(&mut s);
        let mut pay = coin::mint_for_testing<SUI>(LAUNCH_PRICE, ctx2);
        let receipt = journey::purchase_receipt(&j, &mut pay, &c, ctx2);
        treasury::claim(&mut vault, receipt, ctx2);
        journey::destroy_journey_for_testing(j);
        treasury::destroy_vault_for_testing(vault);
        clock::destroy_for_testing(c);
        coin::burn_for_testing(pay);
    };
    ts::end(s);
}

#[test]
#[expected_failure(abort_code = treasury::EWrongVersion)]
fun an_old_package_cannot_withdraw_from_a_migrated_vault() {
    let mut s = ts::begin(OPERATOR);
    {
        let ctx = ts::ctx(&mut s);
        let mut vault = treasury::new_vault_at_version_for_testing<WAL>(
            99, vector[treasury::coin_type_string_for_testing<SUI>()], ctx);
        treasury::fund_for_testing(&mut vault, PROVISION_SUI, PROVISION_WAL);
        treasury::withdraw_for_testing(&mut vault, PROVISION_SUI, PROVISION_WAL, ctx);
        treasury::destroy_vault_for_testing(vault);
    };
    ts::end(s);
}

#[test]
#[expected_failure(abort_code = treasury::EWrongVersion)]
fun an_old_package_cannot_deposit_into_a_migrated_vault() {
    let mut s = ts::begin(OPERATOR);
    {
        let ctx = ts::ctx(&mut s);
        let mut vault = treasury::new_vault_at_version_for_testing<WAL>(
            99, vector[treasury::coin_type_string_for_testing<SUI>()], ctx);
        treasury::deposit_sui(&mut vault, coin::mint_for_testing<SUI>(1, ctx));
        treasury::destroy_vault_for_testing(vault);
    };
    ts::end(s);
}

#[test]
#[expected_failure(abort_code = treasury::EWrongVersion)]
fun an_old_package_cannot_reconfigure_a_migrated_vault() {
    let mut s = ts::begin(OPERATOR);
    {
        let ctx = ts::ctx(&mut s);
        let mut vault = treasury::new_vault_at_version_for_testing<WAL>(
            99, vector[treasury::coin_type_string_for_testing<SUI>()], ctx);
        let j = journey::new_journey_for_testing(OPERATOR, LAUNCH_PRICE, 1_000, ctx);
        treasury::set_journey_approved_for_testing(&mut vault, object::id(&j), true);
        journey::destroy_journey_for_testing(j);
        treasury::destroy_vault_for_testing(vault);
    };
    ts::end(s);
}

#[test]
fun a_fresh_vault_is_stamped_with_the_running_version_and_works() {

    let mut s = ts::begin(OPERATOR);
    {
        let ctx = ts::ctx(&mut s);
        let mut vault = treasury::new_vault_for_testing<WAL>(
            vector[treasury::coin_type_string_for_testing<SUI>()], ctx);
        assert!(treasury::vault_version(&vault) == treasury::package_version(), 600);
        treasury::deposit_sui(&mut vault, coin::mint_for_testing<SUI>(1, ctx));
        treasury::destroy_vault_for_testing(vault);
    };
    ts::end(s);
}

#[test]
fun migrate_moves_a_v1_vault_forward_and_then_refuses_to_run_again() {

    let mut s = ts::begin(OPERATOR);
    {
        let ctx = ts::ctx(&mut s);
        let mut vault = treasury::new_vault_at_version_for_testing<WAL>(
            1, vector[treasury::coin_type_string_for_testing<SUI>()], ctx);
        assert!(treasury::vault_version(&vault) == 1, 610);
        treasury::migrate_for_testing(&mut vault);
        assert!(treasury::vault_version(&vault) == 2, 611);
        treasury::deposit_sui(&mut vault, coin::mint_for_testing<SUI>(1, ctx));
        treasury::destroy_vault_for_testing(vault);
    };
    ts::end(s);
}

#[test]
#[expected_failure(abort_code = treasury::EWrongVersion)]
fun migrate_refuses_a_vault_already_at_the_running_version() {
    let mut s = ts::begin(OPERATOR);
    {
        let ctx = ts::ctx(&mut s);
        let mut vault = treasury::new_vault_for_testing<WAL>(
            vector[treasury::coin_type_string_for_testing<SUI>()], ctx);
        treasury::migrate_for_testing(&mut vault);
        treasury::destroy_vault_for_testing(vault);
    };
    ts::end(s);
}
