%lang starknet

from contracts.account.library import CallArray

@contract_interface
namespace IPluginAccount {

    /////////////////////
    // Plugin
    /////////////////////

    // Add a plugin
    func addPlugin(plugin: felt) {
    }

    // Remove an existing plugin
    func removePlugin(plugin: felt) {
    }

    // Execute a library_call on a plugin to e.g. store some data in storage
    func executeOnPlugin(plugin: felt, selector: felt, calldata_len: felt, calldata: felt*) {
    }

    // Check is a plugin is enabled on the account
    func isPlugin(plugin: felt) -> (success: felt) {
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
