%lang starknet

// Tmp struct introduced while we wait for Cairo
// to support passing `[Call]` to __execute__
struct CallArray {
    to: felt,
    selector: felt,
    data_offset: felt,
    data_len: felt,
}

@contract_interface
namespace IPluginAccount {

    /////////////////////
    // Plugin
    /////////////////////

    func addPlugin(plugin: felt, plugin_calldata_len: felt, plugin_calldata: felt*) {
    }

    func removePlugin(plugin: felt) {
    }

    func isPlugin(plugin: felt) -> (success: felt) {
    }


    func executeOnPlugin(
        plugin: felt, selector: felt, calldata_len: felt, calldata: felt*
    ) -> (retdata_len: felt, retdata: felt*){
    }

    /////////////////////
    // IAccount
    /////////////////////

    func upgrade(implementation: felt) {
    }

    func supportsInterface(interfaceId: felt) -> (success: felt) {
    }

    func isValidSignature(hash: felt, signature_len: felt, signature: felt*) -> (isValid: felt) {
    }

    func __validate__(
        call_array_len: felt,
        call_array: CallArray*,
        calldata_len: felt,
        calldata: felt*
    ) {
    }

    // Parameter temporarily named `cls_hash` instead of `class_hash` (expected).
    // See https://github.com/starkware-libs/cairo-lang/issues/100 for details.
    func __validate_declare__(cls_hash: felt) {
    }

    // Parameter temporarily named `cls_hash` instead of `class_hash` (expected).
    // See https://github.com/starkware-libs/cairo-lang/issues/100 for details.
    func __validate_deploy__(
        cls_hash: felt, ctr_args_len: felt, ctr_args: felt*, salt: felt
    ) {
    }

    func __execute__(
        call_array_len: felt,
        call_array: CallArray*,
        calldata_len: felt,
        calldata: felt*
    ) -> (response_len: felt, response: felt*) {
    }
}
