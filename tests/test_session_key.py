import pytest
import asyncio
import logging
from starkware.starknet.testing.starknet import Starknet
from starkware.starknet.definitions.general_config import StarknetChainId
from starkware.starknet.business_logic.state.state import BlockInfo
from utils.utils import assert_revert, compile, cached_contract, assert_event_emitted, StarkKeyPair, build_contract, ERC165_INTERFACE_ID, ERC165_ACCOUNT_INTERFACE_ID
from utils.plugin_signer import StarkPluginSigner
from utils.session_keys_utils import build_session, SessionPluginSigner
from starkware.starknet.compiler.compile import get_selector_from_name


LOGGER = logging.getLogger(__name__)

signer_key = StarkKeyPair(123456789987654321)
signer_key_2 = StarkKeyPair(123456789987654322)
session_key = StarkKeyPair(666666666666666666)
wrong_session_key = StarkKeyPair(6767676767)

DEFAULT_TIMESTAMP = 1640991600


@pytest.fixture(scope='module')
def event_loop():
    return asyncio.new_event_loop()


@pytest.fixture(scope='module')
async def starknet():
    return await Starknet.empty()


def update_starknet_block(starknet, block_number=1, block_timestamp=DEFAULT_TIMESTAMP):
    old_block_info = starknet.state.state.block_info
    starknet.state.state.block_info = BlockInfo(
        block_number=block_number,
        block_timestamp=block_timestamp,
        gas_price=old_block_info.gas_price,
        starknet_version=old_block_info.starknet_version,
        sequencer_address=old_block_info.sequencer_address
    )


def reset_starknet_block(starknet):
    update_starknet_block(starknet=starknet)


@pytest.fixture(scope='module')
async def account_setup(starknet: Starknet):
    account_cls = compile('contracts/account/PluginAccount.cairo')
    session_key_cls = compile('contracts/plugins/SessionKey.cairo')
    sts_plugin_cls = compile("contracts/plugins/signer/StarkSigner.cairo")

    session_key_class = await starknet.declare(contract_class=session_key_cls)
    sts_plugin_decl = await starknet.declare(contract_class=sts_plugin_cls)

    account = await starknet.deploy(contract_class=account_cls, constructor_calldata=[])
    account_2 = await starknet.deploy(contract_class=account_cls, constructor_calldata=[])

    await account.initialize(sts_plugin_decl.class_hash, [signer_key.public_key]).execute()
    await account_2.initialize(sts_plugin_decl.class_hash, [signer_key_2.public_key]).execute()

    return account, account_2, session_key_class.class_hash, sts_plugin_decl.class_hash


@pytest.fixture(scope='module')
async def dapp_setup(starknet: Starknet):
    dapp_cls = compile('contracts/test/Dapp.cairo')
    await starknet.declare(contract_class=dapp_cls)
    dapp1 = await starknet.deploy(contract_class=dapp_cls, constructor_calldata=[])
    dapp2 = await starknet.deploy(contract_class=dapp_cls, constructor_calldata=[])
    return dapp1, dapp2


@pytest.fixture
def contracts(starknet: Starknet, account_setup, dapp_setup):
    account, account_2, session_plugin_address, sts_plugin_address = account_setup
    dapp1, dapp2 = dapp_setup
    clean_state = starknet.state.copy()

    account = build_contract(account, state=clean_state)
    account_2 = build_contract(account_2, state=clean_state)

    dapp1 = build_contract(dapp1, state=clean_state)
    dapp2 = build_contract(dapp2, state=clean_state)

    stark_plugin_signer = StarkPluginSigner(
        stark_key=signer_key,
        account=account,
        plugin_address=sts_plugin_address
    )

    stark_plugin_signer_2 = StarkPluginSigner(
        stark_key=signer_key_2,
        account=account_2,
        plugin_address=sts_plugin_address
    )

    session_plugin_signer = SessionPluginSigner(
        stark_key=session_key,
        account=account,
        plugin_address=session_plugin_address
    )

    return account, stark_plugin_signer, stark_plugin_signer_2, session_plugin_signer, dapp1, dapp2, session_plugin_address


@pytest.mark.asyncio
async def test_call_dapp_with_session_key(starknet: Starknet, contracts):
    account, stark_plugin_signer, stark_plugin_signer_2, session_plugin_signer, dapp1, dapp2, session_key_class = contracts

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
            proofs=[session.proofs[0]],
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
async def test_supportsInterface(contracts):
    account, stark_plugin_signer, stark_plugin_signer_2, session_plugin_signer, dapp1, dapp2, session_key_class = contracts
    await stark_plugin_signer.add_plugin(session_key_class)
    assert (await stark_plugin_signer.read_on_plugin("supportsInterface", [ERC165_INTERFACE_ID], plugin=session_key_class)).result[0] == [1]
    assert (await stark_plugin_signer.read_on_plugin("supportsInterface", [ERC165_ACCOUNT_INTERFACE_ID], plugin=session_key_class)).result[0] == [0]
    assert (await stark_plugin_signer.read_on_plugin("supportsInterface", [ERC165_ACCOUNT_INTERFACE_ID], plugin=session_key_class)).result[0] == [0]


@pytest.mark.asyncio
async def test_dapp_bad_signature(starknet: Starknet, contracts):
    account, stark_plugin_signer, stark_plugin_signer_2, session_plugin_signer, dapp, dapp2, session_key_class = contracts
    assert (await dapp.get_balance().call()).result.res == 0

    await stark_plugin_signer.add_plugin(session_key_class)
    update_starknet_block(starknet=starknet, block_timestamp=DEFAULT_TIMESTAMP)

    session = build_session(
        signer=stark_plugin_signer,
        allowed_calls=[(dapp.contract_address, 'set_balance')],
        session_public_key=session_key.public_key,
        session_expiration=DEFAULT_TIMESTAMP + 10,
        chain_id=StarknetChainId.TESTNET.value,
        account_address=account.contract_address
    )

    signed_tx = await session_plugin_signer.get_signed_transaction(
        calls=[(dapp.contract_address, 'set_balance', [47])],
        session=session
    )
    signed_tx.signature[2] = 3333

    await assert_revert(
        session_plugin_signer.send_signed_tx(signed_tx)
    )
    assert (await dapp.get_balance().call()).result.res == 0


@pytest.mark.asyncio
async def test_dapp_long_signature(starknet: Starknet, contracts):
    account, stark_plugin_signer, stark_plugin_signer_2, session_plugin_signer, dapp, dapp2, session_key_class = contracts
    assert (await dapp.get_balance().call()).result.res == 0

    await stark_plugin_signer.add_plugin(session_key_class)
    update_starknet_block(starknet=starknet, block_timestamp=DEFAULT_TIMESTAMP)

    session = build_session(
        signer=stark_plugin_signer,
        allowed_calls=[(dapp.contract_address, 'set_balance')],
        session_public_key=session_key.public_key,
        session_expiration=DEFAULT_TIMESTAMP + 10,
        chain_id=StarknetChainId.TESTNET.value,
        account_address=account.contract_address
    )

    signed_tx = await session_plugin_signer.get_signed_transaction(
        calls=[(dapp.contract_address, 'set_balance', [47])],
        session= session
    )
    signed_tx.signature.extend([1, 1, 1, 1])
    await assert_revert(
        session_plugin_signer.send_signed_tx(signed_tx),
        reverted_with="SessionKey: invalid signature length"
    )

    signed_tx = await session_plugin_signer.get_signed_transaction(
        calls=[(dapp.contract_address, 'set_balance', [47])],
        session=session
    )
    index_proofs_len = 7
    proofs_len = signed_tx.signature[index_proofs_len]
    index_session_token_len = index_proofs_len + proofs_len + 1
    assert signed_tx.signature[index_session_token_len] == len(session.session_token)

    signed_tx.signature[index_proofs_len] = proofs_len + 1
    signed_tx.signature.insert(index_session_token_len, 3333)

    await assert_revert(
        session_plugin_signer.send_signed_tx(signed_tx),
        reverted_with="SessionKey: invalid proof len"
    )

    assert (await dapp.get_balance().call()).result.res == 0

    signed_tx = await session_plugin_signer.get_signed_transaction(
        calls=[(dapp.contract_address, 'set_balance', [47])],
        session=session,
    )
    tx_exec_info = await session_plugin_signer.send_signed_tx(signed_tx)

    assert_event_emitted(
        tx_exec_info,
        from_address=account.contract_address,
        name='transaction_executed',
        data=[]
    )
    # check it worked
    assert (await dapp.get_balance().call()).result.res == 47

@pytest.mark.asyncio
async def test_executeOnPlugin(starknet: Starknet, contracts):
    # Account 2 tries to revoke a session key on Account 1, via executeOnPlugin and via readOnPlugin

    account, stark_plugin_signer, stark_plugin_signer_2, session_plugin_signer, dapp1, dapp2, session_key_class = contracts

    await stark_plugin_signer.add_plugin(session_key_class)
    update_starknet_block(starknet=starknet, block_timestamp=DEFAULT_TIMESTAMP)

    session = build_session(
        signer=stark_plugin_signer,
        allowed_calls=[(dapp1.contract_address, 'set_balance')],
        session_public_key=session_key.public_key,
        session_expiration=DEFAULT_TIMESTAMP + 10,
        chain_id=StarknetChainId.TESTNET.value,
        account_address=account.contract_address
    )

    revoke_session_key_arguments = [session.session_hash]
    exec_arguments = [
        session_plugin_signer.plugin_address,
        get_selector_from_name("revokeSessionKey"),
        len(revoke_session_key_arguments),
        *revoke_session_key_arguments
    ]
    await assert_revert(
        stark_plugin_signer_2.send_transaction(
            [(stark_plugin_signer.account.contract_address, 'executeOnPlugin', exec_arguments)]
        ),
        reverted_with="PluginAccount: only self"
    )

    await assert_revert(
        stark_plugin_signer_2.send_transaction(
            [(stark_plugin_signer.account.contract_address, 'readOnPlugin', exec_arguments)]
        ),
        reverted_with="SessionKey: only self"
    )
