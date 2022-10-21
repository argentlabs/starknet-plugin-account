import pytest
import asyncio
import logging
from starkware.starknet.testing.starknet import Starknet
from starkware.starknet.definitions.general_config import StarknetChainId
from starkware.starknet.business_logic.state.state import BlockInfo
from utils.utils import assert_revert, compile, cached_contract, assert_event_emitted, StarkKeyPair, ERC165_INTERFACE_ID, ERC165_ACCOUNT_INTERFACE_ID
from utils.plugin_signer import StarkPluginSigner
from utils.session_keys_utils import build_session, SessionPluginSigner


LOGGER = logging.getLogger(__name__)

signer_key = StarkKeyPair(123456789987654321)
session_key = StarkKeyPair(666666666666666666)
wrong_session_key = StarkKeyPair(6767676767)

DEFAULT_TIMESTAMP = 1640991600

@pytest.fixture(scope='module')
def event_loop():
    return asyncio.new_event_loop()

@pytest.fixture(scope='module')
async def get_starknet():
    starknet = await Starknet.empty()
    return starknet


def update_starknet_block(starknet, block_number=1, block_timestamp=DEFAULT_TIMESTAMP):
    starknet.state.state.block_info = BlockInfo(
        block_number=block_number,
        block_timestamp=block_timestamp,
        gas_price=0,
        starknet_version="0.9.1",
        sequencer_address=starknet.state.state.block_info.sequencer_address)


def reset_starknet_block(starknet):
    update_starknet_block(starknet=starknet)


@pytest.fixture(scope='module')
def contract_classes():
    account_cls = compile('contracts/account/PluginAccount.cairo')
    dapp_cls = compile('contracts/test/Dapp.cairo')
    session_key_cls = compile('contracts/plugins/SessionKey.cairo')
    sts_plugin_cls = compile("contracts/plugins/signer/StarkSigner.cairo")

    return account_cls, dapp_cls, session_key_cls, sts_plugin_cls


@pytest.fixture(scope='module')
async def account_init(contract_classes):
    account_cls, dapp_cls, session_key_cls, sts_plugin_cls = contract_classes
    starknet = await Starknet.empty()

    session_key_class = await starknet.declare(contract_class=session_key_cls)
    sts_plugin_decl = await starknet.declare(contract_class=sts_plugin_cls)

    account = await starknet.deploy(
        contract_class=account_cls,
        constructor_calldata=[]
    )
    dapp1 = await starknet.deploy(
        contract_class=dapp_cls,
        constructor_calldata=[],
    )
    dapp2 = await starknet.deploy(
        contract_class=dapp_cls,
        constructor_calldata=[],
    )

    await account.initialize(sts_plugin_decl.class_hash, [signer_key.public_key]).execute()

    return starknet.state, account, dapp1, dapp2, session_key_class.class_hash, sts_plugin_decl.class_hash


@pytest.fixture
def account_factory(contract_classes, account_init):
    account_cls, dapp_cls, session_key_cls, ECDSABasePlugin_cls = contract_classes
    state, account, dapp1, dapp2, session_key_class, sts_plugin_hash = account_init
    _state = state.copy()
    account = cached_contract(_state, account_cls, account)
    dapp1 = cached_contract(_state, dapp_cls, dapp1)
    dapp2 = cached_contract(_state, dapp_cls, dapp2)

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
    return account, stark_plugin_signer, session_plugin_signer, dapp1, dapp2, session_key_class


@pytest.mark.asyncio
async def test_call_dapp_with_session_key(account_factory, get_starknet):
    account, stark_plugin_signer, session_plugin_signer, dapp1, dapp2, session_key_class = account_factory
    starknet = get_starknet

    # add session key plugin
    await stark_plugin_signer.add_plugin(session_key_class)

    # authorise session key
    session = build_session(
        signer=stark_plugin_signer,
        allowed_calls=[
            (dapp1.contract_address, 'set_balance'),
            (dapp1.contract_address, 'set_balance_double'),
            (dapp2.contract_address, 'set_balance'),
            (dapp2.contract_address, 'set_balance_double'),
            (dapp2.contract_address, 'set_balance_times3'),
        ],
        session_public_key=session_key.public_key,
        session_expiration=DEFAULT_TIMESTAMP + 10,
        chain_id=StarknetChainId.TESTNET.value,
        account_address=account.contract_address
    )

    assert (await dapp1.get_balance().call()).result.res == 0
    update_starknet_block(starknet=starknet, block_timestamp=DEFAULT_TIMESTAMP)
    # call with session key
    tx_exec_info = await session_plugin_signer.send_transaction(
        calls=[
            (dapp1.contract_address, 'set_balance', [47]),
            (dapp2.contract_address, 'set_balance_times3', [20])
        ],
        session=session
    )

    assert_event_emitted(
        tx_exec_info,
        from_address=account.contract_address,
        name='transaction_executed',
        data=[]
    )
    # check it worked
    assert (await dapp1.get_balance().call()).result.res == 47
    assert (await dapp2.get_balance().call()).result.res == 60

    # wrong policy call with random proof
    await assert_revert(
        session_plugin_signer.send_transaction_with_proofs(
            calls=[(dapp1.contract_address, 'set_balance_times3', [47])],
            proofs=[session.proofs[0], session.proofs[4]],
            session=session
        ),
        reverted_with="SessionKey: not allowed by policy"
    )

    # revoke session key
    tx_exec_info = await stark_plugin_signer.execute_on_plugin("revokeSessionKey", [session_key.public_key], plugin=session_key_class)
    assert_event_emitted(
        tx_exec_info,
        from_address=account.contract_address,
        name='session_key_revoked',
        data=[session_key.public_key]
    )
    # check the session key is no longer authorised
    await assert_revert(
        session_plugin_signer.send_transaction(
            calls=[(dapp1.contract_address, 'set_balance', [47])],
            session=session
        ),
        reverted_with="SessionKey: session key revoked"
    )

@pytest.mark.asyncio
async def test_supportsInterface(account_factory):
    _, stark_plugin_signer, _, _, _, session_key_class = account_factory
    await stark_plugin_signer.add_plugin(session_key_class)
    assert (await stark_plugin_signer.read_on_plugin("supportsInterface", [ERC165_INTERFACE_ID], plugin=session_key_class)).result[0] == [1]
    assert (await stark_plugin_signer.read_on_plugin("supportsInterface", [ERC165_ACCOUNT_INTERFACE_ID], plugin=session_key_class)).result[0] == [0]
    assert (await stark_plugin_signer.read_on_plugin("supportsInterface", [ERC165_ACCOUNT_INTERFACE_ID], plugin=session_key_class)).result[0] == [0]