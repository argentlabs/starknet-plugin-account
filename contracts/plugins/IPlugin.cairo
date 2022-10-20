%lang starknet

from contracts.account.library import Call

@contract_interface
namespace IPlugin {

    func initialize(data_len: felt, data: felt*) {
    }

    func validate(
        hash: felt, 
        sig_len: felt,
        sig: felt*,
        calls_len: felt,
        calls: Call*
    ) {
    }

    func execute(
        calls_len: felt,
        calls: Call*,
    ) -> (calls_len: felt, calls: Call*, response_len: felt, response: felt*) {
    }
}
