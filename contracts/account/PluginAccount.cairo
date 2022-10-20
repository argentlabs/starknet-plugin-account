%lang starknet

from starkware.cairo.common.cairo_builtins import HashBuiltin, SignatureBuiltin
from starkware.cairo.common.signature import verify_ecdsa_signature
from starkware.cairo.common.alloc import alloc
from starkware.cairo.common.memcpy import memcpy
from starkware.cairo.common.math import assert_not_zero, assert_le, assert_nn, assert_not_equal
from starkware.cairo.common.math_cmp import is_not_zero
from starkware.starknet.common.syscalls import (
    library_call,
    call_contract,
    get_tx_info,
    get_contract_address,
    get_caller_address,
    get_block_timestamp,
)
from starkware.cairo.common.bool import TRUE, FALSE
from contracts.plugins.IPlugin import IPlugin
from contracts.account.library import CallArray, Call

/////////////////////
// CONSTANTS
/////////////////////

const NAME = 'PluginAccount';
const VERSION = '0.0.1';

const ERC165_ACCOUNT_INTERFACE_ID = 0x3943f10f;

/////////////////////
// EVENTS
/////////////////////

@event
func account_created(account: felt) {
}

@event
func account_upgraded(new_implementation: felt) {
}

@event
func transaction_executed(hash: felt, response_len: felt, response: felt*) {
}

/////////////////////
// STORAGE VARIABLES
/////////////////////


@storage_var
func _plugins(plugin: felt) -> (res: felt) {
}

@storage_var
func _plugins_count() -> (res: felt) {
}

/////////////////////
// PROTOCOL
/////////////////////

@external
func __validate__{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, ecdsa_ptr: SignatureBuiltin*, range_check_ptr
}(
    call_array_len: felt, call_array: CallArray*, calldata_len: felt, calldata: felt*
) {
    alloc_locals;

    assert_initialized();
    
    let (tx_info) = get_tx_info();

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

@external
func __validate_deploy__{
    syscall_ptr: felt*,
    pedersen_ptr: HashBuiltin*,
    ecdsa_ptr: SignatureBuiltin*,
    range_check_ptr
} (
    class_hash: felt,
    ctr_args_len: felt,
    ctr_args: felt*,
    salt: felt
) {
    alloc_locals;
    // get the tx info
    let (tx_info) = get_tx_info();
    // validate the signer signature only
    let (is_valid) = isValidSignature(tx_info.transaction_hash, tx_info.signature_len, tx_info.signature);
    with_attr error_message("PluginAccount: invalid deploy") {
        assert_not_zero(is_valid);
    }
    return ();
}

@external
@raw_output
func __execute__{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, ecdsa_ptr: SignatureBuiltin*, range_check_ptr
} (
    call_array_len: felt, call_array: CallArray*, calldata_len: felt, calldata: felt*
) -> (retdata_size: felt, retdata: felt*) {
    alloc_locals;

    assert_non_reentrant();

    let (response_len, response) = execute(
        call_array_len, call_array, calldata_len, calldata
    );
    return (retdata_size=response_len, retdata=response);
}

@external
func __validate_declare__{
    syscall_ptr: felt*,
    pedersen_ptr: HashBuiltin*,
    ecdsa_ptr: SignatureBuiltin*,
    range_check_ptr
} (
    class_hash: felt
) {
    // todo
    return ();
}

/////////////////////
// EXTERNAL FUNCTIONS
/////////////////////

@external
func initialize{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    plugin: felt, plugin_calldata_len: felt, plugin_calldata: felt*
) {
    let (plugins_count) = _plugins_count.read();
    with_attr error_message("PluginAccount: already initialized") {
        assert plugins_count = 0;
    }

    with_attr error_message("PluginAccount: plugin cannot be null") {
        assert_not_zero(plugin);
    }

    _plugins.write(plugin, 1);
    _plugins_count.write(1);

    initialize_plugin(plugin, plugin_calldata_len, plugin_calldata);

    let (self) = get_contract_address();
    account_created.emit(self);

    return ();
}


@external
func addPlugin{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(plugin: felt, plugin_calldata_len: felt, plugin_calldata: felt*) {
    assert_only_self();

    with_attr error_message("PluginAccount: plugin cannot be null") {
        assert_not_zero(plugin);
    }

    let (is_plugin) = _plugins.read(plugin);
    with_attr error_message("PluginAccount: already a plugin") {
        assert is_plugin = 0;
    }

    _plugins.write(plugin, 1);
    let (plugins_count) = _plugins_count.read();
    _plugins_count.write(plugins_count + 1);

    initialize_plugin(plugin, plugin_calldata_len, plugin_calldata);

    return ();
}

@external
func removePlugin{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(plugin: felt) {
    assert_only_self();

    let (is_plugin) = _plugins.read(plugin);
    with_attr error_message("PluginAccount: unknown plugin") {
        assert_not_zero(is_plugin);
    }

    let (plugins_count) = _plugins_count.read();

    // cannot remove last plugin    
    with_attr error_message("PluginAccount: cannot remove last plugin") {
        assert_not_equal(plugins_count, 1);
    }

    _plugins.write(plugin, 0);
    _plugins_count.write(plugins_count - 1);
    return ();
}


@external
func executeOnPlugin{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    plugin: felt, selector: felt, calldata_len: felt, calldata: felt*
) -> (retdata_len: felt, retdata: felt*) {

    // only called via execute
    assert_only_self();
    // only valid plugin
    let (is_plugin) = _plugins.read(plugin);
    assert_not_zero(is_plugin);

    let (retdata_len: felt, retdata: felt*) = library_call(
        class_hash=plugin,
        function_selector=selector,
        calldata_size=calldata_len,
        calldata=calldata,
    );
    return (retdata_len=retdata_len, retdata=retdata);
}

/////////////////////
// VIEW FUNCTIONS
/////////////////////

@view
func isValidSignature{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, ecdsa_ptr: SignatureBuiltin*, range_check_ptr
}(hash: felt, sig_len: felt, sig: felt*) -> (isValid: felt) {
    alloc_locals;

    let (plugin) = get_plugin_from_signature(sig_len, sig);

    let (isValid) = IPlugin.library_call_is_valid_signature(
        class_hash=plugin,
        hash=hash,
        sig_len=sig_len,
        sig=sig
    );

    return (isValid=isValid);
}

@view
func supportsInterface{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    interfaceId: felt
) -> (success: felt) {
    // 165
    if (interfaceId == 0x01ffc9a7) {
        return (TRUE,);
    }
    // IAccount
    if (interfaceId == ERC165_ACCOUNT_INTERFACE_ID) {
        return (TRUE,);
    }

    return (FALSE,);
}

@view
func isPlugin{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(plugin: felt) -> (
    success: felt
) {
    let (res) = _plugins.read(plugin);
    return (success=res);
}

@view
func readOnPlugin{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    plugin: felt, selector: felt, calldata_len: felt, calldata: felt*
) -> (retdata_len: felt, retdata: felt*) {
    let (is_plugin) = _plugins.read(plugin);
    with_attr error_message("PluginAccount: unknown plugin") {
        assert_not_zero(is_plugin);
    }
    let (retdata_len: felt, retdata: felt*) = library_call(
        class_hash=plugin,
        function_selector=selector,
        calldata_size=calldata_len,
        calldata=calldata,
    );
    return (retdata_len=retdata_len, retdata=retdata);
}

@view
func getName() -> (name: felt) {
    return (name=NAME);
}

@view
func getVersion() -> (version: felt) {
    return (version=VERSION);
}

/////////////////////
// INTERNAL FUNCTIONS
/////////////////////

@view
func get_plugin_from_signature{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    signature_len: felt, signature: felt*,
) -> (plugin: felt) {
    alloc_locals;

    with_attr error_message("PluginAccount: invalid signature") {
        assert_not_zero(signature_len);
    }

    let plugin = signature[0];

    let (is_plugin) = _plugins.read(plugin);
    with_attr error_message("PluginAccount: unknown plugin") {
        assert_not_zero(is_plugin);
    }
    return (plugin=plugin);
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
    let (plugins_count) = _plugins_count.read();
    with_attr error_message("PluginAccount: account not initialized") {
        assert_not_zero(plugins_count);
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
