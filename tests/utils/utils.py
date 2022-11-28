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
from starkware.starknet.public.abi import AbiType
from starkware.starknet.definitions.error_codes import StarknetErrorCode


ERC165_INTERFACE_ID = 0x01ffc9a7
ERC165_ACCOUNT_INTERFACE_ID = 0x3943f10f

def str_to_felt(text: str) -> int:
    b_text = bytes(text, 'UTF-8')
    return int.from_bytes(b_text, "big")

def compile(path: str) -> ContractClass:
    contract_cls = compile_starknet_files([path], debug_info=True, disable_hint_validation=True)
    return contract_cls


def cached_contract(state: StarknetState, _class: ContractClass, deployed: StarknetContract) -> StarknetContract:
    return build_contract(
        state=state,
        contract=deployed,
        custom_abi=_class.abi
    )


def copy_contract_state(contract: StarknetContract) -> StarknetContract:
    return build_contract(contract=contract, state=contract.state.copy())


def build_contract(contract: StarknetContract, state: StarknetState = None,  custom_abi: AbiType = None) -> StarknetContract:
    return StarknetContract(
        state=contract.state if state is None else state,
        abi=contract.abi if custom_abi is None else custom_abi,
        contract_address=contract.contract_address,
        deploy_call_info=contract.deploy_call_info
    )


async def assert_revert(fun, reverted_with: Optional[str] = None):
    try:
        res = await fun
        assert False, "Transaction didn't revert as expected"
    except StarkException as err:
        _, error = err.args
        assert error['code'] == StarknetErrorCode.TRANSACTION_FAILED, f"assert expected: {StarknetErrorCode.TRANSACTION_FAILED}, got error: {error['code']}"
        if reverted_with is not None:
            errors_found = [s.removeprefix("Error message: ") for s in error['message'].splitlines() if s.startswith("Error message: ")]
            assert reverted_with in errors_found, f"assert expected: {reverted_with}, found errors: {errors_found}"


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
