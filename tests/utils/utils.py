from starkware.crypto.signature.signature import private_to_stark_key
from starkware.starknet.services.api.contract_class import ContractClass
from starkware.starknet.testing.contract import StarknetContract
from starkware.starknet.testing.state import StarknetState
from starkware.starkware_utils.error_handling import StarkException
from starkware.starknet.compiler.compile import compile_starknet_files
from starkware.starknet.compiler.compile import get_selector_from_name
from starkware.starknet.business_logic.execution.objects import Event
from typing import Optional, List, Tuple
from starkware.crypto.signature.signature import private_to_stark_key, sign

ERC165_INTERFACE_ID = 0x01ffc9a7
ERC165_ACCOUNT_INTERFACE_ID = 0x3943f10f

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
