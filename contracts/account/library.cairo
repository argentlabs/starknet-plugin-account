%lang starknet

from starkware.cairo.common.cairo_builtins import HashBuiltin, SignatureBuiltin
from starkware.cairo.common.alloc import alloc
from starkware.cairo.common.memcpy import memcpy
from starkware.cairo.common.math import assert_not_zero, assert_not_equal
from starkware.starknet.common.syscalls import (
    library_call,
    call_contract,
    get_tx_info,
    get_contract_address,
    get_caller_address,
)
from starkware.cairo.common.bool import TRUE, FALSE
from contracts.account.IPluginAccount import CallArray

const ERC165_ACCOUNT_INTERFACE_ID = 0x3943f10f;
const TRANSACTION_VERSION = 1;
const QUERY_VERSION = 2**128 + TRANSACTION_VERSION;

struct Call {
    to: felt,
    selector: felt,
    calldata_len: felt,
    calldata: felt*,
}

/////////////////////
// INTERFACES
/////////////////////

@contract_interface
namespace IPlugin {
    func initialize(data_len: felt, data: felt*) {
    }

    func is_valid_signature(hash: felt, sig_len: felt, sig: felt*) -> (isValid: felt) {
    }

    func supportsInterface(interfaceId: felt) -> (success: felt) {
    }

    func validate(
        call_array_len: felt,
        call_array: CallArray*,
        calldata_len: felt,
        calldata: felt*,
    ) {
    }
}

/////////////////////
// EVENTS
/////////////////////

@event
func account_created(account: felt) {
}

@event
func transaction_executed(hash: felt, response_len: felt, response: felt*) {
}

/////////////////////
// STORAGE VARIABLES
/////////////////////

@storage_var
func PluginAccount_plugins(plugin: felt) -> (res: felt) {
}

@storage_var
func PluginAccount_initialized() -> (res: felt) {
}

namespace PluginAccount {
    func initializer{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
        plugin: felt, plugin_calldata_len: felt, plugin_calldata: felt*
    ) {
        let (initialized) = PluginAccount_initialized.read();
        with_attr error_message("PluginAccount: already initialized") {
            assert initialized = 0;
        }

        with_attr error_message("PluginAccount: plugin cannot be null") {
            assert_not_zero(plugin);
        }

        PluginAccount_plugins.write(plugin, 1);
        PluginAccount_initialized.write(1);

        initialize_plugin(plugin, plugin_calldata_len, plugin_calldata);

        return ();
    }

    func validate{
        syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, ecdsa_ptr: SignatureBuiltin*, range_check_ptr
    }(
        call_array_len: felt, call_array: CallArray*, calldata_len: felt, calldata: felt*
    ) {
        alloc_locals;
        
        let (tx_info) = get_tx_info();
        assert_correct_tx_version(tx_info.version);
        assert_initialized();

        let (plugin) = get_plugin_from_signature(tx_info.signature_len, tx_info.signature);

        IPlugin.library_call_validate(
            class_hash=plugin,
            call_array_len=call_array_len,
            call_array=call_array,
            calldata_len=calldata_len,
            calldata=calldata,
        );
        return ();
    }

    func validate_deploy{
        syscall_ptr: felt*,
        pedersen_ptr: HashBuiltin*,
        ecdsa_ptr: SignatureBuiltin*,
        range_check_ptr
    }() {
        alloc_locals;
        let (tx_info) = get_tx_info();
        let (is_valid) = is_valid_signature(tx_info.transaction_hash, tx_info.signature_len, tx_info.signature);
        with_attr error_message("PluginAccount: invalid deploy") {
            assert_not_zero(is_valid);
        }
        return ();
    }

    func validate_declare{
        syscall_ptr: felt*,
        pedersen_ptr: HashBuiltin*,
        ecdsa_ptr: SignatureBuiltin*,
        range_check_ptr
    }() {
        alloc_locals;
        let (tx_info) = get_tx_info();
        let (is_valid) = is_valid_signature(tx_info.transaction_hash, tx_info.signature_len, tx_info.signature);
        with_attr error_message("PluginAccount: invalid declare") {
            assert_not_zero(is_valid);
        }
        return ();
    }

    func execute{
        syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, ecdsa_ptr: SignatureBuiltin*, range_check_ptr
    }(
        call_array_len: felt,
        call_array: CallArray*,
        calldata_len: felt,
        calldata: felt*,
    ) -> (response_len: felt, response: felt*) {
        alloc_locals;

        let (tx_info) = get_tx_info();
        assert_correct_tx_version(tx_info.version);
        assert_non_reentrant();

        /////////////// TMP /////////////////////
        // parse inputs to an array of 'Call' struct
        let (calls: Call*) = alloc();
        from_call_array_to_call(call_array_len, call_array, calldata, calls);
        let calls_len = call_array_len;
        //////////////////////////////////////////

        let (response: felt*) = alloc();
        let (response_len) = execute_list(calls_len, calls, response);
        transaction_executed.emit(
            hash=tx_info.transaction_hash, response_len=response_len, response=response
        );
        return (response_len, response);
    }

    func add_plugin{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(plugin: felt, plugin_calldata_len: felt, plugin_calldata: felt*) {
        assert_only_self();

        with_attr error_message("PluginAccount: plugin cannot be null") {
            assert_not_zero(plugin);
        }

        let (is_plugin) = PluginAccount_plugins.read(plugin);
        with_attr error_message("PluginAccount: plugin already registered") {
            assert is_plugin = 0;
        }

        PluginAccount_plugins.write(plugin, 1);

        initialize_plugin(plugin, plugin_calldata_len, plugin_calldata);

        return ();
    }

    func remove_plugin{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(plugin: felt) {
        assert_only_self();

        let (is_plugin) = PluginAccount_plugins.read(plugin);
        with_attr error_message("PluginAccount: unknown plugin") {
            assert_not_zero(is_plugin);
        }

        let (tx_info) = get_tx_info();

        let (signature_plugin) = get_plugin_from_signature(tx_info.signature_len, tx_info.signature);
        with_attr error_message("PluginAccount: plugin can't remove itself") {
            assert_not_equal(signature_plugin, plugin);
        }

        PluginAccount_plugins.write(plugin, 0);
        return ();
    }

    func execute_on_plugin{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
        plugin: felt, selector: felt, calldata_len: felt, calldata: felt*
    ) -> (retdata_len: felt, retdata: felt*) {

        // only valid plugin
        let (is_plugin) = PluginAccount_plugins.read(plugin);
        assert_not_zero(is_plugin);

        let (retdata_len: felt, retdata: felt*) = library_call(
            class_hash=plugin,
            function_selector=selector,
            calldata_size=calldata_len,
            calldata=calldata,
        );
        return (retdata_len=retdata_len, retdata=retdata);
    }

    func is_valid_signature{
        syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, ecdsa_ptr: SignatureBuiltin*, range_check_ptr
    }(hash: felt, sig_len: felt, sig: felt*) -> (is_valid: felt) {
        alloc_locals;

        let (plugin) = get_plugin_from_signature(sig_len, sig);

        let (is_valid) = IPlugin.library_call_is_valid_signature(
            class_hash=plugin,
            hash=hash,
            sig_len=sig_len,
            sig=sig
        );

        return (is_valid=is_valid);
    }

    func is_interface_supported{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
        interface_id: felt
    ) -> (is_supported: felt) {
        // 165
        if (interface_id == 0x01ffc9a7) {
            return (TRUE,);
        }
        // IAccount
        if (interface_id == ERC165_ACCOUNT_INTERFACE_ID) {
            return (TRUE,);
        }

        return (FALSE,);
    }

    func is_plugin{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(plugin: felt) -> (
        success: felt
    ) {
        let (res) = PluginAccount_plugins.read(plugin);
        return (success=res);
    }

    func initialize_plugin{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
        plugin: felt, plugin_calldata_len: felt, plugin_calldata: felt*
    ) {
        if (plugin_calldata_len == 0) {
            return ();
        }

        IPlugin.library_call_initialize(
            class_hash=plugin,
            data_len=plugin_calldata_len,
            data=plugin_calldata,
        );

        return ();
    }

    func get_plugin_from_signature{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
        signature_len: felt, signature: felt*,
    ) -> (plugin: felt) {
        alloc_locals;

        with_attr error_message("PluginAccount: invalid signature") {
            assert_not_zero(signature_len);
        }

        let plugin = signature[0];

        let (is_plugin) = PluginAccount_plugins.read(plugin);
        with_attr error_message("PluginAccount: unregistered plugin") {
            assert_not_zero(is_plugin);
        }
        return (plugin=plugin);
    }

    func assert_only_self{syscall_ptr: felt*}() -> () {
        let (self) = get_contract_address();
        let (caller_address) = get_caller_address();
        with_attr error_message("PluginAccount: only self") {
            assert self = caller_address;
        }
        return ();
    }

    func assert_non_reentrant{syscall_ptr: felt*}() -> () {
        let (caller) = get_caller_address();
        with_attr error_message("PluginAccount: no reentrant call") {
            assert caller = 0;
        }
        return ();
    }

    func assert_initialized{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() {
        let (initialized) = PluginAccount_initialized.read();
        with_attr error_message("PluginAccount: account not initialized") {
            assert_not_zero(initialized);
        }
        return ();
    }

    func assert_correct_tx_version{syscall_ptr: felt*}(tx_version: felt) -> () {
        with_attr error_message("PluginAccount: invalid tx version") {
            assert (tx_version - TRANSACTION_VERSION) * (tx_version - QUERY_VERSION) = 0;
        }
        return ();
    }

    // @notice Executes a list of contract calls recursively.
    // @param calls_len The number of calls to execute
    // @param calls A pointer to the first call to execute
    // @param response The array of felt to pupulate with the returned data
    // @return response_len The size of the returned data
    func execute_list{syscall_ptr: felt*}(
        calls_len: felt, calls: Call*, reponse: felt*
    ) -> (response_len: felt) {
        alloc_locals;

        // if no more calls
        if (calls_len == 0) {
            return (0,);
        }

        // do the current call
        let this_call: Call = [calls];
        let res = call_contract(
            contract_address=this_call.to,
            function_selector=this_call.selector,
            calldata_size=this_call.calldata_len,
            calldata=this_call.calldata,
        );

        // copy the result in response
        memcpy(reponse, res.retdata, res.retdata_size);
        // do the next calls recursively
        let (response_len) = execute_list(
            calls_len - 1, calls + Call.SIZE, reponse + res.retdata_size
        );
        return (response_len + res.retdata_size,);
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
}