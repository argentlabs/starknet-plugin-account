import pytest
import asyncio
import logging
from starkware.starknet.testing.starknet import Starknet
from utils.utils import compile, cached_contract, StarkKeyPair, ERC165_INTERFACE_ID, ERC165_ACCOUNT_INTERFACE_ID
from utils.plugin_signer import StarkPluginSigner
from utils.session_keys_utils import SessionPluginSigner


LOGGER = logging.getLogger(__name__)

signer_key = StarkKeyPair(123456789987654321)
session_key = StarkKeyPair(666666666666666666)


@pytest.fixture(scope='module')
def event_loop():
    return asyncio.new_event_loop()


@pytest.fixture(scope='module')
async def get_starknet():
    return await Starknet.empty()


@pytest.fixture(scope='module')
def contract_classes():
    account_cls = compile('contracts/account/PluginAccount.cairo')
    session_key_cls = compile('contracts/plugins/SessionKey.cairo')
    sts_plugin_cls = compile("contracts/plugins/signer/StarkSigner.cairo")
    return account_cls, session_key_cls, sts_plugin_cls


@pytest.fixture(scope='module')
async def account_init(contract_classes):
    account_cls, session_key_cls, sts_plugin_cls = contract_classes
    starknet = await Starknet.empty()

    session_key_class = await starknet.declare(contract_class=session_key_cls)
    sts_plugin_decl = await starknet.declare(contract_class=sts_plugin_cls)

    account = await starknet.deploy(contract_class=account_cls, constructor_calldata=[])
    await account.initialize(sts_plugin_decl.class_hash, [signer_key.public_key]).execute()

    return starknet.state, account, session_key_class.class_hash, sts_plugin_decl.class_hash


@pytest.fixture
def account_factory(contract_classes, account_init):
    account_cls, session_key_cls, ECDSABasePlugin_cls = contract_classes
    state, account, session_key_class, sts_plugin_hash = account_init
    _state = state.copy()
    account = cached_contract(_state, account_cls, account)

    stark_plugin_signer = StarkPluginSigner(
        stark_key=signer_key,
        account=account,
        plugin_address=sts_plugin_hash
    )

    session_plugin_signer = SessionPluginSigner(
        stark_key=session_key,
        account=account,
        plugin_address=session_key_class
    )
    return account, stark_plugin_signer, session_plugin_signer, session_key_class


@pytest.mark.asyncio
async def test_addPlugin(account_factory):
    account, stark_plugin_signer, _, session_key_class = account_factory

    assert (await account.isPlugin(session_key_class).call()).result.success == 0
    await stark_plugin_signer.add_plugin(session_key_class)
    assert (await account.isPlugin(session_key_class).call()).result.success == 1


@pytest.mark.asyncio
async def test_removePlugin(account_factory):
    account, stark_plugin_signer, _, session_key_class = account_factory

    assert (await account.isPlugin(session_key_class).call()).result.success == 0
    await stark_plugin_signer.add_plugin(session_key_class)
    assert (await account.isPlugin(session_key_class).call()).result.success == 1
    await stark_plugin_signer.remove_plugin(session_key_class)
    assert (await account.isPlugin(session_key_class).call()).result.success == 0


@pytest.mark.asyncio
async def test_supportsInterface(account_factory):
    account, _, _, _ = account_factory
    assert (await account.supportsInterface(ERC165_INTERFACE_ID).call()).result.success == 1
    assert (await account.supportsInterface(ERC165_ACCOUNT_INTERFACE_ID).call()).result.success == 1
    assert (await account.supportsInterface(0x123).call()).result.success == 0

