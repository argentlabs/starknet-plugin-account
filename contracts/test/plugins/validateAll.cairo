%lang starknet
from starkware.cairo.common.cairo_builtins import HashBuiltin, SignatureBuiltin
from starkware.cairo.common.bool import TRUE, FALSE
from contracts.account.IPluginAccount import CallArray
from starkware.starknet.common.syscalls import (
    get_tx_info,
    get_contract_address,
    get_caller_address,
)

@external
func initialize{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(plugin_data_len: felt, plugin_data: felt*) {
    return ();
}

@external
func uninstall{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(plugin_data_len: felt, plugin_data: felt*) {
    return ();
}

@view
func supportsInterface{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    interfaceId: felt
) -> (success: felt) {
    // 165
    if (interfaceId == 0x01ffc9a7) {
        return (TRUE,);
    }
    return (FALSE,);
}

@view
func validate{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, ecdsa_ptr: SignatureBuiltin*
}(
    call_array_len: felt,
    call_array: CallArray*,
    calldata_len: felt,
    calldata: felt*,
) {
    return ();
}

@view
func is_valid_signature{
    syscall_ptr : felt*,
    pedersen_ptr : HashBuiltin*,
    range_check_ptr,
    ecdsa_ptr: SignatureBuiltin*
}(
    hash: felt,
    signature_len: felt,
    signature: felt*
) -> (is_valid: felt) {
    return (is_valid=TRUE);
}