%lang starknet

from contracts.account.IPluginAccount import CallArray

@contract_interface
namespace IPlugin {

    func initialize(data_len: felt, data: felt*) {
    }

    func uninstall(data_len: felt, data: felt*) {
    }

    func validate(
        call_array_len: felt,
        call_array: CallArray*,
        calldata_len: felt,
        calldata: felt*,
    ) {
    }

    func is_valid_signature(hash: felt, sig_len: felt, sig: felt*) -> (isValid: felt) {
    }

    func supportsInterface(interfaceId: felt) -> (success: felt) {
    }
}