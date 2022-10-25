import pytest
import asyncio
from starkware.starknet.testing.starknet import Starknet
from utils.utils import str_to_felt, cached_contract, compile
from utils.utils import StarkKeyPair, ERC165_INTERFACE_ID, ERC165_ACCOUNT_INTERFACE_ID
from utils.plugin_signer import StarkPluginSigner

key_pair = StarkKeyPair(1234)
new_key_pair = StarkKeyPair(5678)


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
    
    await account.initialize(sts_plugin_decl.class_hash, [key_pair.public_key]).execute()

    return starknet.state, account, sts_plugin_decl.class_hash


@pytest.fixture
def contract_factory(contract_classes, contract_init):
    account_cls, sts_plugin_cls = contract_classes
    state, account, sts_plugin_hash = contract_init
    _state = state.copy()

    account = cached_contract(_state, account_cls, account)

    stark_plugin_signer = StarkPluginSigner(
        stark_key=key_pair,
        account=account,
        plugin_address=sts_plugin_hash
    )

    return account, stark_plugin_signer, sts_plugin_hash


@pytest.mark.asyncio
async def test_initialise(contract_factory):
    account, stark_plugin_signer, sts_plugin_hash = contract_factory

    execution_info = await account.getName().call()
    assert execution_info.result == (str_to_felt('PluginAccount'),)

    execution_info = await account.isPlugin(sts_plugin_hash).call()
    assert execution_info.result == (1,)

    execution_info = await stark_plugin_signer.read_on_plugin("getPublicKey")
    assert execution_info.result[0] == [stark_plugin_signer.public_key]


@pytest.mark.asyncio
async def test_change_public_key(contract_factory):
    account, stark_plugin_signer, sts_plugin_hash = contract_factory

    await stark_plugin_signer.execute_on_plugin(
        selector_name="setPublicKey",
        arguments=[new_key_pair.public_key]
    )

    execution_info = await stark_plugin_signer.read_on_plugin("getPublicKey")
    assert execution_info.result[0] == [new_key_pair.public_key]


@pytest.mark.asyncio
async def test_supportsInterface(contract_factory):
    account, stark_plugin_signer, sts_plugin_hash = contract_factory
    assert (await stark_plugin_signer.read_on_plugin("supportsInterface", [ERC165_INTERFACE_ID])).result[0] == [1]
    assert (await stark_plugin_signer.read_on_plugin("supportsInterface", [ERC165_ACCOUNT_INTERFACE_ID])).result[0] == [0]
    assert (await stark_plugin_signer.read_on_plugin("supportsInterface", [ERC165_ACCOUNT_INTERFACE_ID])).result[0] == [0]