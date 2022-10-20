%lang starknet

from starkware.cairo.common.cairo_builtins import HashBuiltin, SignatureBuiltin
from starkware.cairo.common.signature import verify_ecdsa_signature
from starkware.cairo.common.hash_state import (
    HashState,
    hash_finalize,
    hash_init,
    hash_update,
    hash_update_single,
)
from starkware.cairo.common.hash import hash2
from starkware.cairo.common.math_cmp import is_le_felt
from starkware.cairo.common.registers import get_fp_and_pc
from starkware.cairo.common.alloc import alloc
from starkware.cairo.common.bool import TRUE, FALSE
from starkware.cairo.common.math import assert_not_zero, assert_nn
from starkware.starknet.common.syscalls import (
    call_contract,
    get_tx_info,
    get_contract_address,
    get_caller_address,
    get_block_timestamp,
)
from contracts.account.library import Call, CallArray


// H('StarkNetDomain(chainId:felt)')
const STARKNET_DOMAIN_TYPE_HASH = 0x13cda234a04d66db62c06b8e3ad5f91bd0c67286c2c7519a826cf49da6ba478;
// H('Session(key:felt,expires:felt,root:merkletree)')
const SESSION_TYPE_HASH = 0x1aa0e1c56b45cf06a54534fa1707c54e520b842feb21d03b7deddb6f1e340c;
// H(Policy(contractAddress:felt,selector:selector))
const POLICY_TYPE_HASH = 0x2f0026e78543f036f33e26a8f5891b88c58dc1e20cbbfaf0bb53274da6fa568;

@contract_interface
namespace IAccount {
    func isValidSignature(hash: felt, sig_len: felt, sig: felt*) {
    }
}

@event
func session_key_revoked(session_key: felt) {
}

@storage_var
func SessionKey_revoked_keys(key: felt) -> (res: felt) {
}

@external
func validate{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, ecdsa_ptr: SignatureBuiltin*, range_check_ptr
}(
    hash: felt, 
    sig_len: felt,
    sig: felt*,
    call_array_len: felt,
    call_array: CallArray*,
    calldata_len: felt,
    calldata: felt*,
) {
    alloc_locals;

    // get the tx info
    let (tx_info) = get_tx_info();

    // parse the plugin data
    with_attr error_message("SessionKey: invalid plugin data") {
        let sig_r = sig[0];
        let sig_s = sig[1];
        let session_key = [sig + 2];
        let session_expires = [sig + 3];
        let root = [sig + 6];
        let proof_len = [sig + 7];
        let proofs_len = [sig + 8];
        let proofs = sig + 9;
    }

    with_attr error_message("SessionKey: session expired") {
        let (now) = get_block_timestamp();
        assert_nn(session_expires - now);
    }

        let (session_hash) = compute_session_hash(
            session_key, session_expires, root, tx_info.chain_id, tx_info.account_contract_address
        );    
        with_attr error_message("SessionKey: unauthorised session") {
        IAccount.isValidSignature(
            contract_address=tx_info.account_contract_address,
            hash=session_hash,
            sig_len=2,
            sig=sig + 4,
        );
    }
    // check if the session key is revoked
    with_attr error_message("SessionKey: session key revoked") {
        let (is_revoked) = SessionKey_revoked_keys.read(session_key);
        assert is_revoked = 0;
    }
    // check if the tx is signed by the session key
    with_attr error_message("SessionKey: invalid signature") {
        verify_ecdsa_signature(
            message=tx_info.transaction_hash,
            public_key=session_key,
            signature_r=sig_r,
            signature_s=sig_s,
        );
    }

    /////////////// TMP /////////////////////
    // parse inputs to an array of 'Call' struct
    let (calls: Call*) = alloc();
    from_call_array_to_call(call_array_len, call_array, calldata, calls);
    let calls_len = call_array_len;
    //////////////////////////////////////////

    check_policy(calls_len, calls, root, proof_len, proofs_len, proofs);

    return ();
}

@external
func execute(
    call_array_len: felt,
    call_array: CallArray*,
    calldata_len: felt,
    calldata: felt*,
) -> (
    call_array_len: felt,
    call_array: CallArray*,
    calldata_len: felt,
    calldata: felt*, response_len: felt, response: felt*) {
    let (response: felt*) = alloc();
    return (call_array_len, call_array, calldata_len, calldata, 0, response);
}

@external
func revokeSessionKey{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    session_key: felt
) {
    SessionKey_revoked_keys.write(session_key, 1);
    session_key_revoked.emit(session_key);
    return ();
}

/////////////////////
// INTERNAL FUNCTIONS
/////////////////////

func check_policy{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, ecdsa_ptr: SignatureBuiltin*, range_check_ptr
}(
    calls_len: felt,
    calls: Call*,
    root: felt,
    proof_len: felt,
    proofs_len: felt,
    proofs: felt*,
) {
    alloc_locals;

    if (calls_len == 0) {
        return ();
    }

    let hash_ptr = pedersen_ptr;
    with hash_ptr {
        let (hash_state) = hash_init();
        let (hash_state) = hash_update_single(hash_state_ptr=hash_state, item=POLICY_TYPE_HASH);
        let (hash_state) = hash_update_single(hash_state_ptr=hash_state, item=[calls].to);
        let (hash_state) = hash_update_single(
            hash_state_ptr=hash_state, item=[calls].selector
        );
        let (leaf) = hash_finalize(hash_state_ptr=hash_state);
        let pedersen_ptr = hash_ptr;
    }

    let (proof_valid) = merkle_verify(leaf, root, proof_len, proofs);
    with_attr error_message("SessionKey: not allowed by policy") {
        assert proof_valid = TRUE;
    }
    check_policy(
        calls_len - 1,
        calls + Call.SIZE,
        root,
        proof_len,
        proofs_len - proof_len,
        proofs + proof_len,
    );
    return ();
}

func compute_session_hash{pedersen_ptr: HashBuiltin*}(
    session_key: felt, session_expires: felt, root: felt, chain_id: felt, account: felt
) -> (hash: felt) {
    alloc_locals;
    let hash_ptr = pedersen_ptr;
    with hash_ptr {
        let (hash_state) = hash_init();
        let (hash_state) = hash_update_single(hash_state_ptr=hash_state, item='StarkNet Message');
        let (domain_hash) = hash_domain(chain_id);
        let (hash_state) = hash_update_single(hash_state_ptr=hash_state, item=domain_hash);
        let (hash_state) = hash_update_single(hash_state_ptr=hash_state, item=account);
        let (message_hash) = hash_message(session_key, session_expires, root);
        let (hash_state) = hash_update_single(hash_state_ptr=hash_state, item=message_hash);
        let (hash) = hash_finalize(hash_state_ptr=hash_state);
        let pedersen_ptr = hash_ptr;
    }
    return (hash=hash);
}

func hash_domain{hash_ptr: HashBuiltin*}(chain_id: felt) -> (hash: felt) {
    let (hash_state) = hash_init();
    let (hash_state) = hash_update_single(
        hash_state_ptr=hash_state, item=STARKNET_DOMAIN_TYPE_HASH
    );
    let (hash_state) = hash_update_single(hash_state_ptr=hash_state, item=chain_id);
    let (hash) = hash_finalize(hash_state_ptr=hash_state);
    return (hash=hash);
}

func hash_message{hash_ptr: HashBuiltin*}(session_key: felt, session_expires: felt, root: felt) -> (
    hash: felt
) {
    let (hash_state) = hash_init();
    let (hash_state) = hash_update_single(hash_state_ptr=hash_state, item=SESSION_TYPE_HASH);
    let (hash_state) = hash_update_single(hash_state_ptr=hash_state, item=session_key);
    let (hash_state) = hash_update_single(hash_state_ptr=hash_state, item=session_expires);
    let (hash_state) = hash_update_single(hash_state_ptr=hash_state, item=root);
    let (hash) = hash_finalize(hash_state_ptr=hash_state);
    return (hash=hash);
}

func merkle_verify{pedersen_ptr: HashBuiltin*, range_check_ptr}(
    leaf: felt, root: felt, proof_len: felt, proof: felt*
) -> (res: felt) {
    let (calc_root) = calc_merkle_root(leaf, proof_len, proof);
    // check if calculated root is equal to expected
    if (calc_root == root) {
        return (TRUE,);
    } else {
        return (FALSE,);
    }
}

// calculates the merkle root of a given proof
func calc_merkle_root{pedersen_ptr: HashBuiltin*, range_check_ptr}(
    curr: felt, proof_len: felt, proof: felt*
) -> (res: felt) {
    alloc_locals;

    if (proof_len == 0) {
        return (curr,);
    }

    local node;
    local proof_elem = [proof];
    let le = is_le_felt(curr, proof_elem);

    if (le == 1) {
        let (n) = hash2{hash_ptr=pedersen_ptr}(curr, proof_elem);
        node = n;
    } else {
        let (n) = hash2{hash_ptr=pedersen_ptr}(proof_elem, curr);
        node = n;
    }

    let (res) = calc_merkle_root(node, proof_len - 1, proof + 1);
    return (res,);
}

func from_call_array_to_call{syscall_ptr: felt*}(
    call_array_len: felt, call_array: CallArray*, calldata: felt*, calls: Call*
) {
    // if no more calls
    if (call_array_len == 0) {
        return ();
    }

    // parse the current call
    assert [calls] = Call(
        to=[call_array].to,
        selector=[call_array].selector,
        calldata_len=[call_array].data_len,
        calldata=calldata + [call_array].data_offset
        );

    // parse the remaining calls recursively
    from_call_array_to_call(
        call_array_len - 1, call_array + CallArray.SIZE, calldata, calls + Call.SIZE
    );
    return ();
}
