from typing import Optional, List, Tuple
from starkware.crypto.signature.signature import private_to_stark_key, sign
from starkware.starknet.definitions.general_config import StarknetChainId
from starkware.starknet.core.os.transaction_hash.transaction_hash import calculate_transaction_hash_common, TransactionHashPrefix
from starkware.starknet.services.api.gateway.transaction import InvokeFunction
from starkware.starknet.business_logic.transaction.objects import InternalTransaction, TransactionExecutionInfo
from starkware.starknet.compiler.compile import get_selector_from_name

TRANSACTION_VERSION = 1

class BetterMulticallSigner():
    def __init__(self, private_key):
        self.private_key = private_key
        self.public_key = private_to_stark_key(private_key)

    async def send_transaction(
        self,
        account,
        plugin_validation,
        plugin_execution,
        calls,
        nonce=None,
        max_fee=0
    ) -> TransactionExecutionInfo:
        # hexify address before passing to from_call_to_call_array
        call_array, calldata = from_call_to_better_call_array(calls)

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
            signature=[*plugin_validation, sig_r, sig_s, *plugin_execution],
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

def from_call_to_better_call_array(calls):
    call_array = []
    calldata = []
    for call in calls:
        assert len(call) == 4, "Invalid call parameters"
        entry = (call[0], get_selector_from_name(call[1]), len(calldata), call[2])
        call_array.append(entry)
        calldata.extend(call[3])
    return call_array, calldata