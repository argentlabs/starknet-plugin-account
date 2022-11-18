%lang starknet

from starkware.cairo.common.cairo_builtins import HashBuiltin, SignatureBuiltin
from starkware.cairo.common.alloc import alloc
from starkware.starknet.common.syscalls import library_call
from starkware.cairo.common.bool import TRUE

from contracts.account.library import CallArray, PluginAccount, ERC165_ACCOUNT_INTERFACE_ID
from contracts.upgrade.Upgradable import _set_implementation

/////////////////////
// CONSTANTS
/////////////////////

const NAME = 'PluginAccount';
const VERSION = '0.0.1';
const SUPPORTS_INTERFACE_SELECTOR = 1184015894760294494673613438913361435336722154500302038630992932234692784845;

/////////////////////
// EVENTS
/////////////////////

@event
func account_upgraded(new_implementation: felt) {
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
    PluginAccount.validate(call_array_len, call_array, calldata_len, calldata);
    return ();
}

@external
@raw_output
func __execute__{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, ecdsa_ptr: SignatureBuiltin*, range_check_ptr
} (
    call_array_len: felt, call_array: CallArray*, calldata_len: felt, calldata: felt*
) -> (retdata_size: felt, retdata: felt*) {
    let (response_len, response) = PluginAccount.execute(call_array_len, call_array, calldata_len, calldata);
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
    PluginAccount.initializer(plugin, plugin_calldata_len, plugin_calldata);
    return ();
}

@external
func addPlugin{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(plugin: felt, plugin_calldata_len: felt, plugin_calldata: felt*) {
    PluginAccount.add_plugin(plugin, plugin_calldata_len, plugin_calldata);
    return ();
}

@external
func removePlugin{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(plugin: felt) {
    PluginAccount.remove_plugin(plugin);
    return ();
}

@external
func executeOnPlugin{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    plugin: felt, selector: felt, calldata_len: felt, calldata: felt*
) -> (retdata_len: felt, retdata: felt*) {
    return PluginAccount.execute_on_plugin(plugin, selector, calldata_len, calldata);
}

@external
func upgrade{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    implementation: felt
) {
    // only called via execute
    PluginAccount.assert_only_self();
    // make sure the target is an account
    with_attr error_message("PluginAccount: invalid implementation") {
        let (calldata: felt*) = alloc();
        assert calldata[0] = ERC165_ACCOUNT_INTERFACE_ID;
        let (retdata_size: felt, retdata: felt*) = library_call(
            class_hash=implementation,
            function_selector=SUPPORTS_INTERFACE_SELECTOR,
            calldata_size=1,
            calldata=calldata,
        );
        assert retdata_size = 1;
        assert [retdata] = TRUE;
    }
    // change implementation
    _set_implementation(implementation);
    account_upgraded.emit(new_implementation=implementation);

    return ();
}

/////////////////////
// VIEW FUNCTIONS
/////////////////////

@view
func isValidSignature{
    syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, ecdsa_ptr: SignatureBuiltin*, range_check_ptr
}(hash: felt, sig_len: felt, sig: felt*) -> (isValid: felt) {
    let (isValid) = PluginAccount.is_valid_signature(hash, sig_len, sig);
    return (isValid=isValid);
}

@view
func supportsInterface{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    interfaceId: felt
) -> (success: felt) {
    let (res) = PluginAccount.is_interface_supported(interfaceId);
    return (res,);
}

@view
func isPlugin{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(plugin_id: felt) -> (
    success: felt
) {
    let (res) = PluginAccount.is_plugin(plugin_id);
    return (success=res);
}

@view
func getName() -> (name: felt) {
    return (name=NAME);
}

@view
func getVersion() -> (version: felt) {
    return (version=VERSION);
}
