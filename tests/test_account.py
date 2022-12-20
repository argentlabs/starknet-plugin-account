import pytest
import asyncio
import logging
from starkware.starknet.testing.starknet import Starknet
from utils.utils import compile, build_contract, StarkKeyPair, ERC165_INTERFACE_ID, ERC165_ACCOUNT_INTERFACE_ID, assert_event_emitted, assert_revert, str_to_felt
from utils.plugin_signer import StarkPluginSigner
from utils.session_keys_utils import SessionPluginSigner
from starkware.starknet.compiler.compile import get_selector_from_name


LOGGER = logging.getLogger(__name__)

signer_key = StarkKeyPair(123456789987654321)
signer_key_2 = StarkKeyPair(123456789987654322)
session_key = StarkKeyPair(666666666666666666)

VERSION = '0.0.1'

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
    account_cls_decl = await starknet.declare(contract_class=account_cls)

    account = await starknet.deploy(contract_class=account_cls, constructor_calldata=[])
    await account.initialize(sts_plugin_decl.class_hash, [signer_key.public_key]).execute()

    account2 = await starknet.deploy(contract_class=proxy_cls, 
        constructor_calldata=[
            account_cls_decl.class_hash,
            get_selector_from_name('initialize'),
            3, # all calldata length 
            sts_plugin_decl.class_hash,
            1, # plugin call data length
            signer_key_2.public_key]
    )

    return account, account2, account_cls, sts_plugin_decl, proxy_cls


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
    account, account_2, account_cls, sts_plugin_decl, proxy_cls = account_setup
    session_key_decl = session_plugin_setup

    clean_state = starknet.state.copy()
    account = build_contract(account, state=clean_state)
    account_2 = build_contract(account_2, state=clean_state, custom_abi=account_cls.abi)

    stark_plugin_signer = StarkPluginSigner(
        stark_key=signer_key,
        account=account,
        plugin_class_hash=sts_plugin_decl.class_hash
    )

    stark_plugin_signer_2 = StarkPluginSigner(
        stark_key=signer_key_2,
        account=account_2,
        plugin_class_hash=sts_plugin_decl.class_hash
    )

    session_plugin_signer = SessionPluginSigner(
        stark_key=session_key,
        account=account,
        plugin_class_hash=session_key_decl.class_hash
    )
    dapp = build_contract(dapp_setup, state=clean_state)

    return account, account_2, stark_plugin_signer, stark_plugin_signer_2, session_plugin_signer, dapp


@pytest.mark.asyncio
async def test_addPlugin(network):
    account, account_2, stark_plugin_signer, stark_plugin_signer_2, session_plugin_signer, dapp = network
    plugin_class_hash = session_plugin_signer.plugin_class_hash
    assert (await account.isPlugin(plugin_class_hash).call()).result.success == 0
    await stark_plugin_signer.add_plugin(plugin_class_hash)
    assert (await account.isPlugin(plugin_class_hash).call()).result.success == 1 
    
    assert (await account_2.isPlugin(plugin_class_hash).call()).result.success == 0
    await stark_plugin_signer_2.add_plugin(plugin_class_hash)
    assert (await account_2.isPlugin(plugin_class_hash).call()).result.success == 1


@pytest.mark.asyncio
async def test_removePlugin(network):
    account, account_2, stark_plugin_signer, stark_plugin_signer_2, session_plugin_signer, dapp = network
    plugin_class_hash = session_plugin_signer.plugin_class_hash
    assert (await account.isPlugin(plugin_class_hash).call()).result.success == 0
    await stark_plugin_signer.add_plugin(plugin_class_hash)
    assert (await account.isPlugin(plugin_class_hash).call()).result.success == 1
    await stark_plugin_signer.remove_plugin(plugin_class_hash)
    assert (await account.isPlugin(plugin_class_hash).call()).result.success == 0

    assert (await account_2.isPlugin(plugin_class_hash).call()).result.success == 0
    await stark_plugin_signer_2.add_plugin(plugin_class_hash)
    assert (await account_2.isPlugin(plugin_class_hash).call()).result.success == 1
    await stark_plugin_signer_2.remove_plugin(plugin_class_hash)
    assert (await account_2.isPlugin(plugin_class_hash).call()).result.success == 0


@pytest.mark.asyncio
async def test_supportsInterface(network):
    account, account_2, stark_plugin_signer, stark_plugin_signer_2, session_plugin_signer, dapp = network
    assert (await account.supportsInterface(ERC165_INTERFACE_ID).call()).result.success == 1
    assert (await account.supportsInterface(ERC165_ACCOUNT_INTERFACE_ID).call()).result.success == 1
    assert (await account.supportsInterface(0x123).call()).result.success == 0
    assert (await account.getVersion().call()).result.version == str_to_felt(VERSION)


@pytest.mark.asyncio
async def test_dapp(network):
    account, account_2, stark_plugin_signer, stark_plugin_signer_2, session_plugin_signer, dapp = network
    assert (await dapp.get_balance().call()).result.res == 0
    tx_exec_info = await stark_plugin_signer.send_transaction(
        calls=[(dapp.contract_address, 'set_balance', [47])],
    )
    assert_event_emitted(
        tx_exec_info,
        from_address=stark_plugin_signer.account.contract_address,
        name='transaction_executed',
        data=[]
    )
    assert (await dapp.get_balance().call()).result.res == 47


@pytest.mark.asyncio
async def test_executeOnPlugin(network):
    # Account 2 tries to change the signer key on Account 1, via executeOnPlugin and via readOnPlugin

    account, account_2, stark_plugin_signer, stark_plugin_signer_2, session_plugin_signer, dapp = network
    read_execution_info = await stark_plugin_signer.read_on_plugin("getPublicKey")
    assert read_execution_info.result[0] == [signer_key.public_key]

    set_public_key_arguments = [signer_key_2.public_key]
    exec_arguments = [
        stark_plugin_signer.plugin_class_hash,
        get_selector_from_name("setPublicKey"),
        len(set_public_key_arguments),
        *set_public_key_arguments
    ]
    await assert_revert(
        stark_plugin_signer_2.send_transaction(calls=[(stark_plugin_signer.account.contract_address, 'executeOnPlugin', exec_arguments)]),
        reverted_with="StarkSigner: only self"
    )

    read_execution_info = await stark_plugin_signer.read_on_plugin("getPublicKey")
    assert read_execution_info.result[0] == [signer_key.public_key]