import pytest
import asyncio
import logging
from starkware.starknet.testing.starknet import Starknet
from utils.utils import str_to_felt, cached_contract, build_contract, StarkKeyPair, compile, assert_revert
from utils.plugin_signer import StarkPluginSigner
from utils.better_multicall_signer import BetterMulticallSigner, BetterMulticallSignerFake
from starknet_py.cairo.felt import encode_shortstring


key_pair = StarkKeyPair(1234)
new_key_pair = StarkKeyPair(5678)

betterMulticallSigner = BetterMulticallSigner(1234)
betterMulticallSignerFake = BetterMulticallSignerFake(12345)

LOGGER = logging.getLogger(__name__)

@pytest.fixture(scope='module')
def event_loop():
    return asyncio.new_event_loop()

@pytest.fixture(scope='module')
def contract_classes():
    account_cls = compile('contracts/account/PluginAccount.cairo')
    sts_plugin_cls = compile("contracts/plugins/signer/StarkSigner.cairo")
    bm_plugin_cls = compile("contracts/plugins/execution/BetterMulticall.cairo")
    nft_cls = compile("contracts/test/NFT.cairo")
    
    return account_cls, sts_plugin_cls, bm_plugin_cls, nft_cls

@pytest.fixture(scope='module')
async def contract_init(contract_classes):
    account_cls, sts_plugin_cls, bm_plugin_cls, nft_cls = contract_classes
    starknet = await Starknet.empty()

    sts_plugin_decl = await starknet.declare(contract_class=sts_plugin_cls)
    bm_plugin_decl = await starknet.declare(contract_class=bm_plugin_cls)

    account = await starknet.deploy(
        contract_class=account_cls,
        constructor_calldata=[]
    )

    NFT = await starknet.deploy(
        contract_class=nft_cls,
        constructor_calldata=[]
    )
    
    await account.initialize(sts_plugin_decl.class_hash, [key_pair.public_key]).execute()

    return starknet.state, account, NFT, sts_plugin_decl.class_hash, bm_plugin_decl.class_hash

@pytest.fixture
def contract_factory(contract_classes, contract_init):
    account_cls, sts_plugin_cls, bm_plugin_cls, nft_cls = contract_classes
    state, account, nft, sts_plugin_hash, bm_plugin_hash = contract_init
    _state = state.copy()

    account = build_contract(account, state=_state)
    nft = cached_contract(_state, nft_cls, nft)

    stark_plugin_signer = StarkPluginSigner(
        stark_key=key_pair,
        account=account,
        plugin_class_hash=sts_plugin_hash
    )

    return account, stark_plugin_signer, nft, sts_plugin_hash, bm_plugin_hash

@pytest.mark.asyncio
async def test_initialise(contract_factory):
    account, stark_plugin_signer, nft, sts_plugin_hash, bm_plugin_hash = contract_factory

    execution_info = await account.getName().call()
    assert execution_info.result == (str_to_felt('PluginAccount'),)

    execution_info = await account.isPlugin(sts_plugin_hash).call()
    assert execution_info.result == (1,)

    execution_info = await stark_plugin_signer.read_on_plugin("getPublicKey")
    assert execution_info.result[0] == [stark_plugin_signer.public_key]

@pytest.mark.asyncio
async def test_change_public_key(contract_factory):
    account, stark_plugin_signer, nft, sts_plugin_hash, bm_plugin_hash = contract_factory
    
    await stark_plugin_signer.execute_on_plugin(
        selector_name="setPublicKey",
        arguments=[new_key_pair.public_key]
    )

    execution_info = await stark_plugin_signer.read_on_plugin("getPublicKey")
    assert execution_info.result[0] == [new_key_pair.public_key]

@pytest.mark.asyncio
async def test_better_multicall(contract_factory):
    account, stark_plugin_signer, nft, sts_plugin_hash, bm_plugin_hash = contract_factory

    await stark_plugin_signer.add_plugin(plugin=bm_plugin_hash, plugin_arguments=[0])

    await betterMulticallSigner.send_transaction(
        account,
        [sts_plugin_hash, 2],
        [bm_plugin_hash, 0], 
        calls=[
            (nft.contract_address, 'mint_nft', 0, []),
            (nft.contract_address, 'set_nft_name', 2, [ 1, 0, 0, encode_shortstring('aloha')]),
        ]) 

    execution_info = await nft.read_nft(0).call()
    assert execution_info.result.nft.owner == account.contract_address
    assert execution_info.result.nft.name == encode_shortstring('aloha')

@pytest.mark.asyncio
async def test_better_multicall_alone(contract_factory):
    account, stark_plugin_signer, nft, sts_plugin_hash, bm_plugin_hash = contract_factory

    await stark_plugin_signer.add_plugin(plugin=bm_plugin_hash, plugin_arguments=[0])
    await assert_revert(
        betterMulticallSignerFake.send_transaction(
            account,
            [bm_plugin_hash, 0], 
            calls=[
                (nft.contract_address, 'mint_nft', 0, []),
                (nft.contract_address, 'set_nft_name', 2, [ 1, 0, 0, encode_shortstring('aloha')]),
            ]) 
    )
    execution_info = await nft.read_nft(0).call()
    assert execution_info.result.nft.owner == account.contract_address
    assert execution_info.result.nft.name == encode_shortstring('aloha')