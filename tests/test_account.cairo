%lang starknet

from starkware.cairo.common.cairo_builtins import HashBuiltin
from starkware.cairo.common.uint256 import Uint256
from starkware.starknet.common.syscalls import get_block_timestamp, get_caller_address

from contracts.account.IPluginAccount import IPluginAccount
from contracts.upgrade.IProxy import IProxy

@external
func test_upgrade{syscall_ptr: felt*, range_check_ptr, pedersen_ptr: HashBuiltin*}() {
    alloc_locals;

    local initial_implementation: felt;
    local fake_implementation: felt;
    local account_address: felt;
    %{
        from starkware.starknet.compiler.compile import get_selector_from_name
        ids.initial_implementation = declare("./contracts/account/PluginAccount.cairo").class_hash
        ids.fake_implementation = declare("./contracts/test/FakeAccount.cairo").class_hash
        signer_hash = declare("./contracts/plugins/signer/StarkSigner.cairo").class_hash
        ids.account_address = deploy_contract("./contracts/upgrade/Proxy.cairo", [ids.initial_implementation, get_selector_from_name('initialize'), 3, signer_hash, 1, 420]).contract_address
        
        # prank from self
        stop_prank_callable = start_prank(ids.account_address, target_contract_address=ids.account_address)
    %}

    let (implementation) = IProxy.get_implementation(account_address);

    assert implementation = initial_implementation;

    %{ expect_revert(error_message="PluginAccount: invalid implementation") %}
    IPluginAccount.upgrade(account_address, 0xdead);

    // Successfully upgrades to fake account that masquerades as ERC165.
    IPluginAccount.upgrade(account_address, fake_implementation);

    %{ 
        stop_prank_callable()
    %}

    return ();
}
