import pytest
import asyncio
import logging
from starkware.starknet.testing.starknet import Starknet
from utils.utils import compile, build_contract, assert_event_emitted, StarkKeyPair, ERC165_INTERFACE_ID, ERC165_ACCOUNT_INTERFACE_ID
from utils.plugin_signer import StarkPluginSigner
from utils.session_keys_utils import SessionPluginSigner


LOGGER = logging.getLogger(__name__)

signer_key = StarkKeyPair(123456789987654321)
session_key = StarkKeyPair(666666666666666666)


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
    account_decl = await starknet.declare(contract_class=account_cls)
    sts_plugin_decl = await starknet.declare(contract_class=sts_plugin_cls)

    account = await starknet.deploy(contract_class=account_cls, constructor_calldata=[])
    await account.initialize(sts_plugin_decl.class_hash, [signer_key.public_key]).execute()
    return account, account_cls, sts_plugin_decl


@pytest.fixture(scope='module')
async def session_plugin_setup(starknet: Starknet):
    session_key_cls = compile('contracts/plugins/SessionKey.cairo')
    session_key_decl = await starknet.declare(contract_class=session_key_cls)
    return session_key_decl


@pytest.fixture(scope='module')
async def dapp_setup(starknet: Starknet):
    dapp_cls = compile('contracts/test/Dapp.cairo')
    await starknet.declare(contract_class=dapp_cls)
    return await starknet.deploy(contract_class=dapp_cls, constructor_calldata=[])


@pytest.fixture
async def network(starknet: Starknet, account_setup, session_plugin_setup, dapp_setup):
    account, account_cls, sts_plugin_decl = account_setup
    session_key_decl = session_plugin_setup

    clean_state = starknet.state.copy()
    account = build_contract(account, state=clean_state)

    stark_plugin_signer = StarkPluginSigner(
        stark_key=signer_key,
        account=account,
        plugin_address=sts_plugin_decl.class_hash
    )

    session_plugin_signer = SessionPluginSigner(
        stark_key=session_key,
        account=account,
        plugin_address=session_key_decl.class_hash
    )
    dapp = build_contract(dapp_setup, state=clean_state)

    return account, stark_plugin_signer, session_plugin_signer, dapp


@pytest.mark.asyncio
async def test_addPlugin(network):
    account, stark_plugin_signer, session_plugin_signer, dapp = network
    plugin_address = session_plugin_signer.plugin_address
    assert (await account.isPlugin(plugin_address).call()).result.success == 0
    await stark_plugin_signer.add_plugin(plugin_address)
    assert (await account.isPlugin(plugin_address).call()).result.success == 1


@pytest.mark.asyncio
async def test_removePlugin(network):
    account, stark_plugin_signer, session_plugin_signer, dapp = network
    plugin_address = session_plugin_signer.plugin_address
    assert (await account.isPlugin(plugin_address).call()).result.success == 0
    await stark_plugin_signer.add_plugin(plugin_address)
    assert (await account.isPlugin(plugin_address).call()).result.success == 1
    await stark_plugin_signer.remove_plugin(plugin_address)
    assert (await account.isPlugin(plugin_address).call()).result.success == 0


@pytest.mark.asyncio
async def test_supportsInterface(network):
    account, stark_plugin_signer, session_plugin_signer, dapp = network
    assert (await account.supportsInterface(ERC165_INTERFACE_ID).call()).result.success == 1
    assert (await account.supportsInterface(ERC165_ACCOUNT_INTERFACE_ID).call()).result.success == 1
    assert (await account.supportsInterface(0x123).call()).result.success == 0


@pytest.mark.asyncio
async def test_supportsInterface(network):
    account, stark_plugin_signer, session_plugin_signer, dapp = network
    assert (await account.supportsInterface(ERC165_INTERFACE_ID).call()).result.success == 1
    assert (await account.supportsInterface(ERC165_ACCOUNT_INTERFACE_ID).call()).result.success == 1
    assert (await account.supportsInterface(0x123).call()).result.success == 0


@pytest.mark.asyncio
async def test_dapp(network):
    account, stark_plugin_signer, session_plugin_signer, dapp = network
    assert (await dapp.get_balance().call()).result.res == 0
    tx_exec_info = await stark_plugin_signer.send_transaction(
        calls=[(dapp.contract_address, 'set_balance', [47])],
    )
    assert_event_emitted(
        tx_exec_info,
        from_address=account.contract_address,
        name='transaction_executed',
        data=[]
    )
    assert (await dapp.get_balance().call()).result.res == 47

