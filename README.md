# starknet-plugin-account

Account abstraction opens a completely new design space for accounts.

This repository is a community effort lead by Argent, Cartridge and Ledger, to explore the possibility to make accounts more flexible and modular by letting users compose which functionalities they want to enable when creating their account. The proposed architecture also aims at making the account extendable by letting users add or remove functionalities after the account has been created. 

The idea of modular smart-contracts is not new and several architectures have been proposed for Ethereum [Argent smart-wallet,  Diamond Pattern]. However, it is the first time that this is applied to accounts directly by leveraging account abstraction.

## Account Abstraction:

In StarkNet accounts must comply to the `IAccount` interface:

```
@contract_interface
namespace IAccount {

    func supportsInterface(interfaceId: felt) -> (success: felt) {
    }

    func isValidSignature(hash: felt, signature_len: felt, signature: felt*) -> (isValid: felt) {
    }

    func __validate__(
        call_array_len: felt, call_array: CallArray*, calldata_len: felt, calldata: felt*
    ) {
    }

    func __validate_declare__(class_hash: felt) {
    }

    func __execute__(
        call_array_len: felt, call_array: CallArray*, calldata_len: felt, calldata: felt*
    ) -> (response_len: felt, response: felt*) {
    }
}
```
The two important methods are `__validate__` which is called by the Cairo OS to verify that the transaction is valid and that the account will pay the fee and `__execute__` which is called by the OS to execute the transaction once it has been validated.

The `__validate__` method has some constraints to protect the network. In particular its logic must be implemented in a small number of steps, and it cannot access the mutable state of any other contracts (i.e. it can only read the storage of the account).

## PluginAccount:

The `PluginAccount` contract is the main account contract that supports the addition of plugins. 

A plugin is a separate piece of logic that can extend the functionalities of the account. 

In this first version we focus only on the validation of transactions so plugins can implement different validation logic. However, the architecture can be easily extended to let plugins handle the execution of transactions in the future.

A plugin must expose the following interface:

```
@contract_interface
namespace IPlugin {
		func initialize(
				plugin: felt,
				plugin_calldata_len: felt,
				plugin_calldata: felt*) {}

    func validate(
        plugin_data_len: felt,
        plugin_data: felt*,
        call_array_len: felt,
        call_array: CallArray*,
        calldata_len: felt,
        calldata: felt*) {}
}
```
Plugins can be enabled and disabled with the methods `addPlugin` and `removePlugin` respectively. 

The presence of a plugin can be checked with the `isPlugin` method.

### Validating with a plugin:

For every transaction the caller can instruct the account to validate the multi-call with a given plugin provided that the plugin has been registered in the account. Once the plugin is identified, the account will delegate the validation of the transaction to the plugin by calling the `validate` method of the plugin.

We note that the plugin must be called with a `library_call` to comply to the constraints of the `__validate__` method which prevents accessing the storage of other contracts. I.e. the logic of the plugin is executed in the context of the account and the state of the plugin, if any, must be stored in the account.

To instruct the account to use a specific plugin we leverage the fact that StarkNet supports multi-calls and prepends the multi-call to execute with a first call identifying the plugin to use. The caller can also provide some additional raw data that can be optionally passed to the plugin as context for the validation. This approach is used to minimise the storage required to identify which plugin to use for a given transaction.

So to execute the multi-call `[Call0, Call1, Call2]` with the plugin `plugin_id` the caller sends instead:

```
M = [Callp, Call0, Call1, Call2]
```
where
```
Callp = {
            to = account,
            selector = 'use_plugin',
            calldata = [plugin_id, optional plugin_data],
        }
```
### The default Plugin:

If no plugin is specified in the transaction  the default plugin is called and used to validate the transaction.  There must always be a default plugin enabled, and this plugin must be properly initialised.

The default plugin is also used to implement the view methods of the `IAccount` interface, namely  `isValidSignature` and `supportsInterface` .

The default plugin can be changed with the method `setDefaultPlugin`.

### Changing the state of a plugin:

To manipulate the state of a plugin, the account has a `__default__` method that will be called when a multi-call specifies a call to the account with an unknown selector.  The plugin to call is the one used for the validation.

### Reading the state of a plugin:

The view methods of a plugin can be accessed through the `readOnPlugin` method.

The view methods of the default plugin can also be accessed through the `__default__` method.

## Development

### Setup a local virtual env

```
python -m venv ./venv
source ./venv/bin/activate
```

### Install Cairo dependencies
```
brew install gmp
```

```
pip install -r requirements.txt
```

See for more details:
- https://www.cairo-lang.org/docs/quickstart.html
- https://github.com/martriay/nile

### Compile the contracts
```
nile compile
```
