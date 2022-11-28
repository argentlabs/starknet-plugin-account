%lang starknet

from starkware.cairo.common.cairo_builtins import HashBuiltin
from starkware.starknet.common.syscalls import get_caller_address
from contracts.test.interface import NFT

@storage_var
func free_nft_id() -> (id: felt) {
}

@storage_var
func nfts(id: felt) -> (nft: NFT) {
}

@external
func mint_nft{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}() -> (nft_id: felt) {
    let (nft_id) = free_nft_id.read();
    let (caller) = get_caller_address();

    // we mint the nft
    nfts.write(nft_id, NFT(caller, 'no name'));

    // then we update the free_id
    free_nft_id.write(nft_id + 1);

    return (nft_id=nft_id);
}

@external
func set_nft_name{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(id, name) {
    let (nft: NFT) = nfts.read(id);
    let (caller) = get_caller_address();

    // we ensure the caller owns the nft
    assert nft.owner = caller;

    // then we update the nft name
    nfts.write(id, NFT(caller, name));
    return ();
}

@view
func read_nft{syscall_ptr: felt*, pedersen_ptr: HashBuiltin*, range_check_ptr}(id: felt) -> (
    nft: NFT
) {
    return nfts.read(id);
}