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
from contracts.utils.structs import CallArray, Call

//###################
// CONSTANTS
//###################

const NAME = 'PluginAccount';
const VERSION = '0.0.1';

const IS_VALID_SIGNATURE_SELECTOR = 1138073982574099226972715907883430523600275391887289231447128254784345409857;
const SUPPORTS_INTERFACE_SELECTOR = 1184015894760294494673613438913361435336722154500302038630992932234692784845;
const USE_PLUGIN_SELECTOR = 1121675007639292412441492001821602921366030142137563176027248191276862353634;
const INITIALIZE_SELECTOR = 215307247182100370520050591091822763712463273430149262739280891880522753123;
const ERC165_ACCOUNT_INTERFACE = 0xf10dbd44;

//###################
// EVENTS
//###################

@event
func account_created(account: felt) {
}

@event
func account_upgraded(new_implementation: felt) {
}

@event
func transaction_executed(hash: felt, response_len: felt, response: felt*) {
}

//###################
// STORAGE VARIABLES
//###################

@storage_var
func _current_nonce() -> (res: felt) {
}

@storage_var
func _current_plugin() -> (res: felt) {
}

@storage_var
func _default_plugin() -> (res: felt) {
}

@storage_var
func _plugins(plugin: felt) -> (res: felt) {
}

//###################
// EXTERNAL FUNCTIONS
//###################

@external
func initialize{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    plugin: felt, plugin_calldata_len: felt, plugin_calldata: felt*
) {
    let (is_initialized) = _default_plugin.read();
    with_attr error_message("account already initialized") {
        assert is_initialized = FALSE;
    }

    // add plugin
    with_attr error_message("plugin cannot be null") {
        assert_not_zero(plugin);
    }
    _plugins.write(plugin, 1);

    library_call(
        class_hash=plugin,
        function_selector=INITIALIZE_SELECTOR,
        calldata_size=plugin_calldata_len,
        calldata=plugin_calldata,
    );

    _default_plugin.write(plugin);

    let (self) = get_contract_address();
    account_created.emit(self);

    return ();
}

@external
@raw_output
func __execute__{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, ecdsa_ptr: SignatureBuiltin*, range_check_ptr
}(
    call_array_len: felt, call_array: CallArray*, calldata_len: felt, calldata: felt*, nonce: felt
) -> (retdata_size: felt, retdata: felt*) {
    alloc_locals;

    // no reentrant call to prevent signature reutilization
    assert_non_reentrant();
    // validate and bump nonce
    validate_and_bump_nonce(nonce);

    let (is_plugin, plugin_id, plugin_data_len, plugin_data) = use_plugin(
        call_array_len, call_array, calldata_len, calldata
    );
    if (is_plugin == TRUE) {
        _current_plugin.write(plugin_id);
        validate_with_plugin(
            plugin_id,
            plugin_data_len,
            plugin_data,
            call_array_len - 1,
            call_array + CallArray.SIZE,
            calldata_len,
            calldata,
        );
        let (response_len, response) = execute_with_plugin(
            plugin_id,
            plugin_data_len,
            plugin_data,
            call_array_len - 1,
            call_array + CallArray.SIZE,
            calldata_len,
            calldata,
        );
        return (retdata_size=response_len, retdata=response);
    } else {
        let (default_plugin) = _default_plugin.read();
        validate_with_plugin(
            default_plugin, 0, plugin_data, call_array_len, call_array, calldata_len, calldata
        );
        let (response_len, response) = execute_with_plugin(
            default_plugin, 0, plugin_data, call_array_len, call_array, calldata_len, calldata
        );
        return (retdata_size=response_len, retdata=response);
    }
}

@external
func add_plugin{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(plugin: felt) {
    // only called via execute
    assert_only_self();

    // add plugin
    with_attr error_message("plugin cannot be null") {
        assert_not_zero(plugin);
    }
    _plugins.write(plugin, 1);
    return ();
}

@external
func remove_plugin{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(plugin: felt) {
    // only called via execute
    assert_only_self();

    let (exists) = _plugins.read(plugin);
    with_attr error_message("plugin does not exist") {
        assert_not_zero(exists);
    }

    // cannot remove default plugin
    with_attr error_message("cannot remove default plugin") {
        let (default_plugin) = _default_plugin.read();
        assert_not_equal(plugin, default_plugin);
    }

    _plugins.write(plugin, 0);

    return ();
}

@external
func execute_on_plugin{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    plugin: felt, selector: felt, calldata_len: felt, calldata: felt*
) {
    // only called via execute
    assert_only_self();
    // only valid plugin
    let (is_plugin) = _plugins.read(plugin);
    assert_not_zero(is_plugin);

    library_call(
        class_hash=plugin, function_selector=selector, calldata_size=calldata_len, calldata=calldata
    );
    return ();
}

@external
func set_default_plugin{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    plugin: felt
) {
    // only called via execute
    assert_only_self();

    // add plugin
    with_attr error_message("plugin cannot be null") {
        assert_not_zero(plugin);
    }

    _default_plugin.write(plugin);

    return ();
}

@external
@raw_input
@raw_output
func __default__{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    selector: felt, calldata_size: felt, calldata: felt*
) -> (retdata_size: felt, retdata: felt*) {
    let (current_plugin) = get_current_plugin();

    let (retdata_size: felt, retdata: felt*) = library_call(
        class_hash=current_plugin,
        function_selector=selector,
        calldata_size=calldata_size,
        calldata=calldata,
    );
    return (retdata_size=retdata_size, retdata=retdata);
}

//###################
// VIEW FUNCTIONS
//###################

@view
func is_valid_signature{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, ecdsa_ptr: SignatureBuiltin*, range_check_ptr
}(hash: felt, sig_len: felt, sig: felt*) -> (is_valid: felt) {
    alloc_locals;
    let (default_plugin) = _default_plugin.read();

    let (calldata: felt*) = alloc();
    assert calldata[0] = hash;
    assert calldata[1] = sig_len;
    memcpy(calldata + 2, sig, sig_len);

    let (retdata_size: felt, retdata: felt*) = library_call(
        class_hash=default_plugin,
        function_selector=IS_VALID_SIGNATURE_SELECTOR,
        calldata_size=2 + sig_len,
        calldata=calldata,
    );

    assert retdata_size = 1;
    return (is_valid=retdata[0]);
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
    if (interfaceId == ERC165_ACCOUNT_INTERFACE) {
        return (TRUE,);
    }
    return (FALSE,);
}

@view
func get_nonce{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (nonce: felt) {
    let (res) = _current_nonce.read();
    return (nonce=res);
}

@view
func is_plugin{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(plugin: felt) -> (
    success: felt
) {
    let (res) = _plugins.read(plugin);
    return (success=res);
}

@view
func get_version() -> (name: felt, version: felt) {
    return (name=NAME, version=VERSION);
}

//###################
// INTERNAL FUNCTIONS
//###################

func use_plugin{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    call_array_len: felt, call_array: CallArray*, calldata_len: felt, calldata: felt*
) -> (is_plugin: felt, plugin_id: felt, plugin_data_len: felt, plugin_data: felt*) {
    alloc_locals;

    let (plugin_data: felt*) = alloc();
    let res = is_not_zero(call_array[0].selector - USE_PLUGIN_SELECTOR);
    if (res == 1) {
        return (is_plugin=FALSE, plugin_id=0, plugin_data_len=0, plugin_data=plugin_data);
    }
    let plugin_id = calldata[call_array[0].data_offset];
    let (is_plugin) = _plugins.read(plugin_id);
    memcpy(plugin_data, calldata + call_array[0].data_offset + 1, call_array[0].data_len - 1);
    return (
        is_plugin=is_plugin,
        plugin_id=plugin_id,
        plugin_data_len=call_array[0].data_len - 1,
        plugin_data=plugin_data,
    );
}

func validate_with_plugin{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, ecdsa_ptr: SignatureBuiltin*, range_check_ptr
}(
    plugin_id: felt,
    plugin_data_len: felt,
    plugin_data: felt*,
    call_array_len: felt,
    call_array: CallArray*,
    calldata_len: felt,
    calldata: felt*,
) {
    IPlugin.library_call_validate(
        class_hash=plugin_id,
        plugin_data_len=plugin_data_len,
        plugin_data=plugin_data,
        call_array_len=call_array_len,
        call_array=call_array,
        calldata_len=calldata_len,
        calldata=calldata,
    );
    return ();
}

func execute_with_plugin{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, ecdsa_ptr: SignatureBuiltin*, range_check_ptr
}(
    plugin_id: felt,
    plugin_data_len: felt,
    plugin_data: felt*,
    call_array_len: felt,
    call_array: CallArray*,
    calldata_len: felt,
    calldata: felt*,
) -> (response_len: felt, response: felt*) {
    alloc_locals;

    let (tx_info) = get_tx_info();

    // ############## TMP #############################
    // parse inputs to an array of 'Call' struct
    let (calls: Call*) = alloc();
    from_call_array_to_call(call_array_len, call_array, calldata, calls);
    let calls_len = call_array_len;
    //################################################

    let (response: felt*) = alloc();
    let (response_len) = execute_list(plugin_id, calls_len, calls, response);
    transaction_executed.emit(
        hash=tx_info.transaction_hash, response_len=response_len, response=response
    );
    return (response_len, response);
}

func get_current_plugin{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (
    current_plugin: felt
) {
    let (current_plugin) = _current_plugin.read();
    if (current_plugin == 0) {
        let (default_plugin) = _default_plugin.read();
        return (default_plugin,);
    }
    return (current_plugin,);
}

func assert_only_self{syscall_ptr: felt*}() -> () {
    let (self) = get_contract_address();
    let (caller_address) = get_caller_address();
    with_attr error_message("must be called via execute") {
        assert self = caller_address;
    }
    return ();
}

func assert_non_reentrant{syscall_ptr: felt*}() -> () {
    let (caller) = get_caller_address();
    with_attr error_message("no reentrant call") {
        assert caller = 0;
    }
    return ();
}

func validate_and_bump_nonce{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    message_nonce: felt
) -> () {
    let (current_nonce) = _current_nonce.read();
    with_attr error_message("nonce invalid") {
        assert current_nonce = message_nonce;
    }
    _current_nonce.write(current_nonce + 1);
    return ();
}

// @notice Executes a list of contract calls recursively.
// @param calls_len The number of calls to execute
// @param calls A pointer to the first call to execute
// @param response The array of felt to pupulate with the returned data
// @return response_len The size of the returned data
func execute_list{syscall_ptr: felt*}(
    plugin_id: felt, calls_len: felt, calls: Call*, reponse: felt*
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
        plugin_id, calls_len - 1, calls + Call.SIZE, reponse + res.retdata_size
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
