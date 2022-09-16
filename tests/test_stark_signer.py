import pytest
import asyncio
from starkware.starknet.testing.starknet import Starknet
from utils import str_to_felt, cached_contract, compile, StarkSigner

signer = StarkSigner(1234)
new_signer = StarkSigner(5678)

@pytest.fixture(scope='module')
def event_loop():
    return asyncio.new_event_loop()

@pytest.fixture(scope='module')
def contract_classes():
    account_cls = compile('contracts/account/PluginAccount.cairo')
    sts_plugin_cls = compile("contracts/plugins/signer/StarkSigner.cairo")
    
    return account_cls, sts_plugin_cls

@pytest.fixture(scope='module')
async def contract_init(contract_classes):
    account_cls, sts_plugin_cls = contract_classes
    starknet = await Starknet.empty()

    sts_plugin_decl = await starknet.declare(contract_class=sts_plugin_cls)

    account = await starknet.deploy(
        contract_class=account_cls,
        constructor_calldata=[]
    )
    
    await account.initialize(sts_plugin_decl.class_hash, [1, signer.public_key]).execute()

    return starknet.state, account, sts_plugin_decl.class_hash

@pytest.fixture
def contract_factory(contract_classes, contract_init):
    account_cls, sts_plugin_cls = contract_classes
    state, account, sts_plugin_hash = contract_init
    _state = state.copy()

    account = cached_contract(_state, account_cls, account)
    account_as_plugin = cached_contract(_state, sts_plugin_cls, account)

    return account, account_as_plugin, sts_plugin_hash

@pytest.mark.asyncio
async def test_initialise(contract_factory):
    account, account_as_plugin, sts_plugin_hash = contract_factory

    execution_info = await account.getName().call()
    assert execution_info.result == (str_to_felt('PluginAccount'),)

    execution_info = await account.getDefaultPlugin().call()
    assert execution_info.result == (sts_plugin_hash,)

    execution_info = await account_as_plugin.getPublicKey().call()
    assert execution_info.result == (signer.public_key,)

@pytest.mark.asyncio
async def test_change_public_key(contract_factory):
    account, account_as_plugin, sts_plugin_hash = contract_factory

    execution_info = await signer.send_transaction(account, [(account.contract_address, 'setPublicKey', [new_signer.public_key])])

    execution_info = await account_as_plugin.getPublicKey().call()
    assert execution_info.result == (new_signer.public_key,)