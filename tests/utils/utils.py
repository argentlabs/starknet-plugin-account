from starkware.crypto.signature.signature import private_to_stark_key
from starkware.starknet.services.api.contract_class import ContractClass
from starkware.starknet.testing.contract import StarknetContract
from starkware.starknet.testing.state import StarknetState
from starkware.starknet.definitions.general_config import StarknetChainId
from starkware.starkware_utils.error_handling import StarkException
from starkware.starknet.core.os.transaction_hash.transaction_hash import calculate_transaction_hash_common, TransactionHashPrefix
from starkware.starknet.services.api.gateway.transaction import InvokeFunction, Declare
from starkware.starknet.business_logic.transaction.objects import InternalTransaction, TransactionExecutionInfo
from starkware.starknet.compiler.compile import compile_starknet_files
from starkware.starknet.compiler.compile import get_selector_from_name
from starkware.starknet.business_logic.execution.objects import Event, OrderedEvent
from typing import Optional, List, Tuple

TRANSACTION_VERSION = 1

def str_to_felt(text: str) -> int:
    b_text = bytes(text, 'UTF-8')
    return int.from_bytes(b_text, "big")

def compile(path: str) -> ContractClass:
    contract_cls = compile_starknet_files([path], debug_info=True)
    return contract_cls

def cached_contract(state: StarknetState, _class: ContractClass, deployed: StarknetContract) -> StarknetContract:
    contract = StarknetContract(
        state=state,
        abi=_class.abi,
        contract_address=deployed.contract_address,
        deploy_call_info=deployed.deploy_call_info
    )
    return contract


async def assert_revert(fun, reverted_with=None):
    try:
        await fun
        assert False
    except StarkException as err:
        _, error = err.args
        if reverted_with is not None:
            assert reverted_with in error['message']

def assert_event_emitted(tx_exec_info, from_address, name, data = []):
    if not data:
        raw_events = [Event(from_address=event.from_address, keys=event.keys, data=[]) for event in tx_exec_info.get_sorted_events()]
    else: 
        raw_events = [Event(from_address=event.from_address, keys=event.keys, data=event.data) for event in tx_exec_info.get_sorted_events()] 

    assert Event(
        from_address=from_address,
        keys=[get_selector_from_name(name)],
        data=data,
    ) in raw_events


class StarkKeyPair:
    def __init__(self, private_key: int):
        self.private_key = private_key
        self.public_key = private_to_stark_key(private_key)


class PluginSigner():
    def __init__(self, private_key):
        self.private_key = private_key
        self.public_key = private_to_stark_key(private_key)

    async def send_transaction(
        self,
        account,
        plugin_id,
        plugin,
        calls,
        nonce=None,
        max_fee=0
    ) -> TransactionExecutionInfo:
        # hexify address before passing to from_call_to_call_array
        call_array, calldata = from_call_to_call_array(calls)

        raw_invocation = account.__execute__(call_array, calldata)
        state = raw_invocation.state

        if nonce is None:
            nonce = await state.state.get_nonce_at(contract_address=account.contract_address)

        transaction_hash = calculate_transaction_hash_common(
            tx_hash_prefix=TransactionHashPrefix.INVOKE,
            version=TRANSACTION_VERSION,
            contract_address=account.contract_address,
            entry_point_selector=0,
            calldata=raw_invocation.calldata,
            max_fee=max_fee,
            chain_id=StarknetChainId.TESTNET.value,
            additional_data=[nonce],
        )

        sig_r, sig_s = self.sign(transaction_hash)

        # craft invoke and execute tx
        external_tx = InvokeFunction(
            contract_address=account.contract_address,
            calldata=raw_invocation.calldata,
            entry_point_selector=None,
            signature=[plugin_id, sig_r, sig_s, *plugin],
            max_fee=max_fee,
            version=TRANSACTION_VERSION,
            nonce=nonce,
        )

        tx = InternalTransaction.from_external(
            external_tx=external_tx, general_config=state.general_config
        )
        execution_info = await state.execute_tx(tx=tx)
        return execution_info
    
    def sign(self, message_hash: int) -> Tuple[int, int]:
        return sign(msg_hash=message_hash, priv_key=self.private_key)


def from_call_to_call_array(calls):
    call_array = []
    calldata = []
    for call in calls:
        assert len(call) == 3, "Invalid call parameters"
        entry = (call[0], get_selector_from_name(call[1]), len(calldata), len(call[2]))
        call_array.append(entry)
        calldata.extend(call[2])
    return call_array, calldata