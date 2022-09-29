# starknet-plugin-account

Account abstraction opens a completely new design space for accounts.

This repository is a community effort lead by [Argent](https://www.argent.xyz/), [Cartridge](https://cartridge.gg) and [Ledger](https://www.ledger.com/), to explore the possibility to make accounts more flexible and modular by defining a plugin account architecture which lets users compose functionalities they want to enable when creating their account. The proposed architecture also aims to make the account extendable by letting users add or remove functionalities after the account has been created.

The idea of modular smart-contracts is not new and several architectures have been proposed for Ethereum [Argent smart-wallet,  Diamond Pattern]. However, it is the first time that this is applied to accounts directly by leveraging account abstraction.

## Account Abstraction:

In StarkNet accounts must comply to the `IAccount` interface:

```cairo
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

    func __validate_deploy__(
        class_hash: felt, ctr_args_len: felt, ctr_args: felt*, salt: felt
    ) {
    }

    func __execute__(
        call_array_len: felt, call_array: CallArray*, calldata_len: felt, calldata: felt*
    ) -> (response_len: felt, response: felt*) {
    }
}
```
The two important methods are `__validate__` which is called by the Starknet OS to verify that the transaction is valid and that the account will pay the fee before `__execute__` is called by the OS to execute the transaction.

The `__validate__` method has some constraints to protect the network. In particular, its logic must be implemented in a small number of steps and it cannot access the mutable state of any other contracts (i.e. it can only read the storage of the account).

## PluginAccount:

The `PluginAccount` contract is the main account contract that supports the addition of plugins. 

A plugin is a separate piece of logic that can extend the functionalities of the account. 

In this first version we focus only on the validation of transactions so plugins can implement different validation logic. However, the architecture can be easily extended to let plugins handle the execution of transactions in the future.

The Plugin Account extends the base account interface with the following interface:

```cairo
    func addPlugin(plugin: felt, plugin_calldata_len: felt, plugin_calldata: felt*) {
    }

    func removePlugin(plugin: felt) {
    }

    func setDefaultPlugin(plugin: felt) {
    }

    func isPlugin(plugin: felt) -> (success: felt) {
    }

    func readOnPlugin(plugin: felt, selector: felt, calldata_len: felt, calldata: felt*) {
    }

    func getDefaultPlugin() -> (plugin: felt) {
    }
```

A plugin must expose the following interface:

```cairo
@contract_interface
namespace IPlugin {
    func initialize(
        calldata_len: felt,
        calldata: felt*) {}

    func validate(
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

We note that the plugin must be called with a `library_call` to comply to the constraints of the `__validate__` method, which prevents accessing the storage of other contracts. I.e. the logic of the plugin is executed in the context of the account and the state of the plugin, if any, must be stored in the account.

To instruct the account to use a specific plugin we leverage the transaction signature data. By convention, the first item in the signature data specifies either `0` (the default plugin) or the class hash of the plugin which should be used for validation. Any additional context necessary to validate the transaction, such as the signature itself, should be appended to the signature data.

So to validate a call using the default plugin, the signature data should look like: `[0, ...]` and to validate it against a specific plugin, the signature data should look like `[pluginClassHash, ...]`

Similarly, the `isValidSignature` will validate a signature using the provided plugin in the passed signature data.

### The default Plugin:

If no plugin is specified, the default plugin is used to validate the transaction. There must always be a default plugin defined and this plugin must be properly initialised.

The default plugin is also used to implement the `supportsInterface` method of the account.

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
