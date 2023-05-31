%lang starknet

from starkware.cairo.common.cairo_builtins import HashBuiltin, SignatureBuiltin, BitwiseBuiltin
from starkware.cairo.common.memcpy import memcpy
from contracts.account.IPluginAccount import CallArray
from starkware.cairo.common.alloc import alloc
from starkware.starknet.common.syscalls import (
    call_contract
)

// Enumeration of possible CallData prefix
struct CallDataType {
    VALUE: felt,
    REF: felt,
    CALL_REF: felt,
    FUNC: felt,
    FUNC_CALL: felt,
}


@view
func validate{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr, ecdsa_ptr: SignatureBuiltin*
}(
    hash: felt, 
    sig_len: felt,
    sig: felt*,
    call_array_len: felt,
    call_array: CallArray*,
    calldata_len: felt,
    calldata: felt*,
) {
    with_attr error_message("BetterMultiCall: cannot be used to validate transaction") {
        assert 1 = 2;
    }
    return ();
}

@external
func initialize{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(plugin_data_len: felt, plugin_data: felt*) {
    return ();
}

@external
func execute{
    syscall_ptr: felt*,
    pedersen_ptr: HashBuiltin*,
    ecdsa_ptr: SignatureBuiltin*,
    bitwise_ptr: BitwiseBuiltin*,
    range_check_ptr,
}(call_array_len: felt, call_array: CallArray*, calldata_len: felt, calldata: felt*) -> (
    call_array_len: felt,
    call_array: CallArray*,
    calldata_len: felt,
    calldata: felt*,
    response_len: felt, 
    response: felt*
) {
    let (offsets_len, offsets: felt*, response_len, response: felt*) = rec_execute(
        call_array_len, call_array, calldata
    );
    return (call_array_len, call_array, calldata_len, calldata, response_len, response);
}


func rec_execute{
    syscall_ptr: felt*,
    pedersen_ptr: HashBuiltin*,
    ecdsa_ptr: SignatureBuiltin*,
    bitwise_ptr: BitwiseBuiltin*,
    range_check_ptr,
}(call_array_len: felt, call_array: CallArray*, calldata: felt*) -> (
    offsets_len: felt, offsets: felt*, response_len: felt, response: felt*
) {
    alloc_locals;
    if (call_array_len == 0) {
        let (response) = alloc();
        let (offsets) = alloc();
        assert offsets[0] = 0;
        return (1, offsets, 0, response);
    }

    // call recursively all previous calls
    let (offsets_len, offsets: felt*, response_len, response: felt*) = rec_execute(
        call_array_len - 1, call_array, calldata
    );

    // handle the last call
    let last_call = call_array[call_array_len - 1];

    let (inputs: felt*) = alloc();
    compile_call_inputs(
        inputs, last_call.data_len, calldata + last_call.data_offset, offsets_len, offsets, response
    );

    // call the last call
    let res = call_contract(
        contract_address=last_call.to,
        function_selector=last_call.selector,
        calldata_size=last_call.data_len,
        calldata=inputs,
    );

    // store response data
    memcpy(response + response_len, res.retdata, res.retdata_size);
    assert offsets[offsets_len] = res.retdata_size + offsets[offsets_len - 1];
    return (offsets_len + 1, offsets, response_len + res.retdata_size, response);
}

func compile_call_inputs{syscall_ptr: felt*}(
    inputs: felt*,
    call_len,
    shifted_calldata: felt*,
    offsets_len: felt,
    offsets: felt*,
    response: felt*,
) -> () {
    if (call_len == 0) {
        return ();
    }

    tempvar type = [shifted_calldata];
    if (type == CallDataType.VALUE) {
        // 1 -> value
        assert [inputs] = shifted_calldata[1];
        return compile_call_inputs(
            inputs + 1, call_len - 1, shifted_calldata + 2, offsets_len, offsets, response
        );
    }

    if (type == CallDataType.REF) {
        // 1 -> shift
        assert [inputs] = response[shifted_calldata[1]];
        return compile_call_inputs(
            inputs + 1, call_len - 1, shifted_calldata + 2, offsets_len, offsets, response
        );
    }

    if (type == CallDataType.CALL_REF) {
        // 1 -> call_id, 2 -> shift
        let call_id = shifted_calldata[1];
        let shift = shifted_calldata[2];
        let call_shift = offsets[call_id];

        let value = response[offsets[shifted_calldata[1]] + shifted_calldata[2]];
        assert [inputs] = value;
        return compile_call_inputs(
            inputs + 1, call_len - 1, shifted_calldata + 3, offsets_len, offsets, response
        );
    }

    // should not be called (todo: put the default case)
    assert 1 = 0;
    ret;
}