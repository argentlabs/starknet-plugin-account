import pytest
import asyncio
from starkware.starknet.testing.starknet import Starknet
from utils.utils import str_to_felt, build_contract, compile
from utils.utils import StarkKeyPair, ERC165_INTERFACE_ID, ERC165_ACCOUNT_INTERFACE_ID, assert_event_emitted, assert_revert
from utils.plugin_signer import StarkPluginSigner

key_pair = StarkKeyPair(1234)
new_key_pair = StarkKeyPair(5678)


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

    sts_plugin_decl = await starknet.declare(contract_class=sts_plugin_cls)

    account = await starknet.deploy(
        contract_class=account_cls,
        constructor_calldata=[]
    )

    await account.initialize(sts_plugin_decl.class_hash, [key_pair.public_key]).execute()

    return account, sts_plugin_decl.class_hash


@pytest.fixture(scope='module')
async def dapp(starknet: Starknet):
    dapp_cls = compile('contracts/test/Dapp.cairo')
    await starknet.declare(contract_class=dapp_cls)
    return await starknet.deploy(contract_class=dapp_cls, constructor_calldata=[])


@pytest.fixture
def contracts(starknet: Starknet, account_setup, dapp):
    account, sts_plugin_address = account_setup
    clean_state = starknet.state.copy()

    account = build_contract(account, state=clean_state)

    stark_plugin_signer = StarkPluginSigner(
        stark_key=key_pair,
        account=account,
        plugin_address=sts_plugin_address
    )

    dapp = build_contract(dapp, state=clean_state)

    return account, stark_plugin_signer, sts_plugin_address, dapp


@pytest.mark.asyncio
async def test_initialise(contracts):
    account, stark_plugin_signer, sts_plugin_hash, _ = contracts

    execution_info = await account.getName().call()
    assert execution_info.result == (str_to_felt('PluginAccount'),)

    execution_info = await account.isPlugin(sts_plugin_hash).call()
    assert execution_info.result == (1,)

    execution_info = await stark_plugin_signer.read_on_plugin("getPublicKey")
    assert execution_info.result[0] == [stark_plugin_signer.public_key]


@pytest.mark.asyncio
async def test_change_public_key(contracts):
    account, stark_plugin_signer, sts_plugin_hash, _ = contracts

    await stark_plugin_signer.execute_on_plugin(
        selector_name="setPublicKey",
        arguments=[new_key_pair.public_key]
    )

    execution_info = await stark_plugin_signer.read_on_plugin("getPublicKey")
    assert execution_info.result[0] == [new_key_pair.public_key]


@pytest.mark.asyncio
async def test_supportsInterface(contracts):
    account, stark_plugin_signer, sts_plugin_hash, _ = contracts
    assert (await stark_plugin_signer.read_on_plugin("supportsInterface", [ERC165_INTERFACE_ID])).result[0] == [1]
    assert (await stark_plugin_signer.read_on_plugin("supportsInterface", [ERC165_ACCOUNT_INTERFACE_ID])).result[0] == [0]
    assert (await stark_plugin_signer.read_on_plugin("supportsInterface", [ERC165_ACCOUNT_INTERFACE_ID])).result[0] == [0]


@pytest.mark.asyncio
async def test_dapp(contracts):
    account, stark_plugin_signer, sts_plugin_hash, dapp = contracts
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


@pytest.mark.asyncio
async def test_dapp_bad_signature(contracts):
    account, stark_plugin_signer, sts_plugin_hash, dapp = contracts
    assert (await dapp.get_balance().call()).result.res == 0

    signed_tx = await stark_plugin_signer.get_signed_transaction(
        calls=[(dapp.contract_address, 'set_balance', [47])],
    )
    signed_tx.signature[2] = 3333

    await assert_revert(
        stark_plugin_signer.send_signed_tx(signed_tx)
    )
    assert (await dapp.get_balance().call()).result.res == 0


@pytest.mark.asyncio
async def test_dapp_long_signature(contracts):
    account, stark_plugin_signer, sts_plugin_hash, dapp = contracts
    assert (await dapp.get_balance().call()).result.res == 0

    signed_tx = await stark_plugin_signer.get_signed_transaction(
        calls=[(dapp.contract_address, 'set_balance', [47])],
    )
    signed_tx.signature.extend([1, 1, 1, 1])
    await assert_revert(
        stark_plugin_signer.send_signed_tx(signed_tx)
    )
    assert (await dapp.get_balance().call()).result.res == 0
