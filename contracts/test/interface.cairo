%lang starknet

struct NFT {
    owner: felt,
    name: felt,
}

@contract_interface
namespace ExampleContract {
    func mint_nft() -> (nft_id: felt) {
    }

    func set_nft_name(id, name) {
    }

    func read_nft(id) -> (nft: NFT) {
    }
}