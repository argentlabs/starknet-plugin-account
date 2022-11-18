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
from contracts.plugins.IPlugin import IPlugin
from starkware.cairo.common.hash_chain import hash_chain

const ERC165_ACCOUNT_INTERFACE_ID = 0x3943f10f;

struct Call {
    to: felt,
    selector: felt,
    calldata_len: felt,
    calldata: felt*,
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

        let (self) = get_contract_address();
        account_created.emit(self);

        return ();
    }

    func validate{
        syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, ecdsa_ptr: SignatureBuiltin*, range_check_ptr
    }(
        call_array_len: felt, call_array: CallArray*, calldata_len: felt, calldata: felt*
    ) {
        alloc_locals;
        assert_initialized();

        let (tx_info) = get_tx_info();

        let (res) = alloc();
        with_attr error_message("PluginAccount: Invalid signature format") {
            let (id_len, id_list) = get_plugin_ids(tx_info.signature_len, tx_info.signature, 0, res);
        }
        let (to_hash: felt*) = alloc();
        assert [to_hash] = id_len+1;
        memcpy(dst=to_hash+1, src=id_list- id_len, len=id_len);
        assert [to_hash + id_len + 1] = tx_info.transaction_hash;
        let (hash) = hash_chain{hash_ptr=pedersen_ptr}(to_hash);

        inner_validate(hash, tx_info.signature_len, tx_info.signature, call_array_len, call_array, calldata_len, calldata);

        return ();
    }

    // @dev get plugin ids from tx.signature
    // @devfor instance a signature with many plugins looking like this
    // @@param signature_len: tx.signature_len, used to stop the search of id
    // @param sig: example like classHash1, 1 r, s, classHash2 , 0, classHash3, 3, r, s, v
    // @param res_len used to return the length of the result
    // @return res list of ids example (res_len = 3, res = [classHash1, classHash2, classHash3]
    func get_plugin_ids {
        syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, ecdsa_ptr: SignatureBuiltin*, range_check_ptr
    } (signature_len: felt, sig: felt*, res_len: felt, res: felt*) -> (res_len: felt, res: felt*) {
        if (signature_len == 0) {
            return (res_len, res);
        }
        assert [res] = sig[0];
        let offset = sig[1] + 2;
        return get_plugin_ids(signature_len - offset, sig + offset, res_len + 1, res + 1);
    }

    // @dev lib call all validate function from plugins
    func inner_validate{
        syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, ecdsa_ptr: SignatureBuiltin*, range_check_ptr
    }(
        hash: felt, 
        sig_len: felt,
        sig: felt*,
        call_array_len: felt, 
        call_array: CallArray*, 
        calldata_len: felt, 
        calldata: felt*
    ) {
        alloc_locals;

        if (sig_len == 0) {
            return ();
        }

        let plugin_id = sig[0];
        let plugin_sig_len = sig[1];

        IPlugin.library_call_validate(
            class_hash=plugin_id,
            hash=hash,
            sig_len=plugin_sig_len,
            sig=sig + 2,
            call_array_len=call_array_len,
            call_array=call_array,
            calldata_len=calldata_len,
            calldata=calldata,
        );

        return inner_validate(hash, sig_len - plugin_sig_len - 2, sig + plugin_sig_len + 2, call_array_len, call_array, calldata_len, calldata);
    }

    // todo test and update with new signing
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

    func execute{
        syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, ecdsa_ptr: SignatureBuiltin*, range_check_ptr
    }(
        call_array_len: felt,
        call_array: CallArray*,
        calldata_len: felt,
        calldata: felt*,
    ) -> (response_len: felt, response: felt*) {
        alloc_locals;

        assert_non_reentrant();

        let (tx_info) = get_tx_info();

        /////////////// TMP /////////////////////
        // parse inputs to an array of 'Call' struct
        let (calls: Call*) = alloc();
        from_call_array_to_call(call_array_len, call_array, calldata, calls);
        let calls_len = call_array_len;
        //////////////////////////////////////////

        let (response: felt*) = alloc();
        let (response_len, response) = inner_execute(
            tx_info.signature_len, tx_info.signature, call_array_len, call_array, calldata_len, calldata, 0, response,
        );

        transaction_executed.emit(
            hash=tx_info.transaction_hash, response_len=response_len, response=response
        );

        return (response_len=response_len, response=response);
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
            sig_len=sig[1],
            sig=sig + 2
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

    func inner_execute{
        syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, ecdsa_ptr: SignatureBuiltin*, range_check_ptr
    }(
        sig_len: felt,
        sig: felt*,
        call_array_len: felt, 
        call_array: CallArray*, 
        calldata_len: felt, 
        calldata: felt*,
        response_len: felt,
        response: felt*,
    ) -> (response_len: felt, response: felt*) {
        alloc_locals;

        // TMP? Avoid erasing response after execute with plugin
        if (response_len != 0) {
            return (response_len, response);
        }

        if (sig_len == 0) {

            /////////////// TMP /////////////////////
            // parse inputs to an array of 'Call' struct
            let (calls: Call*) = alloc();
            from_call_array_to_call(call_array_len, call_array, calldata, calls);
            let calls_len = call_array_len;
            //////////////////////////////////////////
            let (response: felt*) = alloc();
            let (plugin_response_len) = execute_list(calls_len, calls, response);
            memcpy(response, response, plugin_response_len);
            return (response_len + plugin_response_len, response);
        }

        let plugin_id = sig[0];
        let plugin_sig_len = sig[1];
        let (plugin_call_array_len, plugin_call_array, plugin_calldata_len, plugin_calldata, plugin_response_len, plugin_response) = IPlugin.library_call_execute(
            class_hash=plugin_id,
            call_array_len=call_array_len,
            call_array=call_array,
            calldata_len=calldata_len,
            calldata=calldata,
        );

        memcpy(response, plugin_response, plugin_response_len);
        return inner_execute(sig_len - plugin_sig_len - 2, sig + plugin_sig_len + 2, plugin_call_array_len, plugin_call_array, plugin_calldata_len, plugin_calldata, response_len + plugin_response_len, response);
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