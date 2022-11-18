%lang starknet

from starkware.cairo.common.cairo_builtins import HashBuiltin, SignatureBuiltin
from starkware.cairo.common.bool import TRUE, FALSE

const ERC165_ACCOUNT_INTERFACE_ID = 0x3943f10f;

@view
func supportsInterface{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(
    interfaceId: felt
) -> (success: felt) {
    // IAccount
    if (interfaceId == ERC165_ACCOUNT_INTERFACE_ID) {
        return (TRUE,);
    }

    return (FALSE,);
}
