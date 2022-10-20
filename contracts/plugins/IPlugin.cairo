%lang starknet

from contracts.account.library import Call, CallArray

@contract_interface
namespace IPlugin {

    func initialize(data_len: felt, data: felt*) {
    }

    func validate(
        hash: felt, 
        sig_len: felt,
        sig: felt*,
        call_array_len: felt,
        call_array: CallArray*,
        calldata_len: felt,
        calldata: felt*,
    ) {
    }

    func execute(
        call_array_len: felt,
        call_array: CallArray*,
        calldata_len: felt,
        calldata: felt*,
    ) -> (
        call_array_len: felt,
        call_array: CallArray*,
        calldata_len: felt,
        calldata: felt*, 
        response_len: felt, 
        response: felt*
    ) {
    }
}
