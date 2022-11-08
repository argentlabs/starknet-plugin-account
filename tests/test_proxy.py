import pytest
import asyncio
import logging
from starkware.starknet.testing.starknet import Starknet
from utils.utils import compile, build_contract, StarkKeyPair, ERC165_INTERFACE_ID, ERC165_ACCOUNT_INTERFACE_ID, assert_event_emitted, assert_revert, str_to_felt
from utils.plugin_signer import StarkPluginSigner
from utils.session_keys_utils import SessionPluginSigner
from starkware.starknet.compiler.compile import get_selector_from_name

signer = StarkKeyPair(420)
wrong_signer = StarkKeyPair(69)


@pytest.fixture(scope='module')
def event_loop():
    return asyncio.new_event_loop()

@pytest.fixture(scope='module')
async def starknet():
    return await Starknet.empty()

@pytest.fixture(scope='module')
async def account_setup(starknet: Starknet):
    account_cls = compile('contracts/account/PluginAccount.cairo')
    sts_plugin_cls = compile("contracts/plugins/signer/StarkSigner.cairo")
    proxy_cls = compile("contracts/upgrade/Proxy.cairo")
    
    sts_plugin_decl = await starknet.declare(contract_class=sts_plugin_cls)
    account_decl = await starknet.declare(contract_class=account_cls)

    account_proxy = await starknet.deploy(
        contract_class=proxy_cls,
        constructor_calldata=[account_decl.class_hash, get_selector_from_name('initialize'), 3, sts_plugin_decl.class_hash, 1, signer.public_key]
    )

    return account_proxy, account_decl, sts_plugin_decl

@pytest.fixture(scope='module')
async def dapp_setup(starknet: Starknet):
    dapp_cls = compile('contracts/test/Dapp.cairo')
    await starknet.declare(contract_class=dapp_cls)
    return await starknet.deploy(contract_class=dapp_cls, constructor_calldata=[])

@pytest.fixture
async def network(starknet: Starknet, account_setup, dapp_setup):
    account_proxy, account_decl, sts_plugin_decl = account_setup

    clean_state = starknet.state.copy()
    account_proxy = build_contract(account_proxy, state=clean_state)

    stark_plugin_signer = StarkPluginSigner(
        stark_key=signer,
        account=account_proxy,
        plugin_class_hash=sts_plugin_decl.class_hash
    )

    dapp = build_contract(dapp_setup, state=clean_state)

    return account_proxy, account_decl, stark_plugin_signer, dapp

@pytest.mark.asyncio
async def test_upgrade(network):
    account_proxy, account_decl, stark_plugin_signer, _ = network
    assert (await account_proxy.get_implementation().call()).result.implementation == account_decl.class_hash

    await assert_revert(
        stark_plugin_signer.send_transaction(calls=[(stark_plugin_signer.account.contract_address, 'upgrade', [420])]),
        reverted_with="PluginAccount: invalid implementation"
    )
