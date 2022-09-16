%lang starknet

from contracts.account.library import CallArray

@contract_interface
namespace IPluginAccount {

    /////////////////////
    // Plugin
    /////////////////////

    func addPlugin(plugin: felt) {
    }

    func removePlugin(plugin: felt) {
    }

    func setDefaultPlugin(plugin: felt, plugin_calldata_len: felt, plugin_calldata: felt*) {
    }

    func isPlugin(plugin: felt) -> (success: felt) {
    }

    func readOnPlugin(plugin: felt, selector: felt, calldata_len: felt, calldata: felt*) {
    }

    func getDefaultPlugin() -> (plugin: felt) {
    }

    /////////////////////
    // IAccount
    /////////////////////

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

    func __validate_declare__(class_hash: felt) {
    }

    func __execute__(
        call_array_len: felt,
        call_array: CallArray*,
        calldata_len: felt,
        calldata: felt*
    ) -> (response_len: felt, response: felt*) {
    }
}
