%lang starknet

from starkware.cairo.common.registers import get_fp_and_pc
from starkware.starknet.common.syscalls import get_contract_address
from starkware.cairo.common.signature import verify_ecdsa_signature
from starkware.cairo.common.cairo_builtins import HashBuiltin, SignatureBuiltin
from starkware.cairo.common.alloc import alloc
from starkware.cairo.common.memcpy import memcpy
from starkware.starknet.common.syscalls import call_contract, get_caller_address, get_tx_info
from starkware.cairo.common.bool import (TRUE)
from starkware.cairo.common.math import assert_not_zero

from contracts.account.IPlugin import IPlugin

#
# Storage
#

@storage_var
func Signer_public_key() -> (res: felt):
end

namespace Signer:

    #
    # Initializer
    #

    func initializer{
            syscall_ptr : felt*,
            pedersen_ptr : HashBuiltin*,
            range_check_ptr
        }(_public_key: felt):
        Signer_public_key.write(_public_key)
        return()
    end

    #
    # Guards
    #

    func assert_only_self{syscall_ptr : felt*}():
        let (self) = get_contract_address()
        let (caller) = get_caller_address()
        with_attr error_message("Account: caller is not this account"):
            assert self = caller
        end
        return ()
    end

    func initialized{syscall_ptr : felt*}():
        let (is_initialized) = Signer_public_key.read()
        with_attr error_message("account already initialized"):
            assert is_initialized = 0
        end
    end

    #
    # Getters
    #

    func get_public_key{
            syscall_ptr : felt*,
            pedersen_ptr : HashBuiltin*,
            range_check_ptr
        }() -> (res: felt):
        let (res) = Signer_public_key.read()
        return (res=res)
    end

    #
    # Setters
    #

    func set_public_key{
            syscall_ptr : felt*,
            pedersen_ptr : HashBuiltin*,
            range_check_ptr
        }(new_public_key: felt):
        assert_only_self()

        with_attr error_message("public key can not be zero"):
            assert_not_zero(new_public_key)
        end

        Signer_public_key.write(new_public_key)
        return ()
    end

    #
    # Business logic
    #

    func is_valid_signature{
            syscall_ptr : felt*,
            pedersen_ptr : HashBuiltin*,
            range_check_ptr,
            ecdsa_ptr: SignatureBuiltin*
        }(
            hash: felt,
            signature_len: felt,
            signature: felt*
        ) -> (is_valid: felt):
        let (_public_key) = Signer_public_key.read()

        # This interface expects a signature pointer and length to make
        # no assumption about signature validation schemes.
        # But this implementation does, and it expects a (sig_r, sig_s) pair.
        let sig_r = signature[0]
        let sig_s = signature[1]

        verify_ecdsa_signature(
            message=hash,
            public_key=_public_key,
            signature_r=sig_r,
            signature_s=sig_s)

        return (is_valid=TRUE)
    end
end
